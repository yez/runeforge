# frozen_string_literal: true

RSpec.describe Runeforge::Sandbox do
  describe Runeforge::Sandbox::Local do
    let(:sandbox) { described_class.new(timeout: 1) }

    it "runs with a scrubbed environment" do
      ENV["RUNEFORGE_SPEC_SECRET"] = "hunter2"
      result = sandbox.run(workdir: tmpdir, script: 'echo "${RUNEFORGE_SPEC_SECRET:-unset} $EXTRA"', env: { "EXTRA" => "given" })
      expect(result.stdout.strip).to eq("unset given")
    ensure
      ENV.delete("RUNEFORGE_SPEC_SECRET")
    end

    it "kills the whole process group on timeout" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = sandbox.run(workdir: tmpdir, script: "sleep 30 & sleep 30")
      expect(result.timed_out).to be(true)
      expect(result.success?).to be(false)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
    end

    it "hands output to on_output as it arrives" do
      chunks = []
      result = sandbox.run(workdir: Dir.pwd, script: "echo out; echo err >&2",
                           on_output: ->(chunk, stream) { chunks << [stream, chunk] })
      expect(chunks).to contain_exactly(["stdout", "out\n"], ["stderr", "err\n"])
      expect(result.stdout).to eq("out\n")
    end

    it "reports the exit status" do
      expect(sandbox.run(workdir: tmpdir, script: "exit 3").exit_code).to eq(3)
    end
  end

  describe Runeforge::Sandbox::Container do
    let(:container) do
      described_class.new(runtime: "docker", image: "alpine:3.20", network: "none", cpus: 1, memory: "256m",
                          pids: 64, timeout: 60)
    end

    it "builds a locked-down docker run command that passes secrets by name" do
      container.instance_variable_set(:@id, "runeforge-test")
      argv = container.argv("/ws", "true", ["ANTHROPIC_API_KEY"])
      expect(argv.each_cons(2).to_a).to include(
        ["--network", "none"], ["--tmpfs", "/tmp:rw,exec,size=1g"], ["--pids-limit", "64"],
        ["--security-opt", "no-new-privileges"], ["--cap-drop", "ALL"], ["-v", "/ws:/workspace"],
        ["-e", "ANTHROPIC_API_KEY"]
      )
      expect(argv).to include("--read-only", "--rm")
      expect(argv.join(" ")).not_to include("sk-")
    end

    it "uses every CPU the runtime has with cpus: auto, and caps them with a number" do
      container.instance_variable_set(:@id, "runeforge-test")
      expect(container.argv("/ws", "true", []).each_cons(2).to_a).to include(["--cpus", "1"])

      auto = described_class.new(runtime: "docker", image: "alpine:3.20", network: "none", cpus: "auto", memory: "256m",
                                 pids: 64, timeout: 60)
      auto.instance_variable_set(:@id, "runeforge-test")
      expect(auto.argv("/ws", "true", [])).not_to include("--cpus")
      expect(auto.argv("/ws", "true", [], volumes: { "deps" => "node_modules" }).each_cons(2).to_a)
        .to include(["-v", "deps:/workspace/node_modules"])
    end

    describe "dependency volumes" do
      # A container runtime that logs its arguments and knows the volumes it created.
      let(:runtime) do
        path = File.join(tmpdir, "fake-docker")
        File.write(path, <<~SH)
          #!/bin/sh
          echo "$*" >> #{tmpdir}/runtime.log
          case "$1 $2" in
            "volume inspect") [ -f "#{tmpdir}/vol-$3" ] || exit 1 ;;
            "volume create") for last; do :; done; touch "#{tmpdir}/vol-$last" ;;
          esac
          exit 0
        SH
        File.chmod(0o755, path)
        path
      end
      let(:sandbox) do
        described_class.new(runtime:, image: "app", network: "bridge", cpus: "auto", memory: "1g", pids: 64, timeout: 30,
                            user: "501:20", dependency_cache: "My App")
      end

      def log = File.readlines(File.join(tmpdir, "runtime.log"), chomp: true)

      def workspace(name, files)
        File.join(tmpdir, name).tap do |dir|
          FileUtils.mkdir_p(dir)
          files.each { |file, body| File.write(File.join(dir, file), body) }
        end
      end

      it "keeps a Node project's node_modules in a volume per manifest, made once and owned by the run's user" do
        first = workspace("one", "package.json" => "{}", "package-lock.json" => "{}")
        sandbox.run(workdir: first, script: "true")
        volume = log.grep(/\Avolume create/).first.split.last
        expect(volume).to match(/\Aruneforge-deps-my-app-node_modules-\h{12}\z/)
        expect(log).to include("volume create --label runeforge.project=my-app --label runeforge.dependencies=node_modules #{volume}",
                               "run --rm --network none --user 0 --entrypoint chown -v #{volume}:/deps app 501:20 /deps")
        expect(log.last).to include("-v #{volume}:/workspace/node_modules")

        File.delete(File.join(tmpdir, "runtime.log"))
        sandbox.run(workdir: workspace("two", "package.json" => "{}", "package-lock.json" => "{}"), script: "true")
        expect(log.grep(/\Avolume create/)).to be_empty
        expect(log.last).to include("-v #{volume}:/workspace/node_modules")

        sandbox.run(workdir: workspace("three", "package.json" => '{"dependencies": {"x": "1"}}'), script: "true")
        expect(log.grep(/\Avolume create/).size).to eq(1)
        expect(log.last).to include("/workspace/node_modules")
        expect(log.last).not_to include(volume)
      end

      it "leaves projects without one, committed dependencies and dependency_volumes: false alone" do
        sandbox.run(workdir: workspace("plain", "Gemfile" => ""), script: "true")
        committed = workspace("committed", "package.json" => "{}")
        FileUtils.mkdir_p(File.join(committed, "node_modules"))
        sandbox.run(workdir: committed, script: "true")
        off = described_class.new(runtime:, image: "app", network: "bridge", cpus: "auto", memory: "1g", pids: 64, timeout: 30)
        off.run(workdir: workspace("off", "package.json" => "{}"), script: "true")
        expect(log.grep(/volume|node_modules/)).to be_empty
      end
    end

    context "with a running Docker daemon", if: system("docker info >/dev/null 2>&1") do
      it "keeps what a run installed for the next run's workspace" do
        sandbox = described_class.new(runtime: "docker", image: "alpine:3.20", network: "none", cpus: "auto", memory: "256m",
                                      pids: 64, timeout: 60, dependency_cache: "spec-#{SecureRandom.hex(4)}")
        dirs = %w[a b].map { |name| File.join(tmpdir, name).tap { |dir| FileUtils.mkdir_p(dir) } }
        dirs.each { |dir| File.write(File.join(dir, "package.json"), "{}") }
        volume = sandbox.dependency_mounts(dirs.first).keys.first
        installed = sandbox.run(workdir: dirs.first, script: "echo kept > node_modules/x && id -u")
        expect(installed.stdout.strip).to eq(Process.uid.to_s)
        expect(sandbox.run(workdir: dirs.last, script: "cat node_modules/x").stdout).to eq("kept\n")
      ensure
        system("docker", "volume", "rm", "-f", volume, out: File::NULL, err: File::NULL) if volume
      end

      it "keeps host secrets and the host filesystem out of the container" do
        ENV["RUNEFORGE_SPEC_SECRET"] = "hunter2"
        script = <<~SH
          echo "secret=${RUNEFORGE_SPEC_SECRET:-unset}"
          touch /etc/owned 2>/dev/null && echo "etc=writable" || echo "etc=readonly"
          touch /workspace/ok && echo "workspace=writable"
          id -u
        SH
        result = container.run(workdir: tmpdir, script:)
        expect(result.stdout).to include("secret=unset", "etc=readonly", "workspace=writable", Process.uid.to_s)
      ensure
        ENV.delete("RUNEFORGE_SPEC_SECRET")
      end

      it "has no network when configured with network none" do
        result = container.run(workdir: tmpdir, script: "wget -q -T 3 -O- http://example.com >/dev/null 2>&1 && echo online || echo offline")
        expect(result.stdout).to include("offline")
      end
    end
  end
end
