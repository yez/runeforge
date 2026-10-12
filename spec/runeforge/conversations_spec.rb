# frozen_string_literal: true

RSpec.describe Runeforge::Conversations do
  on_each_backend do
    let(:store) { described_class.new(db, home: File.join(tmpdir, "home")) }
    let(:conversation) { store.start(task_id: "T-1", repo: "demo", adapter: "ruby_llm") }

    it "hands out the newest conversation of a task" do
      first = store.start(task_id: "T-1", repo: "demo", adapter: "claude_code")
      second = store.start(task_id: "T-1", repo: "demo", adapter: "claude_code")
      store.start(task_id: "T-2", repo: "demo", adapter: "claude_code")

      expect(store.latest("T-1")[:id]).to eq(second[:id])
      expect(first[:id]).to be < second[:id]
      expect(store.latest("T-3")).to be_nil
    end

    it "charges a resumed Claude Code session only for what the run added" do
      claude = store.start(task_id: "T-1", repo: "demo", adapter: "claude_code")
      expect(store.record_session(claude, session_id: "s-1", cost_usd: 0.10)).to be_within(1e-9).of(0.10)
      expect(store.record_session(store.find(claude[:id]), session_id: "s-1", cost_usd: 0.25)).to be_within(1e-9).of(0.15)
      expect(store.find(claude[:id])).to include(session_id: "s-1", reported_cost_usd: 0.25)
      expect(File.directory?(store.sessions_dir(claude))).to be(true)
    end

    it "keeps a ruby_llm transcript in order across runs" do
      store.append(conversation, [{ "role" => "user", "content" => "Plan it." }, { "role" => "assistant", "content" => "Planned." }])
      store.append(conversation, [{ "role" => "user", "content" => "Build it." }], message_id: 7)

      expect(store.messages(conversation).map { |m| m["content"] }).to eq(["Plan it.", "Planned.", "Build it."])
      expect(store.messages_table.where(message_id: 7).count).to eq(1)
    end

    it "drops a trailing tool call that never got its result" do
      store.append(conversation, [{ "role" => "user", "content" => "Go." },
                                  { "role" => "assistant", "content" => nil,
                                    "tool_calls" => { "c1" => { "id" => "c1", "name" => "run_command", "arguments" => {} } } }])
      expect(store.messages(conversation).map { |m| m["role"] }).to eq(["user"])
    end

    it "refuses a transcript that isn't a list of messages with known roles" do
      expect { store.append(conversation, { "role" => "user" }) }.to raise_error(Runeforge::Error, /isn't a list/)
      expect { store.append(conversation, [{ "role" => "root", "content" => "x" }]) }.to raise_error(Runeforge::Error, /known role/)
      expect(store.messages(conversation)).to be_empty
    end
  end
end
