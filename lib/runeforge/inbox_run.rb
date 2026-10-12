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
    def initialize(env, repo:, directory:, stdout: $stdout)
      @env = env
      @repo = repo
      @directory = directory
      @out = stdout
      @inbox = Inbox.new(env)
    end

    # Reads the inbox now and returns its unfinished plans, in queue order.
    def pending
      @inbox.poll_repo(@repo)
      active
    end

    # Plan files in the checkout's runeforge/inbox/ that the base branch doesn't have.
    def uncommitted
      base = @env.repos.refresh(@repo)
      committed = @env.repos.files(@repo, base, Inbox::INBOX).keys
      Dir.glob("#{Inbox::INBOX}/**/*.md", base: @directory).select { |path| Inbox.plan_path?(path) }.sort - committed
    end

    # Returns true when every plan it found or started finished.
    def run
      plans = active
      @out.puts "Building the inbox in #{@directory}: #{plans.map { |p| "#{label(p)} (#{p[:status]})" }.join(', ')}"
      seen = plans.map { |p| p[:id] }
      supervisor = Supervisor.new(@env, repo: @repo)
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
        end
        @env.tasks.messages(current, after: last).each do |msg|
          line = Build.describe(msg, merging: !@env.manual_merge?(@repo))
          @out.puts "  #{line}" if line
          last = msg.id
        end
        task = @env.tasks.find(current)
        # A finished step moves its plan on (or fails it) on the next inbox read.
        next @inbox.poll_repo(@repo) if task.nil? || TERMINAL_STATUSES.include?(task[:status]) || task[:status] == "blocked"
        next if @worker.work_once

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
