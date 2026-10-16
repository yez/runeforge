# frozen_string_literal: true

module Runeforge
  module Roles
    # Looks at a step's UI changes the way a person would, before they're merged: an agent starts
    # the app in the sandbox (with the project's services, a Selenium browser included), opens the
    # screens the planner's UI brief names at desktop and phone widths, screenshots them and judges
    # them against the brief and the app's existing screens. Blocking issues go back to the coder.
    # Only for tasks whose plan changes the UI (tasks.ui_brief; see Prompts.ui_section). The
    # deterministic Reviewer has already approved the work.
    class UxReviewer < Base
      SEVERITIES = %w[blocker major minor].freeze
      BLOCKING = %w[blocker major].freeze
      RESULT = "ux_review.json"
      SHOTS = "ux"
      MAX_SHOTS = 30
      SHOT_BYTES = 5_000_000
      IMAGE = /\.(?:png|jpe?g|webp)\z/i

      def call
        sha = msg.commit_sha
        with_workspace(sha, "ux") { |workspace| review(workspace, sha) }
      end

      private

      def review(workspace, sha)
        prompt = Prompts.ux_review(task:, brief: task[:ui_brief].to_s, browser: browser,
                                   changed: env.repos.changed_files(task[:repo], from: task[:base_sha], to: sha).first(200),
                                   run_command: repo[:run_command], setup_command: repo[:setup_command])
        run = run_agent(workspace, prompt, setup: repo[:setup_command])
        updates = usage_updates(run.usage)
        shots = keep_screenshots(workspace)
        failure = agent_failure(run)
        return skipped("the UX reviewer's agent failed: #{failure}", run, shots, updates) if failure

        report = read_report(workspace)
        return skipped("the UX reviewer wrote no #{Workspace::META_DIR}/#{RESULT}", run, shots, updates) unless report

        verdict(report, run, shots, updates, sha)
      end

      # A review that couldn't run doesn't block the merge (the tests and the deterministic review
      # passed), but says so wherever the verdict is shown.
      def skipped(why, run, shots, updates)
        result("ux.verdict", { "approved" => true, "reasons" => [], "notes" => ["UX review skipped: #{why}"],
                               "screenshots" => shots, "log_path" => run&.log_path }.compact,
               commit_sha: msg.commit_sha, task_updates: updates)
      end

      def verdict(report, run, shots, updates, sha)
        issues = Array(report["issues"]).grep(Hash).first(40).map do |issue|
          severity = SEVERITIES.include?(issue["severity"].to_s) ? issue["severity"].to_s : "major"
          { "severity" => severity, "screen" => issue["screen"].to_s[0, 200], "problem" => issue["problem"].to_s[0, 800],
            "fix" => issue["fix"].to_s[0, 800] }
        end
        blocking = issues.select { |issue| BLOCKING.include?(issue["severity"]) }
        browser = report["browser"].to_s[0, 100]
        notes = issues.reject { |issue| BLOCKING.include?(issue["severity"]) }.map { |issue| describe(issue) }
        notes.unshift("UX review had no browser and judged the markup only") if browser.empty? || browser == "none"
        reasons = blocking.map { |issue| describe(issue) }
        reasons.unshift(UX_FEEDBACK) if reasons.any?
        result("ux.verdict", { "approved" => blocking.empty?, "reasons" => reasons, "notes" => notes, "issues" => issues,
                               "browser" => browser, "summary" => report["summary"].to_s[0, 2000],
                               "screenshots" => shots, "log_path" => run.log_path }.compact,
               commit_sha: sha, task_updates: updates)
      end

      UX_FEEDBACK = "A UX reviewer opened this step's screens in a browser and found these problems. " \
                    "Fix them in the product (the acceptance tests stay as they are), then check the screens yourself."

      def describe(issue)
        fix = issue["fix"].empty? ? "" : " Fix: #{issue['fix']}"
        "[#{issue['severity']}] #{issue['screen'].empty? ? '' : "#{issue['screen']}: "}#{issue['problem']}#{fix}"
      end

      def read_report(workspace)
        raw = workspace.read_meta_text(RESULT, max_bytes: 200_000)
        data = raw && JSON.parse(raw)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError, Workspace::UnsafeFile
        nil
      end

      # Copies the screenshots to <logs>/<task>/<message>-ux/ for a person to look at.
      def keep_screenshots(workspace)
        names = workspace.meta_files(SHOTS).grep(IMAGE).first(MAX_SHOTS)
        return [] if names.empty?

        dir = File.join(env.logs_dir(task[:id]), "#{msg.id}-ux")
        FileUtils.mkdir_p(dir)
        names.filter_map do |name|
          bytes = workspace.read_meta(File.join(SHOTS, name), max_bytes: SHOT_BYTES)
          next unless bytes

          path = File.join(dir, name)
          File.binwrite(path, bytes)
          path
        rescue Workspace::UnsafeFile
          nil
        end
      end

      # The browsers the review can use: the project's browser services (a devcontainer's Selenium),
      # and the name the app's own container has on their network.
      def browser
        devcontainer = repo[:devcontainer] && JSON.parse(repo[:devcontainer])
        services = Array(devcontainer&.dig("services"))
        browsers = services.select { |service| service["image"].to_s.match?(Sandbox::Container::BROWSER_IMAGE) }
        env_vars = (devcontainer&.dig("env") || {}).select { |name, _| name.match?(/SELENIUM|BROWSER|CHROME|CAPYBARA|PLAYWRIGHT/) }
        { services: browsers.map { |service| { name: service["name"], image: service["image"] } },
          app_host: devcontainer&.dig("main"), env: env_vars, sandboxed: env.sandboxed?(repo) }
      rescue JSON::ParserError
        { services: [], app_host: nil, env: {}, sandboxed: env.sandboxed?(repo) }
      end
    end

    register "ux_reviewer", UxReviewer
  end
end
