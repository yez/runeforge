# frozen_string_literal: true

require "thor"

module Runeforge
  class Command < Thor
    class_option :config, aliases: "-c", desc: "Path to runeforge.yml (default ./runeforge.yml if present, else ~/.runeforge/runeforge.yml)"
    class_option :database, desc: "Database URL, overriding the config file (short form: -db)"

    def self.exit_on_failure? = true

    no_commands do
      def env
        @env ||= Environment.load(config_path:, database: options[:database], must_exist: !options[:config].nil?)
      end

      def config_path = Config.locate(options[:config])

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

    desc "list", "List registered repositories"
    def list
      rows = env.repos.list.map { |repo| [repo[:name], repo[:url], repo[:base_branch], repo[:test_command]] }
      print_table([%w[NAME URL BASE TEST], *rows])
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
  end

  class CLI < Command
    # `runeforge plan.md` and `runeforge "a prompt"` run the build command. Thor splits "-db" into
    # "-d -b", so it is rewritten to --database before Thor sees it.
    def self.start(given_args = ARGV, config = {})
      args = given_args.map do |arg|
        next "--database" if arg == "-db"

        arg.start_with?("-db=") ? "--database=#{arg.delete_prefix('-db=')}" : arg
      end
      args = ["build", *args] if args.first && !args.first.start_with?("-") && !command?(args.first)
      super(args, config)
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
    DESC
    option :dir, aliases: "-d", desc: "Existing project directory to work in"
    def build(input = nil)
      return help if input.nil?

      guard { exit(1) unless Build.new(env, input:, dir: options[:dir]).run }
    end
    desc "db SUBCOMMAND", "Database commands"
    subcommand "db", DbCommand

    desc "repo SUBCOMMAND", "Repository commands"
    subcommand "repo", RepoCommand

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

    desc "status TASK", "Show a task and its message history"
    def status(id)
      guard do
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
    def worker
      guard do
        runner = Worker.new(env, roles: options[:role].split(",").map(&:strip))
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
    option :adapter, enum: %w[claude_code codex aider command], desc: "Agent CLI (default claude_code)"
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
      setup_options = options.to_h.transform_keys(&:to_sym).except(:config)
      Setup.new(config_path:, options: setup_options).run
    rescue Setup::StepFailed => e
      raise Thor::Error, e.message
    end

    desc "up", "Start the supervisor and workers in the background"
    def up
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

    no_commands do
      def daemons = Daemons.new(env, config_path:, database: options[:database])

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
          when "review.verdict" then msg.payload["approved"] ? "approved" : "rejected: #{Array(msg.payload['reasons']).join('; ')}"
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
