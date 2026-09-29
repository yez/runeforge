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

    context "with a running Docker daemon", if: system("docker info >/dev/null 2>&1") do
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
