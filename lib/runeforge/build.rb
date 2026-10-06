# frozen_string_literal: true

require "digest"

module Runeforge
  # `runeforge <file|prompt> [--dir DIR]`: builds in the foreground. A markdown task list runs as
  # one plan/code/test cycle per unchecked item, in order, on one branch. Without --dir it asks
  # for a directory name and creates a new project there.
  class Build
    class DirtyWorkingTree < Error; end

    # A file runs one step per unchecked task-list item; a prompt is one step. See PlanFile.
    def self.parse(input)
      from_file = File.file?(input.to_s)
      PlanFile.parse(from_file ? File.read(input) : input.to_s, list: from_file, source: from_file ? "file" : "prompt")
    end

    def self.slug(text) = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40].sub(/-\z/, "")

    # from: start at this step (see BuildProgress#start); rerun: build every step again, even the
    # ones an earlier run finished. resume: a run from BuildProgress#runs to continue (see .resume).
    def initialize(env, input:, dir: nil, stdin: $stdin, stdout: $stdout, from: nil, rerun: false, resume: nil)
      @env = env
      @dir = dir
      @stdin = stdin
      @out = stdout
      @from = from
      @rerun = rerun
      @resume = resume
      if resume
        @input = resume[:plan]
        @plan_source = resume[:input]["plan"] || { "text" => resume[:input]["context"] || resume[:input]["description"],
                                                   "list" => !resume[:input]["context"].nil?, "source" => "resumed" }
      else
        from_file = File.file?(input.to_s)
        @input = self.class.parse(input)
        # Stored on each task, so `runeforge resume` can rebuild the step list without the file.
        @plan_source = { "text" => from_file ? File.read(input) : input.to_s, "list" => from_file,
                         "source" => from_file ? File.expand_path(input) : "prompt" }
      end
    end

    # `runeforge resume -d DIR`: continues the newest build in DIR that didn't finish (or the run
    # named by `run`), from the plan it stored. Returns nil when there's nothing to resume.
    def self.resume(env, dir:, run: nil, from: nil, stdin: $stdin, stdout: $stdout)
      # Registered as build registers it: the repository's top level, symlinks resolved.
      directory = File.expand_path(dir)
      raise Error, "#{directory} does not exist" unless File.directory?(directory)

      top = Git.run("rev-parse", "--show-toplevel", dir: directory, allow_failure: true)&.strip
      directory = File.realpath(top.to_s.empty? ? directory : top)
      repo = env.repos.list.find do |row|
        url = row[:url].to_s
        url.start_with?("/", "~") && File.directory?(File.expand_path(url)) && File.realpath(File.expand_path(url)) == directory
      end
      raise Error, "no runeforge builds in #{directory}; start one with `runeforge build FILE --dir #{dir}`" unless repo

      runs = BuildProgress.new(env, repo[:name]).runs
      raise Error, "no runeforge builds in #{directory}; start one with `runeforge build FILE --dir #{dir}`" if runs.empty?

      chosen =
        if run
          runs.reverse.find { |r| [r[:id], r[:lane], r[:lane].delete_prefix("fg-")].include?(run) } ||
            raise(Error, "no build run #{run} in #{directory} (runs: #{runs.map { |r| r[:id] }.last(5).join(', ')})")
        else
          runs.reverse.find { |r| !r[:finished] }
        end
      if chosen.nil?
        stdout.puts "Nothing to resume in #{directory}: the last build (#{runs.last[:id]}) finished every step."
        return nil
      end
      raise Error, "can't resume #{chosen[:id]}: its plan isn't stored on its tasks" unless chosen[:plan]

      if chosen[:live]
        busy = chosen[:tasks].reject { |t| TERMINAL_STATUSES.include?(t[:status]) }.last
        raise Error, "#{chosen[:id]} is still running (task #{busy[:id]} is #{busy[:status]}); stop it with " \
                     "`runeforge cancel #{busy[:id]}` or wait for it to finish"
      end
      # A build that was killed leaves its current step unfinished; nothing is driving it any more.
      chosen[:tasks].reject { |t| TERMINAL_STATUSES.include?(t[:status]) }.each do |task|
        env.tasks.cancel(task[:id], reason: "abandoned: its build stopped; continued by runeforge resume")
      end

      stdout.puts "Resuming \"#{chosen[:plan].title}\" (run #{chosen[:id]}, started #{chosen[:started_at]&.strftime('%Y-%m-%d %H:%M')})"
      # Earlier attempts at the same plan are covered by this one (steps are matched by content).
      same_plan = ->(r) { r[:plan] && r[:plan].steps.map(&:key) == chosen[:plan].steps.map(&:key) }
      others = runs.reject { |r| r[:finished] || r.equal?(chosen) || same_plan.call(r) }
      stdout.puts "  Other unfinished runs here: #{others.map { |r| r[:id] }.join(', ')} (pick one with --run)" if others.any?
      new(env, input: nil, dir: directory, resume: chosen, from:, stdin:, stdout:)
    end

    # Returns true when every step finished.
    # Above this many steps, a foreground build asks before starting (a misread plan file can
    # turn every bullet into a step).
    CONFIRM_STEPS = 10

    def run
      project = @dir ? { name: nil, url: File.expand_path(@dir) } : nil
      # In an existing project the step list is shown with what earlier runs finished (plan_start).
      confirm_steps! unless @dir
      platform_check!(project)
      @env.check_agent_credentials!(project:)
      directory, created = resolve_directory
      Setup.new(config_path: Config.locate, out: @out).prepare(@env)
      repo = @registered = register(directory)
      start = plan_start(repo)
      return nothing_left(directory) if start.skip == @input.steps.size

      # Manual merging stacks every step on one branch, so a continued build keeps adding to it.
      branch = (!merging? && start.branch) || unique_branch(directory, repo)
      remaining = @input.steps.size - start.skip
      from = start.skip.positive? ? ", from step #{start.skip + 1}" : ""
      @out.puts "\nBuilding \"#{@input.title}\" in #{directory} on branch #{branch} (#{plural(remaining, 'step')}#{from})"

      finished = run_steps(repo, branch, start)
      report(directory, branch, created, finished)
      finished
    ensure
      @worker&.unregister
    end

    private

    # --- before starting ----------------------------------------------------------------------

    def confirm_steps!
      return unless @input.multi_step?

      @out.puts "#{@input.steps.size} steps:"
      @input.steps.each_with_index { |step, index| @out.puts format("  %2d. %s", index + 1, step.title) }
      return if @input.steps.size <= CONFIRM_STEPS

      answer = ask("Build all #{@input.steps.size} steps? [y/N]: ")
      raise Error, "stopped before building; nothing was changed" unless answer.casecmp?("y")
    end

    # A platform-specific app (iOS, macOS, Android) needs its vendor's toolchain where it's built
    # (see Platform). Explain before any tokens are spent; continuing tells the planner the
    # person accepted the request's wording (its project files are still checked).
    def platform_check!(project)
      return if @env.dry_run?

      paths, read = Platform.scan_dir(project && project[:url])
      verdict = Platform.verdict(@env, project, Platform.detect(paths:, read:, text: @input.text))
      return unless verdict.incompatible?

      @out.puts "This looks like #{verdict.reason}.\nTo fix: #{verdict.fix}."
      answer = ask("Continue anyway? [y/N]: ")
      raise Error, "stopped before building: #{verdict.fix}" unless answer.casecmp?("y")

      @platform_confirmed = true
    end

    # --- directory ---------------------------------------------------------------------------

    def resolve_directory
      return [prepare_existing(File.expand_path(@dir)), false] if @dir

      default = self.class.slug(@input.title).then { |slug| slug.empty? ? "runeforge-project" : slug }
      name = ask("Directory for the new project [#{default}]: ")
      name = default if name.empty?
      path = File.expand_path(name)
      if File.exist?(path) && !(File.directory?(path) && Dir.empty?(path))
        raise Error, "#{path} already exists and isn't empty; to build in it, run again with --dir #{name}"
      end

      FileUtils.mkdir_p(path)
      git("init", "-q", "-b", "main", dir: path)
      if @env.config.dig("inbox", "enabled")
        Inbox.scaffold.each do |file, content|
          FileUtils.mkdir_p(File.dirname(File.join(path, file)))
          File.write(File.join(path, file), content)
        end
        git("add", "-A", dir: path)
      end
      initial_commit(path)
      @out.puts "Created #{path}"
      [path, true]
    end

    def prepare_existing(path)
      raise Error, "#{path} does not exist" unless File.directory?(path)

      root = Git.run("rev-parse", "--show-toplevel", dir: path, allow_failure: true)&.strip
      unless root
        answer = ask("#{path} is not a git repository. Create one and commit its current files? [y/N]: ")
        raise Error, "runeforge needs a git repository to make branches in; stopped" unless answer.casecmp?("y")

        git("init", "-q", "-b", "main", dir: path)
        git("add", "-A", dir: path)
        initial_commit(path)
        root = path
      end
      root = File.realpath(root)
      @out.puts "Using the repository at #{root}" unless root == File.realpath(path)

      dirty = git("status", "--porcelain", "--untracked-files=normal", dir: root)
      unless dirty.strip.empty?
        lines = dirty.lines.first(10).map { |line| "    #{line.chomp}" }
        lines << "    ... and #{dirty.lines.size - 10} more" if dirty.lines.size > 10
        raise DirtyWorkingTree, "#{root} has uncommitted changes:\n#{lines.join("\n")}\n" \
                                "Commit or stash them, then run runeforge again."
      end

      initial_commit(root) unless Git.run("rev-parse", "--verify", "--quiet", "HEAD", dir: root, allow_failure: true)
      raise Error, "#{root} is on a detached HEAD; check out a branch first" unless current_branch(root)

      root
    end

    def initial_commit(path)
      name = Git.run("config", "user.name", dir: path, allow_failure: true)&.strip
      email = Git.run("config", "user.email", dir: path, allow_failure: true)&.strip
      identity = {
        "GIT_AUTHOR_NAME" => name.to_s.empty? ? "Runeforge" : name, "GIT_AUTHOR_EMAIL" => email.to_s.empty? ? "runeforge@localhost" : email
      }
      identity["GIT_COMMITTER_NAME"] = identity["GIT_AUTHOR_NAME"]
      identity["GIT_COMMITTER_EMAIL"] = identity["GIT_AUTHOR_EMAIL"]
      git("-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "Initial commit", dir: path, env: identity)
    end

    def current_branch(path) = Git.run("symbolic-ref", "--quiet", "--short", "HEAD", dir: path, allow_failure: true)&.strip

    # --- repository and branch ---------------------------------------------------------------

    # One registered repo per directory; the name is stable, so later runs reuse its test command.
    def register(directory)
      name = "#{self.class.slug(File.basename(directory)).then { |s| s.empty? ? 'project' : s }}-#{Digest::SHA256.hexdigest(directory)[0, 6]}"
      existing = @env.repos.table.where(name:).first || {}
      @env.repos.add(name:, url: directory, base_branch: current_branch(directory),
                     test_command: existing[:test_command].to_s, setup_command: existing[:setup_command],
                     image: existing[:image])
      name
    end

    def unique_branch(directory, repo)
      base = "runeforge/#{self.class.slug(@input.title).then { |s| s.empty? ? 'build' : s }}"
      candidates = [base, *(2..99).map { |n| "#{base}-#{n}" }]
      candidates.find do |branch|
        [directory, @env.repos.path(repo)].none? do |path|
          Git.run("rev-parse", "--verify", "--quiet", "refs/heads/#{branch}", dir: path, allow_failure: true)
        end
      end || raise(Error, "too many runeforge branches named #{base}")
    end

    # --- steps -------------------------------------------------------------------------------

    # Where this build starts: after the steps at the start that earlier runs already finished
    # (BuildProgress), once the person agrees. Lists every step with what happens to it.
    def plan_start(repo)
      progress = BuildProgress.new(@env, repo)
      base = @env.repos.refresh(repo)
      # Skipping finished steps is for continuing a plan. A single prompt given again is a request
      # to build it again (on a fresh branch); `runeforge resume` continues one that failed.
      return progress.start(@input, base:, rerun: true) unless @input.multi_step? || @resume

      start = progress.start(@input, base:, from: @from, rerun: @rerun)
      show_progress(start) if @dir
      start.notes.each { |note| @out.puts "  ! #{note}" }
      skip, total = start.skip, @input.steps.size
      if skip.positive? && skip < total && @from.nil? && interactive?
        answer = ask("Skip #{plural(skip, 'finished step')} and start at step #{skip + 1}? [Y/n]: ")
        start = progress.start(@input, base:, rerun: true) if answer.casecmp?("n")
      elsif skip == total && !@resume && interactive?
        answer = ask("Every step is already done. Build them all again? [y/N]: ")
        start = progress.start(@input, base:, rerun: true) if answer.casecmp?("y")
      end
      remaining = total - start.skip
      if @dir && remaining > CONFIRM_STEPS
        answer = ask("Build #{remaining} steps? [y/N]: ")
        raise Error, "stopped before building; nothing was changed" unless answer.casecmp?("y")
      end
      start
    end

    def show_progress(start)
      return unless @input.multi_step? || start.skip.positive?

      @out.puts "#{plural(@input.steps.size, 'step')}:"
      @input.steps.each_with_index do |step, index|
        status =
          if index >= start.skip then nil
          elsif (task = start.done[index]) then "done (task #{task[:id]}, #{(task[:merged_sha] || task[:head_sha]).to_s[0, 7]})"
          else "skipped (--from)"
          end
        @out.puts format("  %s %2d. %s%s", status ? "✓" : "▶", index + 1, step.title, status ? "  #{status}" : "")
      end
    end

    def nothing_left(directory)
      @out.puts "\nNothing to build: every step of \"#{@input.title}\" is done and in #{directory}. " \
                "To build them again, pass --rerun."
      true
    end

    # A person at a terminal can be asked; otherwise (a script, a pipe) the defaults apply.
    def interactive? = @stdin.respond_to?(:tty?) && @stdin.tty?

    def run_steps(repo, branch, start)
      lane = "fg-#{SecureRandom.hex(4)}"
      run_id = "#{self.class.slug(@input.title)[0, 30].sub(/-\z/, '').then { |s| s.empty? ? 'build' : s }}-#{lane.delete_prefix('fg-')}"
      base = start.base
      locked = start.locked
      @steps_run = 0
      budgets = @env.config["budgets"]
      @supervisor = Supervisor.new(@env, lane:)
      @worker = Worker.new(@env, roles: Roles.names, lane:)
      @operator_box = @env.mailbox("operator@#{Socket.gethostname}:#{Process.pid}")
      @operator = Operator.new(@env, input: @stdin, output: @out)
      @lane = lane

      @unmerged = []
      @input.steps.each_with_index do |step, index|
        next if index < start.skip

        @steps_run += 1
        multi = @input.steps.size > 1
        # Merging: each step gets its own branch off the base it starts from. Manual: one branch.
        step_branch = merging? && multi ? "#{branch}-s#{index + 1}" : branch
        task = @env.tasks.create(
          id: multi ? "#{run_id}-s#{index + 1}" : run_id, workflow: "build", repo:, base_sha: base, branch: step_branch, lane:,
          locked_paths: locked, title: step.title, mailbox: @env.mailbox("cli"),
          input: { "title" => step.title, "description" => step.body,
                   "context" => (multi ? @input.text : nil), "step" => "#{index + 1} of #{@input.steps.size}",
                   "step_key" => step.key, "plan" => @plan_source,
                   "platform_confirmed" => @platform_confirmed }.compact,
          max_attempts: budgets["max_attempts"], token_budget: budgets["token_budget"],
          deadline_at: budgets["max_task_minutes"] && (Runeforge.now + (budgets["max_task_minutes"] * 60))
        )
        @out.puts "\n#{multi ? "Step #{index + 1}/#{@input.steps.size}: " : ''}#{step.title}  (task #{task[:id]})"
        finished = drive(task[:id])
        return false unless finished[:status] == "done"

        # The next step starts from the merged base, or stacks on this step if it wasn't merged.
        if finished[:merged_sha]
          base = @env.repos.refresh(repo)
        else
          base = finished[:head_sha]
          @unmerged << step_branch
        end
        locked = JSON.parse(finished[:locked_paths] || "{}")
      end
      true
    end

    def drive(task_id)
      @current = task_id
      previous = trap("INT") { Thread.new { cancel_current } }
      last = 0
      loop do
        @supervisor.tick
        @env.tasks.messages(task_id, after: last).each do |msg|
          line = describe(msg)
          @out.puts "  #{line}" if line
          last = msg.id
        end
        task = @env.tasks.find!(task_id)
        return task if TERMINAL_STATUSES.include?(task[:status]) || task[:status] == "blocked"
        next if answer_operator || @worker.work_once

        sleep @env.config["poll_seconds"]
      end
    ensure
      trap("INT", previous || "DEFAULT")
    end

    def cancel_current
      @env.tasks.cancel(@current, reason: "interrupted from the terminal")
    rescue Error
      nil
    ensure
      @worker.interrupt
    end

    def answer_operator
      msg = @operator_box.claim(Runeforge.recipient(@lane, "operator"))
      return false unless msg

      @operator_box.complete(msg, **@operator.call(msg))
      true
    rescue Mailbox::LeaseLost
      true
    end

    # One line per message, or nil to stay quiet.
    def describe(msg)
      payload = msg.payload
      sha = msg.commit_sha.to_s[0, 7]
      case msg.type
      when "plan.request" then "· planning"
      when "plan.done" then "✓ planned: #{plural(payload['locked_paths'].size, 'test file')} locked (#{sha})"
      when "plan.failed" then "✗ planning failed: #{payload['reason']}"
      when "deps.check" then "· checking tools: #{Array(payload['tools']).join(', ')}"
      when "deps.ready" then "✓ tools available"
      when "deps.declined" then "✗ stopped: missing #{Array(payload['missing']).join(', ')}"
      when "code.request" then "· coding (attempt #{payload['attempt']})"
      when "code.done" then "✓ coded: #{plural(Array(payload['changed_paths']).size, 'file')} changed (#{sha})"
      when "code.failed" then "✗ attempt #{payload['attempt']} failed: #{payload['reason'].to_s.lines.first&.strip}"
      when "test.request" then "· testing #{sha}"
      when "test.result"
        line = payload["passed"] ? "✓ tests passed" : "✗ #{payload['reason'] || 'tests failed'}"
        [line, *Array(payload["warnings"]).map { |warning| "  ! #{warning}" }].join("\n  ")
      when "review.request" then "· checking locked tests"
      when "review.verdict"
        verdict = payload["approved"] ? "✓ locked tests untouched" : "✗ #{Array(payload['reasons']).join('; ')}"
        [verdict, *Array(payload["notes"]).map { |note| "  note: #{note}" }].join("\n  ")
      when "integrate.request" then merging? ? "· merging" : "· updating the branch"
      when "integrate.done"
        line = payload["merged"] ? "✓ merged into #{payload['base']}" : "✓ branch #{payload['branch']} updated"
        line += " (#{payload['pr_url']})" if payload["pr_url"]
        [line, *Array(payload["warnings"]).map { |warning| "  ! #{warning}" }].join("\n  ")
      when "integrate.failed" then "✗ could not update the branch: #{payload['reason']}"
      end
    end

    def report(directory, branch, created, finished)
      task = @env.tasks.find(@current) if @current
      if finished && merging?
        base = @env.repos.fetch(@registered)[:base_branch]
        if @unmerged.empty?
          @out.puts "\nDone. The work is merged into #{base} in #{directory}:"
          @out.puts "  git -C #{directory} log --oneline --first-parent -#{@steps_run || @input.steps.size} #{base}"
          run_hint(directory)
        else
          @out.puts "\nDone, but not everything was merged; see the warnings above. Unmerged work is on:"
          @unmerged.each { |b| @out.puts "  #{b}" }
        end
      elsif finished
        if created
          git("switch", "-q", branch, dir: directory)
          @out.puts "\nDone. #{directory} is on branch #{branch}."
        else
          @out.puts "\nDone. Your checkout is unchanged; the work is on branch #{branch}:"
          @out.puts "  git -C #{directory} log --oneline #{current_branch(directory)}..#{branch}"
          @out.puts "  git -C #{directory} switch #{branch}"
        end
        run_hint(directory)
      else
        @out.puts "\nStopped: #{task ? "#{task[:status]}. #{task[:error]}" : 'no task ran'}"
        @out.puts "Finished steps are on branch #{branch}." if Git.run("rev-parse", "--verify", "--quiet", "refs/heads/#{branch}", dir: directory, allow_failure: true)
        @out.puts "Details: runeforge status #{task[:id]}   Logs: runeforge logs #{task[:id]}" if task
        @out.puts "Continue with: runeforge resume -d #{directory}" if @registered
      end
    end

    # --- helpers -----------------------------------------------------------------------------

    def ask(question)
      @out.print question
      answer = @stdin.gets
      raise Error, "no answer to \"#{question.strip}\"; pass --dir to skip the question" if answer.nil?

      answer.strip
    end

    # How to run what was built, as the planner recorded it (see the project's README).
    def run_hint(directory)
      repo = @env.repos.fetch(@registered)
      return if repo[:run_command].to_s.strip.empty?

      setup = repo[:setup_command].to_s.strip
      @out.puts "\nRun it:"
      @out.puts "  cd #{directory}"
      @out.puts "  #{setup}" unless setup.empty?
      @out.puts "  #{repo[:run_command]}"
    end

    def git(*args, dir:, env: {}) = Git.run(*args, dir:, env:)

    def merging? = !@env.manual_merge?(@registered)

    def plural(count, word) = "#{count} #{word}#{'s' unless count == 1}"
  end
end
