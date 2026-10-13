# frozen_string_literal: true

require "digest"
require "pathname"
require "yaml"

module Runeforge
  # A project's own development environment, from its devcontainer.json (containers.dev): the
  # image its agents and tests run in, the services its tests talk to (the `depends_on` of a
  # docker-compose devcontainer: postgres, redis, ...) and the variables that point at them.
  #
  # .ensure_image builds the image once per version of these files, with a Runeforge layer on top
  # (the agent CLIs, and the project's gems installed in advance), and records it on the repo;
  # Sandbox::Container then starts the services next to every run (see Environment#new_sandbox).
  class Devcontainer
    PATHS = %w[.devcontainer/devcontainer.json .devcontainer.json].freeze
    # Installed into the image ahead of time, so runs don't download every gem again.
    DEPENDENCY_FILES = %w[Gemfile Gemfile.lock gems.rb gems.locked .ruby-version .tool-versions].freeze
    # Bump when the Runeforge layer changes, so every project image is rebuilt.
    LAYER_VERSION = 3
    BUNDLE = "/opt/runeforge/bundle"
    # Without the devcontainer CLI, the apt packages that stand in for well-known features.
    FEATURE_PACKAGES = {
      "postgres-client" => %w[postgresql-client libpq-dev], "mysql-client" => %w[default-mysql-client default-libmysqlclient-dev],
      "sqlite3" => %w[sqlite3 libsqlite3-dev], "activestorage" => %w[libvips poppler-utils ffmpeg],
      "node" => [], "github-cli" => %w[gh] # Runeforge's layer installs Node when the image lacks it
    }.freeze

    # shm_size: the compose file's, as given (bytes, or "2gb"), or nil for the sandbox's default.
    Service = Data.define(:name, :image, :env, :healthcheck, :shm_size) do
      def initialize(name:, image:, env:, healthcheck:, shm_size: nil) = super

      def to_h = { "name" => name, "image" => image, "env" => env, "healthcheck" => healthcheck, "shm_size" => shm_size }.compact

      def self.from_h(hash)
        new(name: hash["name"], image: hash["image"], env: hash["env"] || {}, healthcheck: hash["healthcheck"], shm_size: hash["shm_size"])
      end
    end

    # path: devcontainer.json. source: { "image" => ... } or { "dockerfile", "context", "args" }
    # (paths from the project root). main: the compose service agents run as, or nil. notes:
    # what was skipped, to tell the person.
    attr_reader :path, :source, :main, :services, :env, :features, :files, :notes, :user

    # read.(path) returns a file's contents (relative to the project root), or nil. Returns nil
    # when the project has no devcontainer.
    def self.read(read)
      path = PATHS.find { |candidate| read.(candidate) }
      path && new(path, read)
    end

    # Reads the project's files from its host clone at `sha`.
    def self.at(env, repo_name, sha)
      clone = env.repos.path(repo_name)
      read(->(path) { Git.run("show", "#{sha}:#{path}", dir: clone, allow_failure: true) })
    end

    def initialize(path, read)
      @path = path
      @read = read
      @notes = []
      @files = [path]
      @services = []
      config = self.class.parse_jsonc(read.(path))
      raise Error, "#{path} must be a JSON object" unless config.is_a?(Hash)

      dir = File.dirname(path)
      @features = (config["features"] || {}).keys
      # Whose login environment the tools are set up in (a devcontainer image's own label says, if this doesn't).
      @user = (config["remoteUser"] || config["containerUser"])&.to_s
      @env = {}
      if config["dockerComposeFile"]
        compose_source(config, dir)
      elsif config["image"]
        @source = { "image" => config["image"].to_s }
      elsif (build = config["build"] || (config["dockerFile"] && { "dockerfile" => config["dockerFile"] }))
        context = relative(dir, build["context"] || ".")
        @source = { "dockerfile" => relative(dir, build["dockerfile"] || build["dockerFile"] || "Dockerfile"),
                    "context" => context, "args" => stringify(build["args"]) }
      else
        raise Error, "#{path} names no image, build or dockerComposeFile"
      end
      @files << @source["dockerfile"] if @source["dockerfile"]
      @env.merge!(stringify(config["containerEnv"])).merge!(stringify(config["remoteEnv"]))
      # ${localEnv:...} and the like are resolved by editors, not here.
      @env.select { |_name, value| value.include?("${") }.each do |name, value|
        @env.delete(name)
        @notes << "#{name} is left out (#{value} isn't resolved here)"
      end
    end

    # Changes whenever anything that goes into the image does.
    def digest
      parts = [LAYER_VERSION.to_s, *(files + DEPENDENCY_FILES + gemfile_extras).uniq.sort.map { |file| "#{file}\0#{@read.(file)}" }]
      Digest::SHA256.hexdigest(parts.join("\0\0"))[0, 12]
    end

    # What's stored on the repo for Environment#new_sandbox.
    def to_h = { "path" => path, "main" => main, "services" => services.map(&:to_h), "env" => env }

    # For the agents' prompts: what runs next to them and how to reach it.
    def self.describe(stored)
      services = Array(stored["services"])
      return nil if services.empty? && (stored["env"] || {}).empty?

      lines = ["The project's devcontainer (#{stored['path']}) is the sandbox image."]
      if services.any?
        lines << "Its services run next to you, reachable by name: " \
                 "#{services.map { |s| "#{s['name']} (#{s['image']})" }.join(', ')}. Their data starts empty on every run, " \
                 "so set up what the tests need (e.g. `bin/rails db:prepare`) in setup_command."
      end
      env = stored["env"] || {}
      lines << "Set for you: #{env.map { |name, value| "#{name}=#{value}" }.join(', ')}." if env.any?
      lines.join(" ")
    end

    # Builds (or finds) the image for `repo_name`'s devcontainer at its base branch and records it
    # on the repo. Returns [status, detail] for Setup#step: :ok, :skipped or :warning.
    def self.ensure_image(env, repo_name, shell: Setup::Shell.new, out: $stdout)
      return [:skipped, "not needed in dry-run mode"] if env.dry_run?

      repo = env.repos.fetch(repo_name)
      runtime = env.sandbox_mode(repo)
      return [:skipped, "not needed without a container sandbox"] unless %w[docker podman].include?(runtime)

      sha = env.repos.refresh(repo_name)
      devcontainer = at(env, repo_name, sha)
      ours = repo[:image].nil? || repo[:image].start_with?(tag_prefix(repo_name))
      unless devcontainer
        env.repos.update(repo_name, devcontainer: nil, **(ours ? { image: nil } : {}))
        return [:skipped, "the project has no devcontainer; using #{repo[:image] || env.config.dig('sandbox', 'image')}"]
      end
      return [:warning, "#{repo_name} uses the image #{repo[:image]} (`runeforge repo set --image`), not its devcontainer"] unless ours

      tag = "#{tag_prefix(repo_name)}#{devcontainer.digest}"
      stored = repo[:devcontainer] && JSON.parse(repo[:devcontainer])
      if shell.run?(runtime, "image", "inspect", tag) && stored&.dig("tag") == tag
        env.repos.update(repo_name, image: tag)
        return [:ok, "#{tag} is present"]
      end

      log = File.join(env.home, "logs", "devcontainer-#{repo_name}.log").tap { |file| FileUtils.mkdir_p(File.dirname(file)) }
      File.write(log, "")
      out.puts "  building #{tag} from #{devcontainer.path} (this takes a few minutes the first time; output in #{log})"
      Dir.mktmpdir("runeforge-devcontainer") do |dir|
        env.repos.export(repo_name, sha:, to: dir)
        base = devcontainer.build_base(runtime, dir, "#{tag}-base", shell:, out:, log:)
        devcontainer.build_layer(runtime, dir, base, tag, shell:, log:, path: login_path(runtime, base, devcontainer.user, shell))
      end
      stored = devcontainer.to_h.merge("tag" => tag, "defaults" => probe(runtime, tag, shell))
      env.repos.update(repo_name, image: tag, devcontainer: JSON.generate(stored))
      remove_older(runtime, repo_name, tag, shell)
      devcontainer.notes.each { |note| out.puts "  ! #{note}" }
      [:ok, "built #{tag}"]
    rescue Setup::StepFailed => e
      raise unless devcontainer

      failed(env, repo_name, repo, devcontainer, "#{e.message}#{diagnosis(log)}", out)
    end

    # Records why the image didn't build, so the planner's advice names it. An image built from an
    # earlier version of the files stays in use; otherwise there is none.
    def self.failed(env, repo_name, repo, devcontainer, reason, out)
      stored = repo[:devcontainer] ? JSON.parse(repo[:devcontainer]) : { "path" => devcontainer.path }
      env.repos.update(repo_name, devcontainer: JSON.generate(stored.merge("error" => reason)))
      [:failed, "the image for #{devcontainer.path} didn't build: #{reason}"]
    end

    # The end of a failed build's log, and what it most likely means.
    def self.diagnosis(log)
      lines = log && File.file?(log) ? File.readlines(log, chomp: true).reject { |line| line.strip.empty? } : []
      cause =
        if lines.any? { |line| line.match?(/no space left on device|input\/output error/i) }
          ". Docker ran out of disk space or its storage failed (input/output error): free space on this machine " \
            "(`df -h`), remove unused images (`docker system prune`), restart Docker, then run again"
        elsif lines.any? { |line| line.match?(/Cannot connect to the Docker daemon|daemon is not running/i) }
          ". Docker isn't running; start it and run again"
        end
      tail = lines.last(6).map { |line| line.strip[0, 200] }.join("\n    ")
      "#{cause}#{tail.empty? ? '' : ". Last lines of #{log}:\n    #{tail}"}"
    end

    # Each version of the devcontainer files is a new image of a few GB; only the newest is used.
    def self.remove_older(runtime, repo_name, tag, shell)
      prefix = tag_prefix(repo_name)
      older = shell.capture(runtime, "images", "--format", "{{.Repository}}:{{.Tag}}", prefix.delete_suffix(":"))
                   .lines(chomp: true).select { |image| image.start_with?(prefix) } - [tag, "#{tag}-base"]
      shell.run?(runtime, "rmi", *older) if older.any?
    end

    def self.tag_prefix(repo_name) = "runeforge/#{repo_name.to_s.downcase}-dev:"

    MARKER = "__RUNEFORGE_PATH__="

    # The PATH the image's user gets in a login shell: where version managers (mise, rbenv, nvm)
    # put the project's Ruby and Node, which the image's own PATH often lacks. What the
    # devcontainer CLI's userEnvProbe does. Nil when it can't be read.
    def self.login_path(runtime, image, user, shell)
      user ||= label_user(runtime, image, shell)
      script = %(command -v bash >/dev/null 2>&1 && exec bash -lic 'printf "\\n#{MARKER}%s\\n" "$PATH"'; ) +
               %(printf "\\n#{MARKER}%s\\n" "$PATH")
      found = shell.capture(runtime, "run", "--rm", *(user ? ["--user", user] : []), "--entrypoint", "sh", image, "-c", script)
      found.lines(chomp: true).reverse.find { |line| line.start_with?(MARKER) }&.delete_prefix(MARKER)&.then { |p| p.empty? ? nil : p }
    end

    # The remoteUser a devcontainer image records in its devcontainer.metadata label.
    def self.label_user(runtime, image, shell)
      label = shell.capture(runtime, "image", "inspect", "--format", '{{index .Config.Labels "devcontainer.metadata"}}', image)
      Array(JSON.parse(label)).reverse.find { |entry| entry.is_a?(Hash) && entry["remoteUser"] }&.dig("remoteUser")
    rescue JSON::ParserError
      nil
    end

    # The image's own PATH and gem path, kept with Runeforge's writable /tmp locations in front
    # (sandbox containers have a read-only root filesystem).
    def self.probe(runtime, tag, shell)
      found = shell.capture(runtime, "run", "--rm", "--entrypoint", "sh", tag, "-c",
                            'printf "%s\n" "$PATH"; ruby -e "print Gem.path.join(%q(:))" 2>/dev/null').lines(chomp: true)
      raise Setup::StepFailed, "couldn't start a container from #{tag}" if found.empty?

      path, gems = found[0].to_s, found[1].to_s
      {
        "PATH" => ["/tmp/gems/bin", "#{BUNDLE}/bin", "/tmp/npm-global/bin", "/tmp/home/.local/bin", path].reject(&:empty?).join(":"),
        "GEM_HOME" => "/tmp/gems", "GEM_PATH" => ["/tmp/gems", BUNDLE, gems].reject(&:empty?).join(":"),
        "BUNDLE_APP_CONFIG" => "/tmp/bundle", "NPM_CONFIG_PREFIX" => "/tmp/npm-global", "npm_config_cache" => "/tmp/.npm"
      }
    end

    # The project's image, without Runeforge's layer. The devcontainer CLI applies `features`;
    # without it, a plain build skips them (and says so).
    def build_base(runtime, dir, tag, shell:, out:, log:)
      if features.any? && shell.which("devcontainer")
        shell.run_logged!("devcontainer", "build", "--workspace-folder", dir, "--config", File.join(dir, path), "--image-name", tag, log:)
        return tag
      end
      skipped = features.reject { |feature| feature_packages(feature) }
      out.puts "  ! devcontainer features skipped (install the devcontainer CLI to apply them): #{skipped.join(', ')}" if skipped.any?
      @packages = features.filter_map { |feature| feature_packages(feature) }.flatten.uniq
      return source["image"] if source["image"]

      args = (source["args"] || {}).flat_map { |name, value| ["--build-arg", "#{name}=#{value}"] }
      shell.run_logged!(runtime, "build", *plain(runtime), "-t", tag, "-f", File.join(dir, source["dockerfile"]), *args,
                        File.join(dir, source["context"]), log:)
      tag
    end

    # Runeforge's layer: the agent CLIs if the image lacks them, and the project's gems. `dir` is
    # the exported project (a Gemfile may load files and path gems from anywhere in it).
    # path: the user's login PATH (see .login_path), set for everything after it. A Gemfile whose
    # gems don't install fails the build: tests could never run without them.
    def build_layer(runtime, dir, base, tag, shell:, log:, path: nil)
      dockerfile = File.join(dir, ".runeforge-layer.Dockerfile")
      File.write(dockerfile, <<~DOCKERFILE)
        FROM #{base}
        USER root
        #{path ? "ENV PATH=#{path}" : ''}
        #{path ? traverse_step : ''}
        RUN set -e; \\
            if ! command -v node >/dev/null 2>&1; then \\
              apt-get update && apt-get install -y --no-install-recommends nodejs npm && rm -rf /var/lib/apt/lists/*; fi; \\
            if ! command -v claude >/dev/null 2>&1; then npm install -g @anthropic-ai/claude-code && npm cache clean --force; fi; \\
            if command -v gem >/dev/null 2>&1; then gem install --no-document --install-dir /opt/runeforge/gems ruby_llm -v "~> 2.0"; fi
        #{packages_step}
        COPY . /opt/runeforge/app/
        RUN if [ -f /opt/runeforge/app/Gemfile ]; then \\
              cd /opt/runeforge/app && GEM_HOME=#{BUNDLE} bundle install --jobs 4; fi; \\
            mkdir -p #{BUNDLE} && chmod -R a+rX /opt/runeforge
      DOCKERFILE
      shell.run_logged!(runtime, "build", *plain(runtime), "-t", tag, "-f", dockerfile, dir, log:)
    end

    # Sandbox runs use this machine's uid, not the image's user, so the directories on PATH (a
    # version manager's under a private home directory) must let anyone through.
    def traverse_step
      'RUN for dir in $(echo "$PATH" | tr ":" " "); do ' \
        'while [ -n "$dir" ] && [ "$dir" != / ]; do [ -d "$dir" ] && chmod o+x "$dir"; dir=$(dirname "$dir"); done; done'
    end

    # Docker's build output as plain lines, readable in a log (podman's already is).
    def plain(runtime) = runtime == "docker" ? ["--progress=plain"] : []

    # The apt packages for a feature id ("ghcr.io/rails/devcontainer/features/postgres-client:1"),
    # or nil for one Runeforge doesn't know.
    def feature_packages(feature) = FEATURE_PACKAGES[File.basename(feature.to_s).sub(/:[^:]*\z/, "")]

    # Installs the packages standing in for features, when the devcontainer CLI didn't apply them.
    def packages_step
      return "" if Array(@packages).empty?

      "RUN apt-get update && apt-get install -y --no-install-recommends #{@packages.join(' ')} && rm -rf /var/lib/apt/lists/*"
    end

    # JSON with comments and trailing commas, as devcontainer.json allows.
    def self.parse_jsonc(text)
      out = +""
      i = 0
      string = false
      while i < text.length
        char = text[i]
        if string
          out << char
          if char == "\\"
            out << text[i + 1].to_s
            i += 1
          elsif char == '"'
            string = false
          end
        elsif char == '"'
          string = true
          out << char
        elsif text[i, 2] == "//"
          i = (text.index("\n", i) || text.length) - 1
        elsif text[i, 2] == "/*"
          i = (text.index("*/", i + 2) || text.length) + 1
        else
          out << char
        end
        i += 1
      end
      JSON.parse(out.gsub(/,(\s*[}\]])/, '\1'))
    rescue JSON::ParserError => e
      raise Error, "devcontainer.json is not valid JSON: #{e.message.lines.first&.strip}"
    end

    private

    # A compose devcontainer: the image is the main service's; the services it depends on run
    # beside it when they're plain images (ones built from source are skipped).
    def compose_source(config, dir)
      files = Array(config["dockerComposeFile"]).map { |file| relative(dir, file) }
      @files.concat(files)
      compose = files.each_with_object({}) do |file, merged|
        data = YAML.safe_load(@read.(file).to_s, aliases: true) || {}
        (data["services"] || {}).each { |name, service| (merged[name] ||= {}).merge!(service || {}) }
      end
      @main = config["service"].to_s
      service = compose[@main] or raise Error, "#{path} names the service #{@main.inspect}, which #{files.join(', ')} doesn't define"
      compose_dir = File.dirname(files.first)
      if (build = service["build"])
        build = { "context" => build } if build.is_a?(String)
        context = relative(compose_dir, build["context"] || ".")
        @source = { "dockerfile" => relative(context, build["dockerfile"] || "Dockerfile"), "context" => context,
                    "args" => stringify(build["args"]) }
      elsif service["image"]
        @source = { "image" => service["image"].to_s }
      else
        raise Error, "the compose service #{@main} has no image or build"
      end
      @env.merge!(environment(service["environment"]))
      depends = service["depends_on"].is_a?(Hash) ? service["depends_on"].keys : Array(service["depends_on"])
      depends.map(&:to_s).each do |name|
        other = compose[name] || {}
        next @notes << "the service #{name} is built from source; it isn't started" if other["build"] || !other["image"]

        test = other.dig("healthcheck", "test")
        @services << Service.new(name:, image: other["image"].to_s, env: environment(other["environment"]),
                                 healthcheck: test && Array(test).map(&:to_s), shm_size: other["shm_size"]&.to_s)
      end
    end

    # Gemfiles the Gemfile pulls in (`eval_gemfile "Gemfile.jumpstart"`), part of the digest.
    def gemfile_extras
      Array(@read.("Gemfile")&.scan(/eval_gemfile\s*\(?\s*["']([^"']+)["']/)).flatten.reject { |file| file.include?("..") }
    end

    def environment(value)
      return stringify(value) if value.is_a?(Hash)

      Array(value).to_h { |pair| pair.to_s.split("=", 2) }.transform_values(&:to_s)
    end

    def stringify(hash) = (hash || {}).to_h { |key, value| [key.to_s, value.to_s] }

    # A path in the devcontainer's files, from the project root; never outside it.
    def relative(dir, file)
      joined = Pathname.new(File.join(dir, file.to_s)).cleanpath.to_s
      raise Error, "#{path} points outside the project: #{file}" if joined.start_with?("..") || joined.start_with?("/")

      joined
    end
  end
end
