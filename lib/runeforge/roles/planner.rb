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
        prompt = Prompts.plan(task:, input: msg.payload.fetch("input", {}), test_globs:,
                              test_command: repo[:test_command], locked_paths: locked_paths.keys)
        run = run_agent(workspace, prompt)
        updates = usage_updates(run.usage)
        failure = agent_failure(run)
        return failed(failure, run, updates) if failure

        project = read_project(workspace)
        if repo[:test_command].to_s.strip.empty? && project["test_command"].to_s.empty?
          return failed("the plan doesn't say how to run the tests (test_command in .runeforge/project.json)", run, updates)
        end

        commit = env.committer(task[:repo]).commit(
          patch: workspace.read_meta("changes.patch", max_bytes: limits["max_patch_bytes"]),
          parent: task[:base_sha], branch: task[:branch],
          message: Committer.message("runeforge: plan for #{task[:id]}", trailers("Agent-Attempt" => "plan")),
          validate: lambda do |changed|
            next if changed.any? { |path| test_path?(path) }

            raise Committer::PatchRejected, "the plan has no acceptance tests (no changed file matches test_globs)"
          end
        )
        locked = commit.changed_paths.select { |path| test_path?(path) }
                       .to_h { |path| [path, env.repos.oid(task[:repo], commit.sha, path)] }
        spec = workspace.read_meta_text("spec.md", max_bytes: limits["max_spec_bytes"]).to_s
        result("plan.done", { "spec" => spec, "locked_paths" => locked, "project" => project, "log_path" => run.log_path },
               commit_sha: commit.sha, task_updates: updates)
      rescue Committer::PatchRejected, Workspace::UnsafeFile => e
        failed(e.message, run, updates || {})
      end

      # .runeforge/project.json: {"test_command": "...", "setup_command": "...", "tools": ["cargo"]}.
      # Written by the agent, so every field is checked before it is used.
      def read_project(workspace)
        raw = workspace.read_meta_text("project.json", max_bytes: 16_384)
        data = raw ? JSON.parse(raw) : {}
        return {} unless data.is_a?(Hash)

        {
          "test_command" => data["test_command"].is_a?(String) ? data["test_command"].strip[0, 500] : nil,
          "setup_command" => data["setup_command"].is_a?(String) ? data["setup_command"].strip[0, 500] : nil,
          "tools" => Array(data["tools"]).grep(String).grep(TOOL).uniq.first(20)
        }.compact
      rescue JSON::ParserError
        {}
      end

      def failed(reason, run, updates)
        result("plan.failed", { "reason" => reason, "log_path" => run&.log_path }, task_updates: updates)
      end

      def test_globs = env.config["test_globs"]

      def test_path?(path)
        test_globs.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
      end
    end

    register "planner", Planner
  end
end
