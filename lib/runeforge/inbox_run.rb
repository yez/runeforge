# frozen_string_literal: true

module Runeforge
  # `runeforge resume -d DIR` when no build there is left unfinished: builds the plans waiting in
  # the project's runeforge/inbox/ in the foreground, as the background supervisor and workers
  # would (see Inbox), touching only this repository's inbox tasks. Stops once nothing is running
  # or queued; plans waiting on a merge or on `after:` are left for later.
  class InboxRun
    def self.enabled?(env) = env.config.dig("inbox", "enabled") ? true : false

    # repo: the registered repository's name; directory: its checkout, checked for plan files
    # that aren't committed to the base branch (the inbox only reads committed plans).
    # operator: ask at the terminal for tools the sandbox is missing (see Operator), as
    # `runeforge build FILE` does; on by default when stdin is a terminal.
    def initialize(env, repo:, directory:, stdin: $stdin, stdout: $stdout, operator: stdin.respond_to?(:tty?) && stdin.tty?)
      @env = env
      @repo = repo
      @directory = directory
      @out = stdout
      @stdin = stdin
      @inbox = Inbox.new(env)
      @operator = operator ? Operator.new(env, input: stdin, output: stdout) : nil
    end

    # Reads the inbox now and returns its unfinished plans, in queue order.
    def pending
      # The inbox's tables may be newer than the database (see Setup#prepare, run before building).
      DB.migrate!(@env.db) unless DB.migrated?(@env.db)
      @inbox.poll_repo(@repo)
      active
    end

    # #pending, after offering to retry the inbox's failed plans: each one at a terminal, or all of
    # them with retry_failed: true. Otherwise says how to retry them.
    def ready(retry_failed: false)
      found = pending
      failed = @inbox.failed(@repo)
      return found if failed.empty?

      retried = failed.count do |plan|
        @out.puts "#{label(plan)} failed: #{plan[:reason].to_s.lines.first.to_s.strip[0, 300]}"
        next @inbox.retry(plan) if retry_failed
        next false unless @stdin.respond_to?(:tty?) && @stdin.tty?

        @out.print "Retry it#{plan[:step].to_i.positive? ? " from step #{plan[:step] + 1}" : ''}? [y/N]: "
        @stdin.gets.to_s.strip.casecmp?("y") && @inbox.retry(plan)
      end
      @out.puts "Retry failed plans with --retry, or edit and commit them." if retried.zero? && !retry_failed
      retried.positive? ? pending : found
    end

    # Plan files in the checkout's runeforge/inbox/ that the base branch doesn't have.
    def uncommitted
      base = @env.repos.refresh(@repo)
      committed = @env.repos.files(@repo, base, Inbox::INBOX).keys
      Dir.glob("#{Inbox::INBOX}/**/*.md", base: @directory).select { |path| Inbox.plan_path?(path) }.sort - committed
    end

    # Returns true when every plan it found or started finished.
    def run
      # As a foreground build prepares: credentials, migrations, container runtime, agent image.
      @env.check_agent_credentials!(project: @env.repos.fetch(@repo))
      Setup.new(config_path: Config.locate, out: @out).prepare(@env).prepare_project(@env, @repo)
      plans = active
      @out.puts "Building the inbox in #{@directory}: #{plans.map { |p| "#{label(p)} (#{p[:status]})" }.join(', ')}"
      seen = plans.map { |p| p[:id] }
      supervisor = Supervisor.new(@env, repo: @repo, operator: !@operator.nil?)
      operator_box = @env.mailbox("operator@#{Socket.gethostname}:#{Process.pid}")
      @worker = Worker.new(@env, roles: Roles.names, repo: @repo)
      @stopped = false
      previous = trap("INT") { @stopped = true; Thread.new { @worker.interrupt(release: true) } }
      current = nil
      last = 0
      until @stopped
        supervisor.tick
        running = @inbox.plans.where(repo: @repo, status: "running").first
        unless running
          @inbox.poll_repo(@repo) # starts the next plan, or the next step after a merge
          running = @inbox.plans.where(repo: @repo, status: "running").first
          break unless running
        end
        seen |= [running[:id]]
        if running[:task_id] != current
          current = running[:task_id]
          last = 0
          step = running[:steps].to_i > 1 ? " step #{running[:step] + 1}/#{running[:steps]}" : ""
          @out.puts "\n#{label(running)}#{step}  (task #{current})"
          @inbox.warnings(running).each { |warning| @out.puts "  ! #{warning}" } if running[:step].to_i.zero?
        end
        @env.tasks.messages(current, after: last).each do |msg|
          line = Build.describe(msg, merging: !@env.manual_merge?(@repo))
          @out.puts "  #{line}" if line
          last = msg.id
        end
        task = @env.tasks.find(current)
        # A finished step moves its plan on (or fails it) on the next inbox read.
        next @inbox.poll_repo(@repo) if task.nil? || TERMINAL_STATUSES.include?(task[:status]) || task[:status] == "blocked"
        next if @operator&.answer(operator_box, "operator", task_ids: @env.tasks.ids_in(@repo)) || @worker.work_once

        sleep @env.config["poll_seconds"]
      end
      report(seen)
    ensure
      trap("INT", previous || "DEFAULT")
      @worker&.unregister
    end

    private

    def active = @inbox.queue(@repo).select { |p| Inbox::ACTIVE.include?(p[:status]) }

    def label(plan) = plan[:title] ? "#{plan[:title]} (#{plan[:name]})" : plan[:name]

    def report(ids)
      plans = @inbox.plans.where(id: ids).order(:arrival, :id).all
      @out.puts(@stopped ? "\nStopped. Inbox:" : "\nInbox:")
      plans.each { |p| @out.puts "  #{label(p)}: #{p[:status]}#{p[:reason] ? " (#{p[:reason]})" : ''}" }
      if @stopped
        @out.puts "The interrupted step runs again, without using an attempt, when you continue:"
        @out.puts "  runeforge resume -d #{@directory}   (or let `runeforge up` build it)"
      elsif plans.any? { |p| Inbox::WAITING.include?(p[:status]) || p[:status] == "unmerged" }
        @out.puts "Plans still waiting are built once what they wait on is done: runeforge inbox"
      end
      !@stopped && plans.all? { |p| %w[done superseded].include?(p[:status]) }
    end
  end
end
