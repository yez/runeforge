# frozen_string_literal: true

module Runeforge
  class Tasks
    ID_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/

    def initialize(db)
      @db = db
    end

    def table = @db[:runeforge_tasks]

    def find(id) = table.where(id: id.to_s).first

    def find!(id) = find(id) || raise(Error, "unknown task #{id}")

    def list(status: nil)
      ds = table.order(Sequel.desc(:created_at))
      ds = ds.where(status:) if status
      ds.all
    end

    def update(id, fields)
      table.where(id: id.to_s).update(fields.merge(updated_at: Runeforge.now))
    end

    def messages(id, after: 0)
      @db[:runeforge_messages].where(task_id: id.to_s).where(Sequel[:id] > after).order(:id)
                              .all.map { |row| Message.from_row(row) }
    end

    def create(id:, workflow:, repo:, base_sha:, mailbox:, title: nil, ticket: nil, input: {},
               max_attempts: 5, token_budget: nil, deadline_at: nil, lane: nil, branch: nil, locked_paths: {})
      raise Error, "invalid task id #{id.inspect}" unless id.to_s.match?(ID_FORMAT)
      raise Error, "unknown workflow #{workflow}" unless Runeforge.workflows.key?(workflow.to_s)

      now = Runeforge.now
      @db.transaction do
        raise Error, "task #{id} already exists" if find(id)

        table.insert(
          id: id.to_s, workflow: workflow.to_s, status: "pending", repo: repo.to_s, title:, ticket:,
          base_sha:, branch: branch || "runeforge/#{id}", max_attempts:, token_budget:, deadline_at:,
          lane:, locked_paths: JSON.generate(locked_paths), created_at: now, updated_at: now
        )
        mailbox.post(task_id: id, type: "task.created", recipient: Runeforge.recipient(lane, "supervisor"),
                     payload: input, dedupe_key: "#{id}:task.created")
      end
      find(id)
    end

    # Stops a task. Claimed messages are cancelled too, so running workers lose their lease on the
    # next heartbeat, kill their sandbox and discard the result.
    def cancel(id, reason: "cancelled")
      @db.transaction do
        task = find!(id)
        raise Error, "task #{id} is already #{task[:status]}" if TERMINAL_STATUSES.include?(task[:status])

        update(id, status: "cancelled", error: reason)
        @db[:runeforge_messages].where(task_id: id.to_s, state: %w[pending claimed]).update(state: "cancelled")
      end
    end

    # Restarts coding from the commit recorded on an earlier message. Budgets carry over;
    # add_attempts is how a human grants more.
    def retry_from(id, message_id:, mailbox:, add_attempts: 0)
      @db.transaction do
        task = find!(id)
        raise Error, "task #{id} is #{task[:status]} and can't be retried" if %w[done cancelled].include?(task[:status])
        raise Error, "task #{id} ran in the foreground; run the runeforge command again instead" if task[:lane]

        source = @db[:runeforge_messages].where(id: message_id.to_i, task_id: id.to_s).first
        raise Error, "message #{message_id} does not belong to task #{id}" unless source
        raise Error, "message #{message_id} has no commit to retry from" unless source[:commit_sha]

        update(id, status: "coding", error: nil, max_attempts: task[:max_attempts] + add_attempts.to_i)
        mailbox.post(task_id: id, type: "task.retry", recipient: "supervisor", commit_sha: source[:commit_sha],
                     payload: { "from_message" => source[:id] })
      end
    end
  end
end
