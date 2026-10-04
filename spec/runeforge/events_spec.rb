# frozen_string_literal: true

RSpec.describe Runeforge::Events do
  on_each_backend do
    let(:mailbox) { Runeforge::Mailbox.new(db, worker_id: "w1", lease_seconds: 60, max_deliveries: 1) }
    let(:tasks) { Runeforge::Tasks.new(db) }

    def kinds(after = 0) = described_class.since(db, after:).map { |event| [event[:kind], event[:message_id]] }

    before do
      tasks.create(id: "T-1", workflow: "jira_to_pr", repo: "demo", base_sha: "a" * 40, mailbox:, title: "Greet")
    end

    it "records task creation and the first message in the same transaction" do
      first = db[:runeforge_messages].first
      expect(kinds).to eq([["task.created", nil], ["message.posted", first[:id]]])
      created = described_class.since(db).first
      expect(created).to include(task_id: "T-1")
      expect(created[:data]).to include("status" => "pending", "title" => "Greet")
    end

    it "follows a message through claim, heartbeat and completion" do
      cursor = described_class.cursor(db)
      msg = mailbox.claim("supervisor")
      mailbox.heartbeat(msg)
      mailbox.complete(msg, result_type: "plan.done", payload: { "spec" => "x" * 2_000 }, task_updates: { attempts: 1 })

      posted = db[:runeforge_messages].where(type: "plan.done").get(:id)
      expect(kinds(cursor)).to eq([
                                    ["message.claimed", msg.id], ["message.heartbeat", msg.id], ["message.done", msg.id],
                                    ["message.posted", posted], ["task.updated", nil]
                                  ])
      event = described_class.since(db, after: cursor).find { |e| e[:kind] == "message.posted" }
      expect(event[:data]).to include("type" => "plan.done", "role" => "supervisor", "in_reply_to" => msg.id)
      expect(event[:data]["payload"]["spec"].length).to be <= described_class::STRING_LIMIT + 1
    end

    it "records requeues, dead letters and the task they block" do
      cursor = described_class.cursor(db)
      msg = mailbox.claim("supervisor")
      mailbox.release(msg, error: "boom")

      expect(kinds(cursor).map(&:first)).to eq(%w[message.claimed message.dead task.updated])
      expect(described_class.since(db, after: cursor).last[:data]).to include("status" => "blocked")
    end

    it "records each message a cancel stops" do
      cursor = described_class.cursor(db)
      tasks.cancel("T-1")
      expect(kinds(cursor).map(&:first)).to eq(%w[task.updated message.cancelled])
    end

    it "does not record a post whose dedupe key was already used" do
      cursor = described_class.cursor(db)
      expect(mailbox.post(task_id: "T-1", type: "task.created", recipient: "supervisor", dedupe_key: "T-1:task.created")).to be_nil
      expect(kinds(cursor)).to be_empty
    end

    it "filters by task and prunes by age" do
      described_class.emit(db, "worker.started", actor: "w2")
      expect(described_class.since(db, task_id: "T-1").map { |e| e[:task_id] }.uniq).to eq(["T-1"])

      described_class.prune(db, before: Runeforge.now + 1)
      expect(described_class.cursor(db)).to eq(0)
    end
  end
end
