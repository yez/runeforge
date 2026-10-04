# frozen_string_literal: true

module Runeforge
  # `runeforge demo`: a supervisor, dry-run workers for every role and a feeder that keeps
  # `concurrency` tasks in flight, all as threads in one process, forever. Used to watch the
  # dashboard move without spending tokens. Finished demo tasks are trimmed so it can run all day.
  class Demo
    TITLES = [
      "Add CSV export to the reports page", "Rate-limit the public API", "Fix timezone drift in reminders",
      "Paginate the audit log", "Cache avatar thumbnails", "Retry failed webhook deliveries",
      "Add dark mode to settings", "Validate phone numbers on signup", "Archive stale projects nightly",
      "Show build status in the sidebar", "Stream large file uploads", "Deduplicate search results",
      "Add SSO login with SAML", "Speed up the invoices query", "Send weekly digest emails"
    ].freeze
    # Coding takes the most turns, so it gets two workers.
    WORKERS = %w[planner coder coder tester reviewer integrator].freeze
    ID_PREFIX = "DEMO-"

    def initialize(env, concurrency: 3, keep_finished: 40, out: $stdout)
      @env = env
      @concurrency = concurrency
      @keep_finished = keep_finished
      @out = out
      @stop = false
      @threads = []
      @workers = nil
    end

    def start
      stop = -> { @stop }
      @threads << thread("supervisor") { Supervisor.new(@env, id: "supervisor@demo").run(stop:) }
      @workers = WORKERS.each_with_index.map { |role, index| Worker.new(@env, roles: [role], id: "#{role}-#{index}@demo") }
      @workers.each { |worker| @threads << thread(worker.roles.first) { worker.run(stop:) } }
      @threads << thread("feeder") { feed }
      self
    end

    # Interrupts the steps in progress, like Ctrl-C in a foreground build. Their messages stay
    # claimed until the lease expires, then the next run picks them up again.
    def stop(timeout: 5)
      @stop = true
      @workers&.each(&:interrupt)
      @threads.each { |thread| thread.join(timeout) || thread.kill }
    end

    # Starts a task whenever fewer than `concurrency` are in flight, staggered so the pipeline
    # stages overlap.
    def feed
      until @stop
        top_up
        trim
        25.times { sleep 0.1 unless @stop }
      end
    end

    def top_up
      active = demo_tasks.exclude(status: TERMINAL_STATUSES + ["blocked"]).count
      create_task if active < @concurrency
    end

    def create_task
      number = next_number
      @env.tasks.create(
        id: "#{ID_PREFIX}#{number}", workflow: "jira_to_pr", repo: "demo", base_sha: SecureRandom.hex(20),
        title: TITLES[(number - 1) % TITLES.size], mailbox: @env.mailbox("demo-feeder"),
        input: { "title" => TITLES[(number - 1) % TITLES.size], "description" => "Simulated ticket." },
        max_attempts: 3
      )
    end

    # Keeps the newest keep_finished finished tasks; older ones go with their messages and events.
    def trim
      old = demo_tasks.where(status: TERMINAL_STATUSES + ["blocked"]).order(Sequel.desc(:updated_at))
                      .offset(@keep_finished).select_map(:id)
      return if old.empty?

      @env.db.transaction do
        @env.db[:runeforge_messages].where(task_id: old).delete
        Events.table(@env.db).where(task_id: old).delete
        @env.db[:runeforge_tasks].where(id: old).delete
      end
    end

    private

    def demo_tasks = @env.db[:runeforge_tasks].where(Sequel.like(:id, "#{ID_PREFIX}%"))

    def next_number
      demo_tasks.select_map(:id).map { |id| id.delete_prefix(ID_PREFIX).to_i }.max.to_i + 1
    end

    def thread(name, &block)
      Thread.new do
        Thread.current.name = "demo-#{name}"
        Thread.current.report_on_exception = false
        loop do
          block.call
          break
        rescue StandardError => e
          break if @stop

          @out.puts "demo #{name}: #{e.class}: #{e.message}; restarting"
          sleep 1
        end
      end
    end
  end
end
