# frozen_string_literal: true

module Runeforge
  # Answers deps.check messages for a foreground run by asking the person at the terminal.
  # In a container sandbox it installs apt packages into a per-project image built on top of the
  # current one; without a sandbox it asks the person to install the tools themselves.
  class Operator
    TOOL = /\A[A-Za-z0-9][\w.+-]{0,63}\z/
    PACKAGE = /\A[a-z0-9][a-z0-9.+-]{0,63}\z/

    # Debian packages for tools whose package name differs from the command.
    PACKAGES = {
      "go" => "golang", "java" => "default-jdk", "javac" => "default-jdk", "mvn" => "maven",
      "python" => "python3", "pip" => "python3-pip", "pip3" => "python3-pip", "node" => "nodejs",
      "npx" => "npm", "ruby" => "ruby-full", "bundle" => "ruby-bundler", "gcc" => "build-essential",
      "g++" => "build-essential", "make" => "build-essential", "php" => "php-cli", "psql" => "postgresql-client",
      "mysql" => "default-mysql-client", "redis-server" => "redis-server", "rustc" => "rustc", "cargo" => "cargo"
    }.freeze

    # builder(runtime, tag, dockerfile) builds an image and returns true on success.
    def initialize(env, input: $stdin, output: $stdout, builder: nil)
      @env = env
      @input = input
      @output = output
      @builder = builder || method(:docker_build)
    end

    # Returns the outcome for Mailbox#complete.
    def call(msg)
      tools = Array(msg.payload["tools"]).map(&:to_s).grep(TOOL).uniq
      repo = @env.repos.fetch(@env.tasks.find!(msg.task_id)[:repo])
      loop do
        missing = missing_tools(tools, repo)
        return outcome(msg, "deps.ready", "tools" => tools) if missing.empty?

        packages = ask(missing, repo)
        return outcome(msg, "deps.declined", "missing" => missing) unless packages

        install(repo, packages) if @env.sandboxed? && packages.any?
        repo = @env.repos.fetch(repo[:name])
      end
    end

    private

    def outcome(msg, type, payload)
      { result_type: type, payload: payload.merge("resume" => msg.payload["resume"]), commit_sha: msg.commit_sha }
    end

    def missing_tools(tools, repo)
      return [] if tools.empty?

      script = tools.map { |tool| "command -v #{tool} >/dev/null 2>&1 || echo #{tool}" }.join("\n")
      Dir.mktmpdir("runeforge-deps") do |dir|
        @env.new_sandbox(image: repo[:image]).run(workdir: dir, script:).stdout.split.grep(TOOL)
      end
    end

    # Returns packages to install ([] means "check again"), or nil when the person declines.
    def ask(missing, repo)
      if @env.sandboxed?
        image = repo[:image] || @env.config.dig("sandbox", "image")
        suggested = missing.map { |tool| PACKAGES.fetch(tool, tool) }.uniq
        @output.puts "\n  The sandbox image #{image} is missing: #{missing.join(', ')}"
        @output.print "  Install these apt packages? [#{suggested.join(' ')}] (Enter to accept, type package names, or n to stop): "
        answer = read_line
        return nil if answer.nil? || answer.casecmp?("n")

        packages = answer.empty? ? suggested : answer.split
        invalid = packages.grep_v(PACKAGE)
        return packages if invalid.empty?

        @output.puts "  Not a valid package name: #{invalid.join(', ')}"
        []
      else
        @output.puts "\n  Missing on this machine: #{missing.join(', ')}"
        @output.print "  Install them, then press Enter to check again (or n to stop): "
        answer = read_line
        answer.nil? || answer.casecmp?("n") ? nil : []
      end
    end

    def read_line
      line = @input.gets
      line&.strip
    end

    def install(repo, packages)
      runtime = @env.config.dig("sandbox", "mode")
      base = repo[:image] || @env.config.dig("sandbox", "image")
      tag = "runeforge/#{repo[:name].downcase}:latest"
      dockerfile = <<~DOCKERFILE
        FROM #{base}
        USER root
        RUN apt-get update && apt-get install -y --no-install-recommends #{packages.join(' ')} && rm -rf /var/lib/apt/lists/*
      DOCKERFILE
      @output.puts "  Building #{tag} with #{packages.join(', ')}..."
      raise Error, "#{runtime} build failed for #{tag}" unless @builder.call(runtime, tag, dockerfile)

      @env.repos.update(repo[:name], image: tag)
      @output.puts "  #{repo[:name]} now uses #{tag}"
    end

    def docker_build(runtime, tag, dockerfile)
      IO.popen([runtime, "build", "-t", tag, "-"], "w") { |io| io.write(dockerfile) }
      $?.success?
    end
  end
end
