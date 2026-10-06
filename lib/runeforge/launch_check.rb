# frozen_string_literal: true

module Runeforge
  # Runs an Apple project's run command before its work is merged and checks the app really
  # launched and kept running. Tests can pass while the run script is broken (a wordreel script
  # ran `open -a Simulator` on Xcode 27, which has no Simulator.app, warned and carried on), and
  # the first person to notice was the one trying to play it. The reviewer runs this; a failure
  # sends the work back to the coder with the reasons.
  class LaunchCheck
    Outcome = Data.define(:reasons, :note) do
      def ok? = reasons.empty?
    end

    # Output that means the script couldn't do part of its job, even if it exited 0. Specific on
    # purpose: xcodebuild prints harmless "warning:" lines of its own (stale files, destinations).
    PROBLEMS = [
      /Unable to find application named '[^']*'/,
      /\bcould not open\b.*/i,
      /No available simulator.*/,
      /Built app not found.*/,
      /An error was encountered processing the command.*/, # simctl install/launch/boot failures
      /The application.*cannot be (?:installed|launched).*/i
    ].freeze
    # What `xcrun simctl launch` prints: "<bundle id>: <pid>".
    LAUNCHED = /^([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+): (\d+)\s*$/
    SETTLE_SECONDS = 5

    def initialize(env, repo, settle: SETTLE_SECONDS)
      @env = env
      @repo = repo
      @settle = settle
    end

    # Whether the reviewer should run it for this project.
    def self.applies?(env, repo)
      repo[:platform] == "apple" && !repo[:run_command].to_s.strip.empty? && Platform.mac? &&
        !env.sandboxed?(repo) && !env.dry_run? && env.config.for_project(repo, "launch_check") != false
    end

    # Runs the setup and run commands in `workdir` (an export of the commit under review).
    def call(workdir)
      script = [@repo[:setup_command], @repo[:run_command]].map(&:to_s).map(&:strip).reject(&:empty?).join(" && ")
      run = Sandbox::Local.new(timeout: @env.config["limits"]["launch_check_seconds"])
                          .run(workdir:, script:, env: { "RUNEFORGE_LAUNCH_CHECK" => "1" })
      output = [run.stdout, run.stderr].join("\n").scrub
      reasons, bundle = self.class.problems(output, run.exit_code, run.timed_out, command: @repo[:run_command])
      return Outcome.new(reasons:, note: nil) if reasons.any?

      sleep @settle
      device = booted_devices.find { |udid, _| running?(udid, bundle) }
      booted_devices.each_key { |udid| terminate(udid, bundle) }
      return Outcome.new(reasons: ["#{bundle} launched but isn't running #{@settle} s later (it crashed or quit at startup)"], note: nil) unless device

      Outcome.new(reasons: [], note: "launch check: `#{@repo[:run_command]}` launched #{bundle} on #{device.last}")
    end

    # What's wrong with a run of the run command, and the bundle id it launched (nil if none).
    def self.problems(output, exit_code, timed_out, command:)
      tail = output.lines.last(15).join.strip
      reasons = []
      reasons << "`#{command}` timed out" if timed_out
      reasons << "`#{command}` failed (exit status #{exit_code}): #{tail[-1500..] || tail}" if !timed_out && exit_code != 0
      found = PROBLEMS.flat_map { |pattern| output.scan(pattern).map { |m| m.is_a?(Array) ? m.first : m } }.compact.map(&:strip).uniq
      # "warning: could not open X" matches two patterns; keep the longer line only.
      found = found.reject { |line| found.any? { |other| other != line && other.include?(line) } }
      reasons.concat(found.first(5).map { |line| "`#{command}` printed: #{line}" })
      bundle = output.lines.filter_map { |line| line[LAUNCHED, 1] }.last
      if bundle.nil? && reasons.empty?
        reasons << "`#{command}` didn't launch the app: no `<bundle id>: <pid>` line from `xcrun simctl launch` in its output"
      end
      [reasons.uniq, bundle]
    end

    private

    # Booted simulators: udid => name.
    def booted_devices
      @booted_devices ||= begin
        out, ok = Platform.capture("xcrun", "simctl", "list", "devices", "booted", "-j")
        ok ? JSON.parse(out).fetch("devices", {}).values.flatten.to_h { |d| [d["udid"], d["name"]] } : {}
      rescue JSON::ParserError
        {}
      end
    end

    def running?(udid, bundle)
      out, ok = Platform.capture("xcrun", "simctl", "spawn", udid, "launchctl", "list")
      ok && out.include?("UIKitApplication:#{bundle}[")
    end

    def terminate(udid, bundle) = Platform.capture("xcrun", "simctl", "terminate", udid, bundle)
  end
end
