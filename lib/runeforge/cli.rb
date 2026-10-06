# frozen_string_literal: true

require "thor"

module Runeforge
  class Command < Thor
    class_option :config, aliases: "-c", desc: "Path to runeforge.yml (default ./runeforge.yml if present, else ~/.runeforge/runeforge.yml)"
    class_option :database, desc: "Database URL, overriding the config file (short form: -db)"

    def self.exit_on_failure? = true

    no_commands do
      def env
        @env ||= begin
          warn_stray_config
          Environment.load(config_path:, database: options[:database], must_exist: !options[:config].nil?)
        end
      end

      def config_path = Config.locate(options[:config])

      def warn_stray_config
        stray = Config.stray_config(config_path)
        warn "runeforge: ignoring #{stray}; settings are read from #{config_path} (move it there, or pass -c)" if stray
      end

      def guard
        yield
      rescue Error => e
        raise Thor::Error, e.message
      end

      def short(sha) = sha.to_s[0, 7]

      def ago(time)
        return "-" unless time

        seconds = (Runeforge.now - time).to_i
        return "#{seconds}s ago" if seconds < 120
        return "#{seconds / 60}m ago" if seconds < 7200

        "#{seconds / 3600}h ago"
      end
    end
  end

  class DbCommand < Command
    desc "migrate", "Create or update the Runeforge tables"
    def migrate
      DB.migrate!(env.db)
      say "Database is up to date."
    end
  end

  class RepoCommand < Command
    desc "add NAME", "Register a repository and create the host clone"
    option :url, required: true, desc: "Clone URL; host git credentials are used"
    option :test_command, required: true, desc: "Command that runs the full test suite"
    option :base_branch, default: "main"
    option :image, desc: "Container image with this repo's toolchain and the agent CLI"
    option :setup_command, desc: "Runs before the tests (e.g. bundle install)"
    def add(name)
      guard do
        sha = env.repos.add(name:, url: options[:url], test_command: options[:test_command],
                            base_branch: options[:base_branch], image: options[:image],
                            setup_command: options[:setup_command])
        say "#{name}: cloned to #{env.repos.path(name)}; #{options[:base_branch]} is at #{short(sha)}"
      end
    end

    desc "set NAME", "Change a registered repository's commands"
    long_desc <<~DESC
      Sets how Runeforge tests, prepares and runs a repository's project. --run-command records
      the project's own launch command (Runeforge won't replace it); --require-run-docs makes the
      reviewer reject work whose README doesn't contain it.
    DESC
    option :test_command
    option :setup_command
    option :run_command
    option :require_run_docs, type: :boolean, desc: "Reject work whose README doesn't contain the run command"
    option :base_branch
    option :image
    def set(name)
      guard do
        env.repos.fetch(name)
        fields = { test_command: options[:test_command], setup_command: options[:setup_command],
                   run_command: options[:run_command], base_branch: options[:base_branch], image: options[:image] }.compact
        fields[:run_docs_required] = options[:require_run_docs] unless options[:require_run_docs].nil?
        raise Error, "nothing to change; pass e.g. --run-command 'npm start'" if fields.empty?

        env.repos.update(name, fields)
        repo = env.repos.fetch(name)
        say "#{name}: test #{repo[:test_command].to_s.empty? ? '-' : repo[:test_command]}, " \
            "run #{repo[:run_command].to_s.empty? ? '-' : repo[:run_command]}" \
            "#{repo[:run_docs_required] ? ' (README must say it)' : ''}"
      end
    end

    desc "list", "List registered repositories"
    def list
      rows = env.repos.list.map do |repo|
        [repo[:name], repo[:url], repo[:base_branch], repo[:test_command], repo[:run_command].to_s.empty? ? "-" : repo[:run_command]]
      end
      print_table([%w[NAME URL BASE TEST RUN], *rows])
    end
  end

  class ConfigCommand < Command
    desc "edit", "Open the config in your editor ($VISUAL, $EDITOR, else vi), then check it"
    long_desc <<~DESC
      Opens ~/.runeforge/runeforge.yml (or the file -c / RUNEFORGE_CONFIG names), creating it with
      commented examples if it doesn't exist. After you save, the file is checked; if something is
      wrong you can edit it again.
    DESC
    def edit
      guard do
        path = config_path
        unless File.exist?(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, Config::STARTER)
          say "Created #{path}"
        end
        loop do
          open_editor(path)
          problems = Config.problems(path)
          break say("#{path} looks good.") if problems.empty?

          say "Problems in #{path}:"
          problems.each { |problem| say "  - #{problem}" }
          raise Error, "fix #{path} and run `runeforge config edit` again" unless $stdin.tty?
          break if ask("Edit it again? [Y/n]").to_s.strip.downcase.start_with?("n")
        end
      end
    end

    desc "path", "Print the config file in use"
    def path
      say config_path
    end

    desc "show", "Print the settings in effect: the config file merged over the defaults"
    def show
      guard do
        problems = Config.problems(config_path)
        problems.each { |problem| warn "runeforge: #{problem}" }
        say "# #{File.exist?(config_path) ? config_path : "#{config_path} (not created yet; these are the defaults)"}"
        say YAML.dump(env.config.to_h).delete_prefix("---\n")
      end
    end

    no_commands do
      def open_editor(path)
        editor = [ENV.fetch("VISUAL", nil), ENV.fetch("EDITOR", nil)].map(&:to_s).find { |value| !value.strip.empty? } || "vi"
        command = Shellwords.split(editor)
        ok = system(*command, path)
        raise Error, "could not run your editor (#{editor}); set $VISUAL or $EDITOR" if ok.nil?
        raise Error, "#{editor} exited with an error; #{path} was left as it is" unless ok
      end
    end
  end

  class TaskCommand < Command
    desc "create", "Create a task from a ticket or a spec file"
    option :repo, required: true
    option :workflow, default: "jira_to_pr"
    option :ticket, desc: "Ticket key, e.g. DEV-101 (text is fetched from JIRA when configured)"
    option :spec, desc: "Markdown file describing the change, when there is no ticket"
    option :title
    option :id, desc: "Task id (defaults to the ticket key or a generated id)"
    def create
      guard do
        description = options[:spec] && File.read(options[:spec])
        task = Intake.new(env).create(repo: options[:repo], workflow: options[:workflow], id: options[:id],
                                      ticket: options[:ticket], title: options[:title], description:)
        say "Created #{task[:id]} on #{task[:branch]} from #{short(task[:base_sha])}"
      end
    end

    desc "mark-done TASK", "Record that you finished a failed or stopped step yourself"
    long_desc <<~DESC
      For a build step you fixed by hand: SHA is the commit with the finished work, already in the
      base branch (or, with manual merging, on any branch). The task becomes done, its tests are
      locked as they are at SHA, and a build run again or `runeforge resume` skips the step.
    DESC
    option :sha, required: true, desc: "The commit with the finished work"
    map "mark-done" => :mark_done
    def mark_done(id)
      guard do
        task = BuildProgress.mark_done(env, id, sha: options[:sha])
        locked = JSON.parse(task[:locked_paths] || "{}")
        say "#{task[:id]} is done at #{short(task[:head_sha])}#{task[:merged_sha] ? ' (in the base branch)' : ''}; " \
            "#{locked.size} test file#{'s' unless locked.size == 1} locked"
      end
    end
  end

  class CLI < Command
    # `runeforge plan.md` and `runeforge "a prompt"` run the build command. Thor splits "-db" into
    # "-d -b", so it is rewritten to --database before Thor sees it.
    def self.start(given_args = ARGV, config = {})
      args = given_args.map do |arg|
        next "--database" if arg == "-db"

        arg.start_with?("-db=") ? "--database=#{arg.delete_prefix('-db=')}" : arg
      end
      args = dir_first(args)
      if args.first && !args.first.start_with?("-") && !command?(args.first)
        refuse_bare_word(args.first)
        args = ["build", *args]
      end
      super(args, config)
    end

    # `runeforge -d DIR status` (or any command) reads like `runeforge status -d DIR`; with no
    # command after it, `runeforge -d DIR "prompt"` builds, as before.
    def self.dir_first(args)
      dir_args =
        if %w[-d --dir].include?(args[0]) && args.size >= 2 then args.first(2)
        elsif args[0].to_s.start_with?("--dir=") then args.first(1)
        end
      return args unless dir_args

      rest = args.drop(dir_args.size)
      rest.first && command?(rest.first) ? [rest.first, *dir_args, *rest.drop(1)] : ["build", *dir_args, *rest]
    end

    # A single word that is neither a command nor a file is far more likely a mistyped command (or
    # one this version doesn't have) than a prompt, and treating it as a prompt starts a real build.
    # `runeforge build WORD` still builds from it.
    def self.refuse_bare_word(word)
      return if word.match?(/\s/) || File.exist?(word)

      names = all_commands.keys.map { |name| name.tr("_", "-") } + subcommands + map.keys.map(&:to_s)
      suggestion = DidYouMean::SpellChecker.new(dictionary: names.uniq).correct(word).first
      warn "runeforge: unknown command \"#{word}\"#{suggestion ? ". Did you mean \"#{suggestion}\"?" : ''}"
      warn "To build from a one-word prompt, run: runeforge build #{word}"
      exit 1
    end

    def self.command?(name)
      all_commands.key?(name.tr("-", "_")) || subcommands.include?(name) || map.key?(name)
    end

    default_command :build

    desc "build INPUT", "Build from a markdown task list or a prompt (also: runeforge INPUT)"
    long_desc <<~DESC
      INPUT is a markdown file or a prompt. In a file, each unchecked top-level list item is one
      step, built in order on one branch; anything else is built as a single step.

      Without --dir, runeforge asks for a directory name and creates a new project there. With
      --dir, it works in that repository on a new branch and refuses to start if it has
      uncommitted changes. Runs in the foreground; Ctrl-C stops it.

      Run again with the same file, it skips the steps at the start that an earlier run already
      finished (matched by each step's text, and only if their work is still in the base branch)
      and starts at the first one that isn't done. `runeforge resume -d DIR` does the same
      without the file.
    DESC
    option :dir, aliases: "-d", desc: "Existing project directory to work in"
    option :from, type: :numeric, desc: "Start at this step (the steps before it must be done, unless --rerun)"
    option :rerun, type: :boolean, desc: "Build every step again, even the ones an earlier run finished"
    def build(input = nil)
      return help if input.nil?

      guard { exit(1) unless Build.new(env, input:, dir: options[:dir], from: options[:from], rerun: options[:rerun]).run }
    end

    desc "resume", "Continue the last unfinished build in a directory, from the step that didn't finish"
    long_desc <<~DESC
      Finds the newest build in DIR that didn't finish, rebuilds its step list from the plan it
      stored, skips the steps that are done (and still in the base branch) and builds the rest.
      A step that failed is planned again from scratch. If you fixed it yourself, record that
      first with `runeforge task mark-done TASK --sha SHA`.
    DESC
    option :dir, aliases: "-d", required: true, desc: "The project directory"
    option :run, desc: "The run to continue (its id or lane), instead of the newest unfinished one"
    option :from, type: :numeric, desc: "Start at this step instead (the steps before it must be done)"
    def resume
      guard do
        build = Build.resume(env, dir: options[:dir], run: options[:run], from: options[:from])
        exit(1) if build && !build.run
      end
    end
    desc "db SUBCOMMAND", "Database commands"
    subcommand "db", DbCommand

    desc "repo SUBCOMMAND", "Repository commands"
    subcommand "repo", RepoCommand

    desc "config SUBCOMMAND", "Edit, locate or show the config (~/.runeforge/runeforge.yml)"
    subcommand "config", ConfigCommand

    desc "task SUBCOMMAND", "Task commands"
    subcommand "task", TaskCommand

    map %w[-v --version] => :version
    map "retry" => :retry_task

    desc "version", "Print the version"
    def version
      say "runeforge #{VERSION}"
    end

    desc "tasks", "List tasks"
    option :status, desc: "Only tasks in this status (e.g. blocked, awaiting_human)"
    def tasks
      rows = env.tasks.list(status: options[:status]).map do |task|
        [task[:id], task[:status], "#{task[:attempts]}/#{task[:max_attempts]}", task[:repo], ago(task[:updated_at]), task[:title].to_s[0, 50]]
      end
      print_table([%w[TASK STATUS ATTEMPTS REPO UPDATED TITLE], *rows])
    end

    desc "status [TASK]", "Show a task and its history, or with -d DIR a project: platform, build environment, tasks"
    long_desc <<~DESC
      With TASK: the task and every message. With -d DIR (or `runeforge -d DIR status`): the
      project in DIR: whether it can be built where Runeforge builds it (platform-specific apps
      like iOS, macOS and Android need their toolchain), how it runs and merges, its recent tasks
      and queued plans.
    DESC
    option :dir, aliases: "-d", desc: "A project directory"
    def status(id = nil)
      guard do
        next project_status(File.expand_path(options[:dir])) if options[:dir]
        raise Error, "give a TASK, or -d DIR for a project" unless id

        task = env.tasks.find!(id)
        say task_header(task)
        say "─" * 72
        env.tasks.messages(id).each { |msg| say message_line(msg) }
      end
    end

    desc "watch TASK", "Follow a task's messages until it finishes"
    option :interval, type: :numeric, default: 2
    def watch(id)
      guard do
        last = 0
        loop do
          env.tasks.messages(id, after: last).each do |msg|
            say message_line(msg)
            last = msg.id
          end
          task = env.tasks.find!(id)
          break say("#{id} is #{task[:status]}#{task[:error] ? ": #{task[:error]}" : ''}") if TERMINAL_STATUSES.include?(task[:status])

          sleep options[:interval]
        end
      end
    end

    desc "inbox [REPO]", "Show the plans queued from each project's runeforge/inbox/"
    long_desc <<~DESC
      Plans committed to runeforge/inbox/ on a repository's base branch are built one at a time,
      in the order they arrived. The background supervisor checks every inbox.poll_seconds;
      --poll checks now.
    DESC
    option :poll, type: :boolean, desc: "Check the inboxes now instead of waiting for the supervisor"
    option :all, type: :boolean, desc: "Include finished, dropped and superseded plans"
    def inbox(repo = nil)
      guard do
        inbox = Inbox.new(env)
        if options[:poll]
          names = repo ? [env.repos.fetch(repo)[:name]] : env.repos.list.map { |r| r[:name] }
          names.each do |name|
            inbox.poll_repo(name)
          rescue Error => e
            say "#{name}: #{e.message}"
          end
        end
        names = repo ? [repo] : env.db[:runeforge_plans].distinct.select_map(:repo).sort
        say "No plans yet. Commit a markdown file to runeforge/inbox/ on a registered repository's base branch." if names.empty?
        names.each do |name|
          rows = inbox.queue(name)
          rows = rows.reject { |p| %w[done dropped superseded cancelled].include?(p[:status]) } unless options[:all]
          say "#{name}#{rows.empty? ? ': nothing queued' : ''}"
          table = rows.map do |p|
            step = p[:steps] ? "#{[p[:step] + (p[:status] == 'running' ? 1 : 0), p[:steps]].min}/#{p[:steps]}" : "-"
            ["  #{p[:name]}", p[:status], step, p[:task_id] || "-", p[:reason].to_s[0, 70]]
          end
          print_table([["  PLAN", "STATUS", "STEP", "TASK", "REASON"], *table]) if table.any?
        end
      end
    end

    desc "workers", "List live workers"
    def workers
      rows = env.db[:runeforge_workers].order(:id).all.map do |worker|
        [worker[:id], worker[:roles], worker[:current_message_id] || "-", worker[:sandbox_id] || "-", ago(worker[:heartbeat_at])]
      end
      print_table([%w[WORKER ROLES MESSAGE SANDBOX HEARTBEAT], *rows])
    end

    desc "cancel TASK", "Stop a task and discard work in progress"
    option :reason, default: "cancelled by a person"
    def cancel(id)
      guard do
        env.tasks.cancel(id, reason: options[:reason])
        say "Cancelled #{id}."
      end
    end

    desc "retry TASK", "Restart coding from the commit on an earlier message"
    option :from_message, type: :numeric, required: true
    option :add_attempts, type: :numeric, default: 0, desc: "Extra attempts to allow on top of the task's limit"
    def retry_task(id)
      guard do
        env.tasks.retry_from(id, message_id: options[:from_message], add_attempts: options[:add_attempts], mailbox: env.mailbox("cli"))
        say "Requeued #{id} from message #{options[:from_message]}."
      end
    end

    desc "logs TASK", "List a task's logs, or print one message's log"
    option :message, type: :numeric
    def logs(id)
      guard do
        messages = env.tasks.messages(id)
        if options[:message]
          msg = messages.find { |m| m.id == options[:message] } || raise(Error, "no message #{options[:message]} on #{id}")
          path = msg.payload["log_path"]
          path && File.exist?(path) ? say(File.read(path)) : say(JSON.pretty_generate(msg.payload))
        else
          rows = messages.select { |m| m.payload["log_path"] }.map { |m| ["##{m.id}", m.type, m.payload["log_path"]] }
          print_table([%w[MESSAGE TYPE LOG], *rows])
        end
      end
    end

    desc "supervisor", "Run the supervisor (routing, budgets, lease reaper)"
    option :once, type: :boolean, desc: "Handle what is waiting, then exit"
    def supervisor
      runner = Supervisor.new(env)
      options[:once] ? runner.tick : run_until_signal(runner)
    end

    desc "worker", "Run a worker for one or more roles"
    option :role, required: true, desc: "Comma-separated: planner,coder,tester,reviewer,integrator"
    option :once, type: :boolean, desc: "Handle at most one message, then exit"
    option :dry_run, type: :boolean, desc: "Go through the motions without calling an LLM, git or the network"
    def worker
      guard do
        worker_env = env
        if options[:dry_run]
          worker_env = Environment.new(Config.new(Config.deep_merge(env.config.to_h, "dry_run" => { "enabled" => true })), db: env.db)
        end
        worker_env.check_agent_credentials! if (options[:role].split(",").map(&:strip) & %w[planner coder]).any?
        runner = Worker.new(worker_env, roles: options[:role].split(",").map(&:strip))
        options[:once] ? runner.work_once : run_until_signal(runner)
      end
    end

    desc "init", "First-time setup: config, database, container runtime, agent image, then start everything"
    long_desc <<~DESC
      Safe to run again: each step checks what is already in place. Starts PostgreSQL (via Homebrew)
      and Docker Desktop or the Podman machine when they are needed but not running, creates the
      database, runs migrations, builds the example agent image, and starts the supervisor and
      workers in the background.
    DESC
    option :sandbox, enum: %w[docker podman none], desc: "Container runtime for agents (default docker)"
    option :model, desc: "Model for the agents, e.g. claude-sonnet-5-5, gemini-pro-latest, gpt-5, openrouter/qwen/qwen3-coder"
    option :adapter, enum: %w[ruby_llm claude_code codex aider command], desc: "Agent (default: ruby_llm for API keys, claude_code for a Claude subscription token)"
    option :home, desc: "Where clones, logs and workspaces live (default ~/.runeforge)"
    option :image, desc: "Agent container image (default runeforge/general:latest)"
    option :repo, desc: "Name for --repo-url (default: from the URL)"
    option :repo_url, desc: "Register this repository during setup"
    option :test_command, desc: "Test command for --repo-url"
    option :setup_command, desc: "Setup command for --repo-url (e.g. bundle install)"
    option :base_branch, default: "main"
    option :skip_image, type: :boolean, desc: "Don't build the agent image"
    option :start, type: :boolean, default: true, desc: "Start the supervisor and workers (--no-start to skip)"
    def init
      warn_stray_config
      setup_options = options.to_h.transform_keys(&:to_sym).except(:config)
      Setup.new(config_path:, options: setup_options).run
    rescue Setup::StepFailed => e
      raise Thor::Error, e.message
    end

    desc "up", "Start the supervisor and workers in the background"
    def up
      guard { env.check_agent_credentials! } if Array(env.config["workers"]).join(",").match?(/planner|coder/)
      guard { daemons.up.each { |s| say "#{s.name.ljust(40)} #{s.state} (pid #{s.pid})" } }
    end

    desc "down", "Stop the background supervisor and workers"
    def down
      guard { daemons.down.each { |s| say "#{s.name.ljust(40)} #{s.state}" } }
    end

    desc "ps", "Show the background supervisor and workers"
    def ps
      guard do
        rows = daemons.status.map { |s| [s.name, s.state, s.pid || "-", s.log_path] }
        print_table([%w[PROCESS STATE PID LOG], *rows])
      end
    end

    desc "implode", "Remove everything runeforge init and runeforge runs created on this machine"
    long_desc <<~DESC
      Stops the background processes, deletes the database (only the Runeforge tables on
      PostgreSQL), removes runeforge/* container images, deletes Runeforge's clones, logs and
      workspaces under its home directory, and deletes config files written by runeforge init.
      Config files you wrote yourself are kept. Your project directories and their runeforge/*
      branches are never touched. Lists everything and asks before deleting.
    DESC
    option :yes, type: :boolean, aliases: "-y", desc: "Don't ask for confirmation"
    option :dry_run, type: :boolean, desc: "Only list what would be removed"
    option :keep_images, type: :boolean, desc: "Keep the runeforge/* container images"
    def implode
      guard do
        implode = Implode.new(config_path:, database: options[:database], keep_images: options[:keep_images],
                              must_exist: !options[:config].nil?)
        actions = implode.actions
        say(actions.empty? ? "Nothing to remove." : "This will:")
        actions.each { |action| say "  - #{action.description}" }
        implode.kept.each { |item| say "  Keeping: #{item}" }
        next if actions.empty?

        say "Not touched: your project directories and their runeforge/* branches, Docker, PostgreSQL, " \
            "and the runeforge gem itself (gem uninstall runeforge)."
        next say("Dry run: nothing was removed.") if options[:dry_run]
        unless options[:yes]
          $stdout.print "Type implode to continue: "
          raise Error, "Cancelled; nothing was removed." unless $stdin.gets.to_s.strip == "implode"
        end

        implode.run(actions)
        say "Runeforge's local setup is gone. Run runeforge init to start again."
      end
    end

    desc "webhook", "Serve the JIRA webhook endpoint (POST /webhooks/jira)"
    option :host, default: "127.0.0.1"
    option :port, type: :numeric, default: 9292
    def webhook
      require "rackup"
      require "runeforge/web/webhook_app"
      Rackup::Handler::WEBrick.run(Web::WebhookApp.new(env), Host: options[:host], Port: options[:port])
    end

    desc "dashboard", "Serve the live dashboard (HTML + Server-Sent Events) with Puma"
    long_desc <<~DESC
      Open http://HOST:PORT/ in a browser. Watches whatever supervisor and workers share this
      database, on this machine or others. Set RUNEFORGE_DASHBOARD_TOKEN to require ?token=.
    DESC
    option :host, default: "127.0.0.1"
    option :port, type: :numeric, default: 9393
    def dashboard
      guard do
        db = DB.connect(env.config["database"], max_connections: 40)
        raise Error, "the database needs migrating; run runeforge db migrate" unless DB.migrated?(db)

        serve(Environment.new(env.config, db:), options[:host], options[:port])
      end
    end

    desc "warcamp", "Serve the war camp: the live dashboard as an orc camp, RTS-style"
    long_desc <<~DESC
      Same data and API as `runeforge dashboard`, drawn as an orc camp: each role has a building,
      and each worker is an orc who leaves it to work on a job and brings the result back.
    DESC
    option :host, default: "127.0.0.1"
    option :port, type: :numeric, default: 9393
    def warcamp
      guard do
        db = DB.connect(env.config["database"], max_connections: 40)
        raise Error, "the database needs migrating; run runeforge db migrate" unless DB.migrated?(db)

        serve(Environment.new(env.config, db:), options[:host], options[:port], page: :warcamp)
      end
    end

    desc "demo", "Run dry-run agents forever and serve the dashboard (no LLM, git or network)"
    long_desc <<~DESC
      Starts a supervisor, dry-run workers for every role and a feeder that keeps tasks flowing,
      all in this process, plus the dashboard. Agents sleep through canned steps for 5-10 seconds
      each and sometimes fail, so retries show up too. Uses its own SQLite database
      (<home>/demo.db) unless you pass --database. Ctrl-C stops it.
    DESC
    option :host, default: "127.0.0.1"
    option :port, type: :numeric, default: 9393
    option :concurrency, type: :numeric, default: 3, desc: "Tasks in flight at once"
    option :min_seconds, type: :numeric, desc: "Shortest step (default dry_run.min_seconds, 5)"
    option :max_seconds, type: :numeric, desc: "Longest step (default dry_run.max_seconds, 10)"
    option :warcamp, type: :boolean, desc: "Serve the war camp view instead of the dashboard"
    def demo
      guard do
        settings = Config.deep_merge(env.config.to_h, {
          "database" => options[:database] || "sqlite://#{File.join(env.home, 'demo.db')}",
          "poll_seconds" => 0.2, "heartbeat_seconds" => 2, "lease_seconds" => 60,
          "dry_run" => { "enabled" => true, "min_seconds" => options[:min_seconds], "max_seconds" => options[:max_seconds] }.compact
        })
        db = DB.connect(settings["database"], max_connections: 40)
        DB.migrate!(db)
        demo_env = Environment.new(Config.new(settings), db:)
        runner = Demo.new(demo_env, concurrency: options[:concurrency]).start
        begin
          serve(demo_env, options[:host], options[:port], page: options[:warcamp] ? :warcamp : :dashboard)
        ensure
          trap("INT", "DEFAULT") # a second Ctrl-C exits immediately
          say "Stopping the demo agents..."
          runner.stop
        end
      end
    end

    no_commands do
      def daemons = Daemons.new(env, config_path:, database: options[:database])

      # The project in `dir`, registered or not: platform verdict (checked now, and as last
      # recorded by a planner), how it runs and merges, recent tasks, queued plans.
      def project_status(dir)
        raise Error, "#{dir} is not a directory" unless File.directory?(dir)

        repo = env.repos.list.find { |row| row[:url].to_s.start_with?("/", "~") && File.expand_path(row[:url]) == dir }
        project = repo || { name: nil, url: dir }
        paths, read = Platform.scan_dir(dir)
        request = repo ? last_request(repo[:name]) : {}
        text = [request["title"], request["description"], request["context"]].compact.join("\n")
        need = Platform.detect(paths:, read:, text:, files_only: request["platform_confirmed"] == true)
        verdict = Platform.verdict(env, project, need)
        rows = [["Project", "#{dir}#{repo ? " (repo #{repo[:name]})" : ' (not registered with runeforge yet)'}"],
                ["Builds on", verdict.environment.description],
                ["Platform", verdict.status == "compatible" && verdict.platform.nil? ? "portable (no platform toolchain needed)" : verdict.reason],
                ["Status", verdict.status]]
        rows << ["To fix", verdict.fix] if verdict.fix
        if repo&.dig(:platform_status)
          rows << ["Last check", "#{repo[:platform_status]} (planner, #{ago(repo[:platform_checked_at])}): #{repo[:platform_note]}"]
        end
        if repo
          rows << ["Runs with", repo[:run_command].to_s.empty? ? "-" : repo[:run_command]]
          rows << ["Merging", env.manual_merge?(repo[:name]) ? "manual (left for a person)" : "automatic (#{env.merge_method(repo[:name])})"]
        end
        print_table(rows)
        return unless repo

        tasks = env.db[:runeforge_tasks].where(repo: repo[:name]).order(Sequel.desc(:created_at)).limit(8).all
        say "\nRecent tasks#{tasks.empty? ? ': none' : ''}"
        print_table(tasks.map { |t| ["  #{t[:id]}", t[:status], ago(t[:updated_at]), (t[:error] || t[:title]).to_s[0, 70]] }) if tasks.any?
        plans = Inbox.new(env).queue(repo[:name]).select { |p| Inbox::ACTIVE.include?(p[:status]) }
        say "\nInbox: #{plans.empty? ? 'nothing queued' : plans.map { |p| "#{p[:name]} (#{p[:status]})" }.join(', ')}"
        last_run = BuildProgress.new(env, repo[:name]).runs.last
        say "\nResume with: runeforge resume -d #{dir}   (build #{last_run[:id]} didn't finish)" if last_run && !last_run[:finished] && !last_run[:live]
      end

      # What the repo's latest task asked for (its task.created input), which tells the platform
      # apart while the project's files don't yet (an iOS app before its Xcode project exists).
      def last_request(repo_name)
        task_id = env.db[:runeforge_tasks].where(repo: repo_name).order(Sequel.desc(:created_at)).get(:id)
        row = task_id && env.db[:runeforge_messages].where(task_id:, type: "task.created").first
        payload = row && Message.from_row(row).payload
        payload.is_a?(Hash) ? payload : {}
      end

      def serve(env, host, port, page: :dashboard)
        require "rackup"
        require "rack/handler/puma"
        require "runeforge/web/dashboard_app"
        say "Dashboard on http://#{host}:#{port}/  (database #{env.config['database']}; Ctrl-C stops)"
        app = Web::DashboardApp.new(env, page:)
        # Ctrl-C makes Puma call launcher.stop and wait for requests in progress. Event streams never
        # finish on their own, so end them first. The short timeouts are a backstop.
        on_stop = Module.new do
          define_method(:stop) do
            app.shutdown
            super()
          end
        end
        Rackup::Handler::Puma.run(app, Host: host, Port: port, Threads: "1:32", Silent: true,
                                       force_shutdown_after: 1, pool_shutdown_grace_time: 1) do |launcher|
          launcher.singleton_class.prepend(on_stop)
        end
      end

      def run_until_signal(runner)
        stop = false
        %w[INT TERM].each { |signal| trap(signal) { stop = true } }
        say "#{runner.class.name.split('::').last} running; Ctrl-C finishes the current job and exits."
        runner.run(stop: -> { stop })
      end

      def task_header(task)
        budget = task[:token_budget] ? " (#{(100.0 * task[:tokens_used] / task[:token_budget]).round}% of budget)" : ""
        lines = [
          "#{task[:id]}  #{task[:workflow]}  status: #{task[:status]}   attempt #{task[:attempts]}/#{task[:max_attempts]}   " \
          "tokens #{task[:tokens_used]}#{budget}, $#{format('%.2f', task[:cost_cents] / 100.0)}",
          "branch #{task[:branch]}   base #{short(task[:base_sha])}   head #{task[:head_sha] ? short(task[:head_sha]) : '-'}"
        ]
        lines << "title  #{task[:title]}" if task[:title]
        lines << "PR     #{task[:external_pr_url]}" if task[:external_pr_url]
        lines << "error  #{task[:error]}" if task[:error]
        lines.join("\n")
      end

      def message_line(msg)
        # Senders look like "coder:worker@host:pid", "supervisor@host:pid" or "human:name".
        from = msg.sender.start_with?("human:") ? msg.sender : msg.sender.split(/[:@]/).first
        detail =
          case msg.type
          when "test.result" then msg.payload["passed"] ? "passed" : "failed"
          when "review.verdict"
            verdict = msg.payload["approved"] ? "approved" : "rejected: #{Array(msg.payload['reasons']).join('; ')}"
            [verdict, *Array(msg.payload["notes"]).map { |note| "(note: #{note})" }].join(" ")
          when "code.failed", "plan.failed", "integrate.failed" then msg.payload["reason"].to_s[0, 80]
          when "integrate.done" then msg.payload["pr_url"].to_s
          when "deps.check" then Array(msg.payload["tools"]).join(", ")
          when "deps.declined" then "missing #{Array(msg.payload['missing']).join(', ')}"
          else ""
          end
        state = msg.state
        if state == "claimed"
          worker = env.db[:runeforge_workers].where(current_message_id: msg.id).first
          state = "claimed  #{msg.claimed_by}#{worker ? "  ♥ #{ago(worker[:heartbeat_at])}" : ''}"
        end
        format("#%-6d %-14s → %-11s %-18s %-8s %-9s %s", msg.id, from[0, 14], Runeforge.role_of(msg.recipient), msg.type, short(msg.commit_sha), state, detail).rstrip
      end
    end
  end
end
