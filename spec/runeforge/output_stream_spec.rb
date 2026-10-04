# frozen_string_literal: true

RSpec.describe Runeforge::OutputStream do
  let(:backend) { "sqlite" }
  let(:msg) do
    Runeforge::Message.new(id: 7, task_id: "T-1", type: "code.request", recipient: "coder", sender: "supervisor",
                           in_reply_to: nil, commit_sha: nil, payload: {}, state: "claimed", claimed_by: "w1",
                           lease_expires_at: nil, delivery_count: 1, last_error: nil, created_at: nil)
  end

  def outputs = Runeforge::Events.since(db).select { |e| e[:kind] == "agent.output" }

  def text = outputs.map { |e| e[:data]["text"] }.join

  it "batches writes into a few events" do
    stream = described_class.new(db, msg, flush_seconds: 60)
    10.times { |i| stream.say("line #{i}") }
    expect(outputs).to be_empty

    stream.close
    expect(outputs.size).to eq(1)
    expect(outputs.first).to include(task_id: "T-1", message_id: 7, actor: "w1")
    expect(outputs.first[:data]).to include("role" => "coder", "stream" => "stdout")
    expect(text).to eq((0..9).map { |i| "line #{i}\n" }.join)
  end

  it "flushes on its own after flush_seconds" do
    stream = described_class.new(db, msg, flush_seconds: 0.05)
    stream.say("hello")
    sleep 0.3
    expect(text).to eq("hello\n")
    stream.close
  end

  it "stops at max_bytes with a note" do
    stream = described_class.new(db, msg, flush_seconds: 60, max_bytes: 10)
    stream.write("x" * 50)
    stream.write("more")
    stream.close
    expect(text).to eq("#{'x' * 10}\n[output truncated]\n")
  end

  it "follows a file while the block runs, without following symlinks" do
    File.write(File.join(tmpdir, "secret"), "do not read")
    File.symlink(File.join(tmpdir, "secret"), File.join(tmpdir, "err"))
    out = File.join(tmpdir, "out")
    stream = described_class.new(db, msg, flush_seconds: 0.02)
    stream.follow("stdout" => out, "stderr" => File.join(tmpdir, "err")) do
      File.write(out, "first\n")
      sleep 0.2
      File.write(out, "second\n", mode: "a")
    end
    stream.close
    expect(text).to eq("first\nsecond\n")
  end
end
