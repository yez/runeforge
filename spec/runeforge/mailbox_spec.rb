# frozen_string_literal: true

RSpec.describe Runeforge::Mailbox do
  on_each_backend do
    let(:mailbox) { described_class.new(db, worker_id: "w1", lease_seconds: 60, max_deliveries: 2) }
    let(:messages) { db[:runeforge_messages] }

    before do
      now = Runeforge.now
      db[:runeforge_tasks].insert(id: "T-1", workflow: "jira_to_pr", status: "coding", repo: "demo",
                                  base_sha: "a" * 40, branch: "runeforge/T-1", created_at: now, updated_at: now)
    end

    def post(type = "code.request", recipient: "coder", **opts)
      mailbox.post(task_id: "T-1", type:, recipient:, payload: { "n" => 1 }, **opts)
    end

    def expire!(msg) = messages.where(id: msg.id).update(lease_expires_at: Runeforge.now - 1)

    it "claims the oldest pending message for a recipient and leases it" do
      first = post
      post
      msg = mailbox.claim("coder")

      expect(msg.id).to eq(first)
      expect(msg).to have_attributes(state: "claimed", claimed_by: "w1", delivery_count: 1, payload: { "n" => 1 })
      expect(msg.lease_expires_at).to be > Runeforge.now
    end

    it "ignores messages addressed to other recipients" do
      post(recipient: "tester")
      expect(mailbox.claim("coder")).to be_nil
    end

    it "treats a repeated dedupe key as a no-op" do
      expect(post(dedupe_key: "k")).to be_a(Integer)
      expect(post(dedupe_key: "k")).to be_nil
      expect(messages.count).to eq(1)
    end

    it "records the result and the task update in one step" do
      post
      msg = mailbox.claim("coder")
      mailbox.complete(msg, result_type: "code.done", payload: { "ok" => true }, commit_sha: "b" * 40,
                            task_updates: { head_sha: "b" * 40 })

      expect(mailbox.find(msg.id).state).to eq("done")
      reply = messages.where(in_reply_to: msg.id).first
      expect(reply).to include(type: "code.done", recipient: "supervisor", sender: "coder:w1", commit_sha: "b" * 40,
                               dedupe_key: "T-1:code.done:#{msg.id}")
      expect(db[:runeforge_tasks].first[:head_sha]).to eq("b" * 40)
    end

    it "raises LeaseLost and records nothing when the claim was taken back" do
      post
      msg = mailbox.claim("coder")
      messages.where(id: msg.id).update(state: "pending", claimed_by: nil)

      expect { mailbox.complete(msg, result_type: "code.done") }.to raise_error(described_class::LeaseLost)
      expect(messages.where(type: "code.done").count).to eq(0)
    end

    it "requeues expired leases, then dead-letters the message and blocks the task" do
      post
      msg = mailbox.claim("coder")
      expire!(msg)
      expect(mailbox.reap).to eq([msg.id])
      expect(mailbox.find(msg.id)).to have_attributes(state: "pending", claimed_by: nil)
      expect(mailbox.find(msg.id).last_error).to include("lease expired")

      expire!(mailbox.claim("coder"))
      mailbox.reap
      expect(mailbox.find(msg.id).state).to eq("dead")
      expect(db[:runeforge_tasks].first).to include(status: "blocked")
      expect(db[:runeforge_tasks].first[:error]).to include("failed 2 times")
    end

    it "keeps a lease alive with heartbeats" do
      post
      msg = mailbox.claim("coder")
      expire!(msg)
      expect(mailbox.heartbeat(msg)).to be(true)
      expect(mailbox.reap).to be_empty
    end

    it "gives a message back after a handler error" do
      post
      msg = mailbox.claim("coder")
      expect(mailbox.release(msg, error: "boom")).to be(true)
      expect(mailbox.find(msg.id)).to have_attributes(state: "pending", last_error: "boom")
    end

    it "hands each message to exactly one of many concurrent workers" do
      40.times { post }
      claimed = Queue.new
      threads = Array.new(8) do |i|
        Thread.new do
          box = described_class.new(db, worker_id: "w#{i}")
          while (msg = box.claim("coder"))
            claimed << msg.id
          end
        end
      end
      threads.each(&:join)

      ids = Array.new(claimed.size) { claimed.pop }
      expect(ids.size).to eq(40)
      expect(ids.uniq.size).to eq(40)
    end
  end
end
