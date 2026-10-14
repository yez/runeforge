# frozen_string_literal: true

module Runeforge
  module Roles
    # Writes the spec, the acceptance tests and any scaffolding needed to run them. Only test
    # files become locked paths. It also reports how to run the tests and which tools they need.
    class Planner < Base
      TOOL = /\A[A-Za-z0-9][\w.+-]{0,63}\z/

      def call
        with_workspace(task[:base_sha], "plan") { |workspace| plan(workspace) }
      end

      private

      def plan(workspace)
        input = msg.payload.fetch("input", {})
        verdict = check_platform(workspace, input)
        if verdict.incompatible?
          return result("plan.failed", { "reason" => "incompatible build environment: #{verdict.reason}. To fix: #{verdict.fix}",
                                         "platform" => verdict.platform })
        end
        if (mismatch = Platform.runtime_mismatch(env, repo, workspace.path))
          env.repos.update(task[:repo], platform_status: "incompatible", platform_note: mismatch, platform_checked_at: Runeforge.now)
          return result("plan.failed", { "reason" => "incompatible build environment: #{mismatch}. To fix: #{runtime_fix}" })
        end

        pitfalls = env.memory.pitfalls(repo: task[:repo], query: [input["title"], input["description"]].compact.join("\n"),
                                       exclude_task: task[:id])
        prompt = Prompts.plan(task:, input:, test_globs:, test_command: repo[:test_command], locked_paths: locked_paths.keys,
                              environment: verdict.environment.description, feedback: msg.payload["feedback"],
                              apple: apple_toolchain(verdict.platform), run_command: repo[:run_command],
                              pitfalls:, setup_command: repo[:setup_command],
                              setup_fixed: !RepoStore.planned(repo).include?("setup_command"))
        # Every plan, a re-plan included, starts a conversation for the coder to continue.
        conversation = conversations? ? env.conversations.start(task_id: task[:id], repo: task[:repo], adapter: agent.adapter.name) : nil
        run = run_agent(workspace, prompt, conversation:, setup: repo[:setup_command])
        updates = usage_updates(run.usage)
        failure = agent_failure(run)
        return failed(failure, run, updates) if failure

        # The agent found it can't build or test this stack here (e.g. an iOS app in a Linux sandbox).
        blocked = workspace.read_meta_text("blocked.md", max_bytes: 16_384).to_s.strip
        unless blocked.empty?
          env.repos.update(task[:repo], platform_status: "incompatible", platform_note: "the planner: #{blocked[0, 1500]}",
                                        platform_checked_at: Runeforge.now)
          return failed("incompatible build environment: the planner can't build this here: #{blocked[0, 1500]}#{blocked_hint}",
                        run, updates)
        end

        project = read_project(workspace)
        if (long = COMMANDS.find { |key| project[key].to_s.size > COMMAND_MAX })
          return failed("#{long} in .runeforge/project.json is #{project[long].size} characters (at most #{COMMAND_MAX}): " \
                        "put the steps in a script you commit with the plan (for example script/runeforge_setup.sh) " \
                        "and make #{long} run it", run, updates, retryable: true)
        end
        if repo[:test_command].to_s.strip.empty? && project["test_command"].to_s.empty?
          return failed("the plan doesn't say how to run the tests (test_command in .runeforge/project.json)", run, updates,
                        retryable: true)
        end

        commit = env.committer(task[:repo]).commit(
          patch: workspace.read_meta("changes.patch", max_bytes: limits["max_patch_bytes"]),
          parent: task[:base_sha], branch: task[:branch],
          message: Committer.message("runeforge: plan for #{task[:id]}", trailers("Agent-Attempt" => "plan")),
          validate: lambda do |changed|
            tests = changed.select { |path| test_path?(path) }
            if tests.empty?
              shown = changed.first(10).join(", ") + (changed.size > 10 ? ", ..." : "")
              raise Committer::PatchRejected, "the plan has no acceptance tests: none of the changed files (#{shown}) match " \
                                              "test_globs; add a glob for this layout under `test_globs` in #{Config.locate}"
            end

            reading_meta = tests.select { |path| reads_runeforge_meta?(workspace, path) }
            next if reading_meta.empty?

            raise Committer::PatchRejected, "acceptance tests #{reading_meta.join(', ')} read .runeforge/, which Runeforge " \
                                            "never commits, so they could never pass; tests must use the project's own files"
          end
        )
        locked = commit.changed_paths.select { |path| test_path?(path) }
                       .to_h { |path| [path, env.repos.oid(task[:repo], commit.sha, path)] }
        if (problem = probe_tests(commit.sha, project))
          return failed(problem, run, updates, retryable: true)
        end

        spec = workspace.read_meta_text("spec.md", max_bytes: limits["max_spec_bytes"]).to_s
        result("plan.done", { "spec" => spec, "locked_paths" => locked, "project" => project, "log_path" => run.log_path,
                              "skipped" => skipped(workspace).then { |list| list.empty? ? nil : list } }.compact,
               commit_sha: commit.sha, task_updates: updates)
      rescue Committer::PatchRejected, Workspace::UnsafeFile => e
        failed(e.message, run, updates || {}, retryable: true)
      end

      # .runeforge/project.json: {"test_command": "...", "setup_command": "...", "run_command": "...",
      # "run_command_new": false, "tools": ["cargo"]}.
      # Written by the agent, so every field is checked before it is used.
      # Commands are never shortened (a cut command is broken shell); one over COMMAND_MAX fails the plan.
      COMMANDS = %w[test_command setup_command run_command].freeze
      COMMAND_MAX = 1000

      def read_project(workspace)
        raw = workspace.read_meta_text("project.json", max_bytes: 16_384)
        data = raw ? JSON.parse(raw) : {}
        return {} unless data.is_a?(Hash)

        {
          "test_command" => data["test_command"].is_a?(String) ? data["test_command"].strip : nil,
          "setup_command" => data["setup_command"].is_a?(String) ? data["setup_command"].strip : nil,
          "run_command" => data["run_command"].is_a?(String) && !data["run_command"].strip.empty? ? data["run_command"].strip : nil,
          "run_command_new" => [true, false].include?(data["run_command_new"]) ? data["run_command_new"] : nil,
          "tools" => Array(data["tools"]).grep(String).grep(TOOL).uniq.first(20)
        }.compact
      rescue JSON::ParserError
        {}
      end

      # Can this project be built where it would be? Decided from the project's files and the
      # request (unless the person already confirmed the request text), recorded on the repo.
      def check_platform(workspace, input)
        paths, read = Platform.scan_dir(workspace.path)
        text = [input["title"], input["description"], input["context"]].compact.join("\n")
        need = Platform.detect(paths:, read:, text:, files_only: input["platform_confirmed"] == true)
        Platform.verdict(env, repo, need).tap do |verdict|
          env.repos.update(task[:repo], platform: verdict.platform, platform_status: verdict.status,
                                        platform_note: verdict.incompatible? ? "#{verdict.reason}. To fix: #{verdict.fix}" : verdict.reason,
                                        platform_checked_at: Runeforge.now)
        end
      end

      def blocked_hint
        return "" unless env.sandboxed?(repo)

        " (#{runtime_fix})"
      end

      # How to give a sandboxed project the toolchain it needs.
      def runtime_fix
        dir = repo[:url].to_s.start_with?("/") ? repo[:url] : "DIR"
        retry_with = "then run `runeforge resume -d #{dir} --retry`"
        devcontainer = repo[:devcontainer] && JSON.parse(repo[:devcontainer])
        if devcontainer&.dig("error") && !devcontainer["tag"]
          "the project's devcontainer (#{devcontainer['path']}) didn't build, so the general image was used: " \
            "#{devcontainer['error'].lines.first.strip}. Fix that, #{retry_with}"
        elsif devcontainer
          "the sandbox is the project's devcontainer image #{repo[:image]}: add what's missing to " \
            "#{devcontainer['path']} and commit it, #{retry_with}; or set `sandbox: none` for this " \
            "project under `projects:` in #{Config.locate} to build on this machine"
        else
          "commit a .devcontainer/devcontainer.json with the project's image and services (Runeforge builds it into the " \
            "sandbox image), #{retry_with}; or set `sandbox: none` for this project under `projects:` in #{Config.locate} " \
            "to build on this machine"
        end
      end

      # A test file that mentions .runeforge/ (read by the planner's own workspace copy, which is
      # the file being committed). Agent-written, so read like any meta file: no symlinks.
      def reads_runeforge_meta?(workspace, path)
        file = File.join(workspace.path, path)
        return false if File.symlink?(file) || !File.file?(file) || File.size(file) > 1_000_000

        File.binread(file).include?(".runeforge/")
      end

      # Runs the plan's test command once on a clean export of the plan commit. Tests failing is
      # expected; tests not running at all means the command can never pass, and tests that don't
      # compile were never checked against the locked ones, so either fails the plan.
      def probe_tests(sha, project)
        # The commands the tester will use once this plan is recorded (see Supervisor#apply_project!).
        test_command = RepoStore.command(repo, "test_command", project)
        return nil if test_command.empty?

        setup = RepoStore.command(repo, "setup_command", project)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        run = with_workspace(sha, "probe") do |workspace|
          sandbox.run(workdir: workspace.path, script: TestProbe.script(test_command), env: TestProbe.env(setup))
        end
        raw = [run.stdout, run.stderr].reject(&:empty?).join("\n")
        # Kept so a slow or puzzling probe can be looked into: <logs>/<task>/<message>-probe.log.
        seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
        write_log("probe", "$ #{setup.empty? ? '' : "#{setup} && "}#{test_command}\n" \
                           "# exit #{run.exit_code.inspect} after #{seconds}s\n\n#{raw}")
        output = TestProbe.clean(raw)
        if (setup_failed = TestProbe.setup_failure(raw))
          what = setup_failed == "syntax" ? "isn't valid shell" : "failed (exit status #{run.exit_code})"
          return "the setup command `#{setup[0, 300]}` #{what}, so no test ran. Fix setup_command; put anything longer " \
                 "than a line or two in a script committed with the plan and run that. Output: #{tail(output, 1500)}"
        end
        errors = run.exit_code.to_i.zero? ? [] : TestProbe.load_errors(output)
        return load_failed(errors) if errors.any?
        if (why = TestProbe.nothing_ran(output, run.exit_code))
          return "the test command `#{test_command}` didn't run the acceptance tests (#{why}): #{tail(output, 1500)}"
        end
        return nil unless (why = TestProbe.build_failed(output, run.exit_code))

        "the tests don't compile (#{why}), so none of them ran: neither your new tests nor the locked tests from " \
          "earlier steps, and nothing showed whether your assertions can pass alongside them. Add the smallest stubs of " \
          "the new types and functions to the source (placeholder bodies that return empty or default values; never " \
          "crash or trap) so the suite builds, then run test_command again: the locked tests must pass and each new " \
          "test must fail on its own assertion. Output: #{tail(output.gsub(TestProbe::ANSI, ''), 1500)}"
      end

      # rspec stops before running anything when a spec file raises while loading, most often by
      # naming a class the step hasn't built yet (`RSpec.describe Foo::Bar`).
      def load_failed(errors)
        shown = errors.first(3).join("\n\n")
        advice = if shown.match?(/NameError|uninitialized constant/)
                   " A spec must load before the code it tests exists: describe a class that doesn't exist yet " \
                     "with a string (`RSpec.describe \"Foo::Bar\"`), and refer to new constants only inside examples."
                 else
                   ""
                 end
        "rspec couldn't load #{errors.size == 1 ? 'a spec file' : "#{errors.size} spec files"}, which stops the whole " \
          "run, so no test ran: neither your new tests nor the locked tests from earlier steps.#{advice} " \
          "Fix it so every new test fails on its own assertion. #{shown}"
      end

      # Retryable: a mistake in the plan the planner can fix when told (see the workflow), as
      # opposed to one it can't (no toolchain here, the agent itself failing).
      def failed(reason, run, updates, retryable: false)
        payload = { "reason" => reason, "log_path" => run&.log_path, "retryable" => retryable || nil }.compact
        result("plan.failed", payload, task_updates: updates)
      end

      def test_globs = env.config["test_globs"]

      def test_path?(path)
        test_globs.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
      end
    end

    register "planner", Planner
  end
end
