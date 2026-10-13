# frozen_string_literal: true

RSpec.describe Runeforge::Devcontainer do
  let(:backend) { "sqlite" }

  # Shaped like a Jumpstart Rails app: a compose devcontainer whose app service depends on
  # postgres, redis and selenium, with comments and trailing commas in devcontainer.json.
  let(:rails_files) do
    {
      ".devcontainer/devcontainer.json" => <<~JSON,
        // For format details, see https://aka.ms/devcontainer.json.
        {
          "name": "Rails app",
          "dockerComposeFile": "compose.yaml",
          "service": "rails-app",
          "features": {
            "ghcr.io/rails/devcontainer/features/postgres-client": {}, /* psql */
            "ghcr.io/example/features/unknown:2": {},
          },
          "containerEnv": {
            "SELENIUM_HOST": "selenium",
            "REDIS_URL": "redis://redis:6379/1",
            "DB_HOST": "postgres",
            "TOKEN": "${localEnv:TOKEN}",
          },
          "postCreateCommand": "bin/setup"
        }
      JSON
      ".devcontainer/compose.yaml" => <<~YAML,
        services:
          rails-app:
            build:
              context: ..
              dockerfile: .devcontainer/Dockerfile
            command: sleep infinity
            depends_on:
              - selenium
              - redis
              - postgres
          selenium:
            image: seleniarm/standalone-chromium
          redis:
            image: redis:7
          postgres:
            image: postgres:17
            environment:
              POSTGRES_USER: postgres
              POSTGRES_PASSWORD: postgres
      YAML
      ".devcontainer/Dockerfile" => "ARG RUBY_VERSION=3.4.7\nFROM ghcr.io/rails/devcontainer/images/ruby:$RUBY_VERSION\n",
      "Gemfile" => "source \"https://rubygems.org\"\nruby file: \".ruby-version\"\neval_gemfile \"Gemfile.jumpstart\"\n",
      "Gemfile.jumpstart" => "gem \"jumpstart\", path: \"lib/jumpstart\"\n",
      ".ruby-version" => "3.4.7\n"
    }
  end

  def reader(files) = ->(path) { files[path] }

  describe ".read" do
    it "reads a compose devcontainer: the app service's build, its image-only services and its variables" do
      devcontainer = described_class.read(reader(rails_files))

      expect(devcontainer.path).to eq(".devcontainer/devcontainer.json")
      expect(devcontainer.main).to eq("rails-app")
      expect(devcontainer.source).to eq("dockerfile" => ".devcontainer/Dockerfile", "context" => ".", "args" => {})
      expect(devcontainer.services.map(&:name)).to eq(%w[selenium redis postgres])
      expect(devcontainer.services.last).to have_attributes(image: "postgres:17",
                                                            env: { "POSTGRES_USER" => "postgres", "POSTGRES_PASSWORD" => "postgres" })
      expect(devcontainer.env).to eq("SELENIUM_HOST" => "selenium", "REDIS_URL" => "redis://redis:6379/1", "DB_HOST" => "postgres")
      expect(devcontainer.notes).to eq(["TOKEN is left out (${localEnv:TOKEN} isn't resolved here)"])
      expect(devcontainer.features).to eq(%w[ghcr.io/rails/devcontainer/features/postgres-client ghcr.io/example/features/unknown:2])
      expect(devcontainer.features.map { |feature| devcontainer.feature_packages(feature) }).to eq([%w[postgresql-client libpq-dev], nil])
    end

    it "reads image and Dockerfile devcontainers, and none at all" do
      expect(described_class.read(reader(".devcontainer.json" => '{"image": "ruby:3.4"}')).source).to eq("image" => "ruby:3.4")
      built = described_class.read(reader(".devcontainer/devcontainer.json" => '{"build": {"dockerfile": "Dockerfile", "args": {"V": 1}}}'))
      expect(built.source).to eq("dockerfile" => ".devcontainer/Dockerfile", "context" => ".devcontainer", "args" => { "V" => "1" })
      expect(described_class.read(reader({}))).to be_nil
    end

    it "refuses paths outside the project and broken JSON" do
      outside = { ".devcontainer/devcontainer.json" => '{"build": {"dockerfile": "../../etc/Dockerfile"}}' }
      expect { described_class.read(reader(outside)) }.to raise_error(Runeforge::Error, /outside the project/)
      expect { described_class.read(reader(".devcontainer.json" => "{nope")) }.to raise_error(Runeforge::Error, /not valid JSON/)
    end

    it "changes its digest with the files that go into the image, including Gemfiles the Gemfile loads" do
      base = described_class.read(reader(rails_files)).digest
      expect(described_class.read(reader(rails_files.merge("README.md" => "changed"))).digest).to eq(base)
      expect(described_class.read(reader(rails_files.merge("Gemfile.jumpstart" => "gem \"x\"\n"))).digest).not_to eq(base)
      expect(described_class.read(reader(rails_files.merge(".ruby-version" => "3.4.8\n"))).digest).not_to eq(base)
    end
  end

  describe ".ensure_image" do
    # Records commands; images "exist" once built.
    let(:shell) do
      Class.new do
        attr_reader :commands

        def initialize = (@commands = [])
        def which(_name) = nil
        def capture(*cmd)
          @commands << cmd
          return "runeforge/app-dev:0123456789ab\nruneforge/app-dev:0123456789ab-base\n" if cmd[1] == "images"

          "/usr/local/bin:/usr/bin\n/usr/local/bundle\n"
        end

        def run?(*cmd)
          @commands << cmd
          cmd[1..2] == %w[image inspect] && @commands.any? { |c| c[1] == "build" && c.include?(cmd[3]) }
        end

        def run!(*cmd) = (@commands << cmd) && true

        # fail_with: a line the build "prints" before failing.
        attr_accessor :fail_with

        def run_logged!(*cmd, log:)
          @commands << cmd
          return true unless fail_with

          File.write(log, "#{fail_with}\n", mode: "a")
          raise Runeforge::Setup::StepFailed, "`#{cmd.first(2).join(' ')}` failed"
        end
      end.new
    end

    def project(files)
      dir = File.join(tmpdir, "app")
      files.each do |path, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), body)
      end
      sh!("git", "init", "-q", "-b", "main", dir:)
      sh!("git", "add", "-A", dir:)
      sh!("git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "init", dir:)
      dir
    end

    it "builds the project's image with Runeforge's layer once, and records it with its services" do
      env = build_env("sandbox" => { "mode" => "docker" })
      env.repos.add(name: "app", url: project(rails_files), test_command: "")
      out = StringIO.new

      status, detail = described_class.ensure_image(env, "app", shell:, out:)
      tag = env.repos.fetch("app")[:image]
      expect([status, detail]).to eq([:ok, "built #{tag}"])
      expect(tag).to match(%r{\Aruneforge/app-dev:\h{12}\z})
      builds = shell.commands.select { |cmd| cmd[1] == "build" }
      expect(builds.first).to include("#{tag}-base").and(satisfy { |cmd| cmd.any? { |arg| arg.end_with?(".devcontainer/Dockerfile") } })
      expect(builds.last).to include(tag)
      expect(out.string).to include("devcontainer features skipped (install the devcontainer CLI to apply them): " \
                                    "ghcr.io/example/features/unknown:2", "! TOKEN is left out")

      stored = JSON.parse(env.repos.fetch("app")[:devcontainer])
      expect(stored).to include("tag" => tag, "main" => "rails-app")
      expect(stored["services"].map { |s| s["name"] }).to eq(%w[selenium redis postgres])
      expect(stored["defaults"]).to include("GEM_PATH" => "/tmp/gems:/opt/runeforge/bundle:/usr/local/bundle",
                                            "PATH" => start_with("/tmp/gems/bin:").and(end_with(":/usr/local/bin:/usr/bin")))

      expect(shell.commands).to include(["docker", "rmi", "runeforge/app-dev:0123456789ab", "runeforge/app-dev:0123456789ab-base"])
      expect(described_class.ensure_image(env, "app", shell:, out:)).to eq([:ok, "#{tag} is present"])
      expect(shell.commands.count { |cmd| cmd[1] == "build" }).to eq(2)
    end

    it "stops the environment check when the image doesn't build, saying why and what to do" do
      env = build_env("sandbox" => { "mode" => "docker" })
      env.repos.add(name: "app", url: project(rails_files), test_command: "")
      shell.fail_with = "ERROR: failed to solve: write /var/lib/docker/buildkit/metadata_v2.db: input/output error"

      status, detail = described_class.ensure_image(env, "app", shell:, out: StringIO.new)
      expect(status).to eq(:failed)
      expect(detail).to include("didn't build: `docker build` failed. Docker ran out of disk space", "input/output error",
                                "docker system prune", "Last lines of #{env.home}/logs/devcontainer-app.log")
      stored = JSON.parse(env.repos.fetch("app")[:devcontainer])
      expect(stored).to include("path" => ".devcontainer/devcontainer.json", "error" => start_with("`docker build` failed"))
      expect(stored).not_to include("services") # no services beside the general image
      expect(env.repos.fetch("app")[:image]).to be_nil

      out = StringIO.new
      allow(shell).to receive(:which).and_return("/usr/local/bin/docker")
      allow(shell).to receive(:capture).and_return("28.5.2\n")
      doctor = Runeforge::Doctor.new(env, "app", directory: File.join(tmpdir, "app"), shell:, out:)
      expect { doctor.run! }.to raise_error(Runeforge::Doctor::NotReady)
      expect(out.string).to include("✓ docker", "✗ project image  the image for .devcontainer/devcontainer.json didn't build",
                                    "fix: docker ran out of disk space or its storage failed")
    end

    it "leaves an image the person chose, and skips projects without a devcontainer or a container sandbox" do
      env = build_env("sandbox" => { "mode" => "docker" })
      env.repos.add(name: "app", url: project(rails_files), test_command: "", image: "my/image:1")
      expect(described_class.ensure_image(env, "app", shell:).first).to eq(:warning)
      expect(env.repos.fetch("app")[:image]).to eq("my/image:1")

      expect(described_class.ensure_image(build_env.tap { |e| e.repos.add(name: "app", url: File.join(tmpdir, "app"), test_command: "") },
                                          "app", shell:).first).to eq(:skipped)
    end
  end

  describe "the sandbox with services" do
    # A container runtime that logs its arguments; `exec` (a readiness check) fails once.
    let(:runtime) do
      path = File.join(tmpdir, "fake-docker")
      File.write(path, <<~SH)
        #!/bin/sh
        echo "$*" >> #{tmpdir}/runtime.log
        if [ "$1" = exec ] && [ ! -f #{tmpdir}/ready ]; then touch #{tmpdir}/ready; exit 1; fi
        [ "$1" = run ] && [ "$2" != -d ] && echo "host DB_HOST=${DB_HOST:-unset} PATH=$PATH"
        exit 0
      SH
      File.chmod(0o755, path)
      path
    end

    def log = File.readlines(File.join(tmpdir, "runtime.log"), chomp: true)

    it "starts the services on a private network, waits for them, runs, then removes them" do
      services = [Runeforge::Devcontainer::Service.new(name: "postgres", image: "pgvector/pgvector:pg17", env: { "POSTGRES_PASSWORD" => "pw" }, healthcheck: nil),
                  Runeforge::Devcontainer::Service.new(name: "cache", image: "example/cache", env: {}, healthcheck: ["CMD", "ping-it"])]
      sandbox = Runeforge::Sandbox::Container.new(runtime:, image: "app:dev", network: "bridge", cpus: 1, memory: "1g", pids: 64,
                                                  timeout: 30, services:, name: "rails-app",
                                                  env: { "DB_HOST" => "postgres", "PATH" => "/opt/app/bin:/usr/bin" })
      result = sandbox.run(workdir: tmpdir, script: "true")

      # The container's settings go in by value; the CLI's own PATH stays this machine's.
      expect(result.stdout).to eq("host DB_HOST=unset PATH=#{ENV['PATH']}\n")
      net = log.first[/network create (\S+)/, 1]
      expect(net).to end_with("-net")
      id = net.delete_suffix("-net")
      expect(log[1]).to start_with("run -d --rm --name #{id}-postgres --network #{net} --network-alias postgres").and end_with("-e POSTGRES_PASSWORD=pw pgvector/pgvector:pg17")
      expect(log[2]).to include("--network-alias cache", "example/cache")
      expect(log[3..5]).to eq(["exec #{id}-postgres pg_isready -q", "exec #{id}-postgres pg_isready -q", "exec #{id}-cache ping-it"])
      expect(log[6]).to start_with("run --rm --name #{id} --network #{net} --network-alias rails-app --read-only").and include("-e DB_HOST=postgres -e PATH=/opt/app/bin:/usr/bin")
      expect(log[7..]).to eq(["rm -f #{id}-postgres #{id}-cache", "network rm #{net}"])
    end

    it "says the sandbox is unavailable, not that the agent failed, when the runtime is missing or broken" do
      missing = Runeforge::Sandbox::Container.new(runtime: "no-such-docker", image: "app", network: "bridge", cpus: 1, memory: "1g",
                                                  pids: 64, timeout: 30)
      expect { missing.run(workdir: tmpdir, script: "true") }
        .to raise_error(Runeforge::Sandbox::Unavailable, "`no-such-docker` isn't installed or isn't on PATH")

      broken = File.join(tmpdir, "broken-docker")
      File.write(broken, "#!/bin/sh\necho 'docker: Error response from daemon: write /var/lib/docker/x: input/output error.' >&2\nexit 125\n")
      File.chmod(0o755, broken)
      sandbox = Runeforge::Sandbox::Container.new(runtime: broken, image: "app", network: "bridge", cpus: 1, memory: "1g", pids: 64, timeout: 30)
      expect { sandbox.run(workdir: tmpdir, script: "true") }
        .to raise_error(Runeforge::Sandbox::Unavailable, /couldn't start the container: docker: Error response from daemon.*input\/output error/)
    end

    it "keeps an offline sandbox's services offline too" do
      services = [Runeforge::Devcontainer::Service.new(name: "x", image: "example/x", env: {}, healthcheck: nil)]
      Runeforge::Sandbox::Container.new(runtime:, image: "app", network: "none", cpus: 1, memory: "1g", pids: 64, timeout: 30, services:)
                                   .run(workdir: tmpdir, script: "true")
      expect(log.first).to match(/\Anetwork create --internal \S+-net\z/)
    end
  end

  describe "the runtime check before planning" do
    it "names the pinned version the sandbox image doesn't have" do
      env = build_env("sandbox" => { "mode" => "docker", "image" => "runeforge/general:latest" })
      dir = File.join(tmpdir, "app").tap { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(dir, ".ruby-version"), "ruby-3.4.7\n")
      File.write(File.join(dir, ".nvmrc"), "v22\n")
      probe = instance_double(Runeforge::Sandbox::Container)
      allow(probe).to receive(:run).and_return(Runeforge::Sandbox::Result.new(exit_code: 0, stdout: "3.3.12\n22.4.1\n", stderr: "", timed_out: false))
      allow(env).to receive(:new_sandbox).with(image: "runeforge/general:latest", project: anything, services: false).and_return(probe)
      Runeforge::Platform.instance_variable_set(:@runtimes, nil)

      expect(Runeforge::Platform.pinned_runtimes(dir)).to eq("ruby" => "3.4.7", "node" => "22")
      expect(Runeforge::Platform.runtime_mismatch(env, { name: "app" }, dir))
        .to eq("the project pins ruby 3.4.7 (it has ruby 3.3.12), which the sandbox image runeforge/general:latest doesn't match")
      File.write(File.join(dir, ".ruby-version"), "3.3\n")
      expect(Runeforge::Platform.runtime_mismatch(env, { name: "app" }, dir)).to be_nil
      expect(Runeforge::Platform.runtime_mismatch(build_env, { name: "app" }, dir)).to be_nil # no container, no check

      # A container that doesn't start (Docker broken) isn't a version mismatch.
      File.write(File.join(dir, ".ruby-version"), "3.4.7\n")
      Runeforge::Platform.instance_variable_set(:@runtimes, nil)
      allow(probe).to receive(:run).and_return(Runeforge::Sandbox::Result.new(exit_code: 125, stdout: "", stderr: "input/output error", timed_out: false))
      expect(Runeforge::Platform.runtime_mismatch(env, { name: "app" }, dir)).to be_nil
      expect(Runeforge::Platform.instance_variable_get(:@runtimes)).to be_empty
    ensure
      Runeforge::Platform.instance_variable_set(:@runtimes, nil)
    end
  end
end
