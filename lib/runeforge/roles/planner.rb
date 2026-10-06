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

        prompt = Prompts.plan(task:, input:, test_globs:, test_command: repo[:test_command], locked_paths: locked_paths.keys,
                              environment: verdict.environment.description, feedback: msg.payload["feedback"])
        run = run_agent(workspace, prompt)
        updates = usage_updates(run.usage)
        failure = agent_failure(run)
        return failed(failure, run, updates) if failure

        # The agent found it can't build or test this stack here (e.g. an iOS app in a Linux sandbox).
        blocked = workspace.read_meta_text("blocked.md", max_bytes: 16_384).to_s.strip
        unless blocked.empty?
          env.repos.update(task[:repo], platform_status: "incompatible", platform_note: "the planner: #{blocked[0, 1500]}",
                                        platform_checked_at: Runeforge.now)
          return failed("the planner can't build this here: #{blocked[0, 1500]}#{blocked_hint}", run, updates)
        end

        project = read_project(workspace)
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
        result("plan.done", { "spec" => spec, "locked_paths" => locked, "project" => project, "log_path" => run.log_path },
               commit_sha: commit.sha, task_updates: updates)
      rescue Committer::PatchRejected, Workspace::UnsafeFile => e
        failed(e.message, run, updates || {}, retryable: true)
      end

      # .runeforge/project.json: {"test_command": "...", "setup_command": "...", "run_command": "...",
      # "run_command_new": false, "tools": ["cargo"]}.
      # Written by the agent, so every field is checked before it is used.
      def read_project(workspace)
        raw = workspace.read_meta_text("project.json", max_bytes: 16_384)
        data = raw ? JSON.parse(raw) : {}
        return {} unless data.is_a?(Hash)

        {
          "test_command" => data["test_command"].is_a?(String) ? data["test_command"].strip[0, 500] : nil,
          "setup_command" => data["setup_command"].is_a?(String) ? data["setup_command"].strip[0, 500] : nil,
          "run_command" => data["run_command"].is_a?(String) && !data["run_command"].strip.empty? ? data["run_command"].strip[0, 500] : nil,
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

        " (to build on this machine instead, set `sandbox: none` for this project under `projects:` in runeforge.yml)"
      end

      # A test file that mentions .runeforge/ (read by the planner's own workspace copy, which is
      # the file being committed). Agent-written, so read like any meta file: no symlinks.
      def reads_runeforge_meta?(workspace, path)
        file = File.join(workspace.path, path)
        return false if File.symlink?(file) || !File.file?(file) || File.size(file) > 1_000_000

        File.binread(file).include?(".runeforge/")
      end

      # Runs the plan's test command once on a clean export of the plan commit. Tests failing is
      # expected; tests not running at all means the command can never pass, so the plan fails.
      def probe_tests(sha, project)
        # Same precedence as the tester: the repo's command once set, else the plan's.
        test_command = repo[:test_command].to_s.strip
        test_command = project["test_command"].to_s.strip if test_command.empty?
        return nil if test_command.empty?

        setup = (repo[:setup_command].to_s.strip.empty? ? project["setup_command"] : repo[:setup_command]).to_s.strip
        script = [setup, test_command].reject(&:empty?).join(" && ")
        run = with_workspace(sha, "probe") { |workspace| sandbox.run(workdir: workspace.path, script:, env: {}) }
        output = [run.stdout, run.stderr].reject(&:empty?).join("\n")
        why = TestProbe.nothing_ran(output, run.exit_code)
        return nil unless why

        "the test command `#{test_command}` didn't run the acceptance tests (#{why}): #{tail(output, 1500)}"
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
