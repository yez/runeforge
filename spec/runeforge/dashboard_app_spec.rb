# frozen_string_literal: true

require "runeforge/web/dashboard_app"

RSpec.describe Runeforge::Web::DashboardApp do
  let(:backend) { "sqlite" }
  let(:env) { build_env }
  let(:hub) { Runeforge::Web::EventHub.new(db) }
  let(:token) { nil }
  let(:app) { Rack::MockRequest.new(described_class.new(env, hub:, token:)) }

  before do
    env.tasks.create(id: "T-1", workflow: "jira_to_pr", repo: "demo", base_sha: "a" * 40, title: "Greet", mailbox: env.mailbox("t"))
  end

  def body(response) = JSON.parse(response.body)

  it "serves the page" do
    response = app.get("/")
    expect(response.status).to eq(200)
    expect(response.body).to include("<title>Runeforge</title>")
  end

  it "returns a snapshot with a cursor to stream from" do
    state = body(app.get("/api/state"))
    expect(state["cursor"]).to eq(Runeforge::Events.cursor(db))
    expect(state["tasks"].map { |t| t["id"] }).to eq(["T-1"])
    expect(state["messages"].map { |m| [m["type"], m["role"], m["state"]] }).to eq([%w[task.created supervisor pending]])
    expect(state["roles"]).to include("supervisor", "planner", "integrator")
    expect(state["dry_run"]).to be(false)
  end

  it "includes the plan queue" do
    now = Runeforge.now
    db[:runeforge_plans].insert(repo: "demo", path: "runeforge/inbox/export.md", name: "export", blob: "b" * 40, title: "Export",
                                arrival: 3, updated: 3, status: "blocked", reason: "waiting on reports", after: '["reports"]',
                                replaces: "[]", created_at: now, updated_at: now)
    plans = body(app.get("/api/state"))["plans"]
    expect(plans).to contain_exactly(include("name" => "export", "status" => "blocked", "reason" => "waiting on reports",
                                             "after" => ["reports"], "arrival" => 3))
  end

  it "returns one task with its messages" do
    detail = body(app.get("/api/tasks/T-1"))
    expect(detail["task"]).to include("id" => "T-1", "status" => "pending")
    expect(detail["messages"].size).to eq(1)
    expect(app.get("/api/tasks/nope").status).to eq(422)
  end

  it "cancels a task only with the dashboard header" do
    expect(app.post("/api/tasks/T-1/cancel").status).to eq(403)
    response = app.post("/api/tasks/T-1/cancel", "HTTP_X_RUNEFORGE_DASHBOARD" => "1", input: "{}")
    expect(response.status).to eq(200)
    expect(env.tasks.find("T-1")[:status]).to eq("cancelled")
  end

  context "with a token" do
    let(:token) { "s3cret" }

    it "requires it on the API but not the page" do
      expect(app.get("/").status).to eq(200)
      expect(app.get("/api/state").status).to eq(401)
      expect(app.get("/api/state?token=s3cret").status).to eq(200)
      expect(app.get("/api/state", "HTTP_X_RUNEFORGE_TOKEN" => "s3cret").status).to eq(200)
    end
  end

  describe Runeforge::Web::EventStream do
    # Collects frames until `count` events have been sent, then hangs up like a closed browser tab.
    def read(stream, count)
      frames = []
      catch(:hang_up) do
        stream.each do |chunk|
          frames << chunk
          throw :hang_up if frames.count { |f| f.start_with?("id: ") } >= count
        end
      end
      frames
    end

    def ids(frames) = frames.grep(/\Aid: /).map { |f| f[/\Aid: (\d+)/, 1].to_i }

    it "sends events after the cursor as SSE frames, then waits for more" do
      after = Runeforge::Events.cursor(db)
      hub.start
      Thread.new do
        sleep 0.1
        Runeforge::Events.emit(db, "worker.started", actor: "w1")
      end
      frames = read(described_class.new(db, hub, after:, keepalive: 5), 1)

      expect(frames.first).to eq("retry: 2000\n\n")
      event = JSON.parse(frames.last[/^data: (.*)$/, 1])
      expect(event).to include("kind" => "worker.started", "actor" => "w1")
      expect(ids(frames)).to eq([after + 1])
    ensure
      hub.stop
    end

    it "resumes from a cursor and filters by task" do
      Runeforge::Events.emit(db, "worker.started", actor: "w1")
      frames = read(described_class.new(db, hub, after: 0, task_id: "T-1"), 2)
      expect(frames.grep(/\Aid: /).map { |f| JSON.parse(f[/^data: (.*)$/, 1])["task_id"] }).to eq(%w[T-1 T-1])
    end

    it "ends when the server shuts down, even while waiting" do
      app = Runeforge::Web::DashboardApp.new(env, hub:)
      stream = described_class.new(db, hub, after: Runeforge::Events.cursor(db), keepalive: 30)
      Thread.new { sleep 0.1; app.shutdown }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      frames = stream.to_enum(:each).to_a

      expect(frames).to eq(["retry: 2000\n\n"])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end

    it "sends a keepalive comment while idle" do
      stream = described_class.new(db, hub, after: Runeforge::Events.cursor(db), keepalive: 0.05)
      frames = []
      catch(:hang_up) { stream.each { |chunk| (frames << chunk).size >= 3 && throw(:hang_up) } }
      expect(frames.drop(1)).to all(eq(": keepalive\n\n"))
    end
  end
end

RSpec.describe Runeforge::Web::DashboardApp, "war camp" do
  let(:backend) { "sqlite" }
  let(:env) { build_env }
  let(:hub) { Runeforge::Web::EventHub.new(db) }

  def get(path, page: :warcamp) = Rack::MockRequest.new(described_class.new(env, page:, hub:)).get(path)

  it "serves the war camp page and its art" do
    expect(get("/").body).to include("<title>Runeforge War Camp</title>")
    meta = JSON.parse(get("/assets/assets.json").body)
    expect(meta["orcs"].keys).to contain_exactly("regular", "elite", "heavy", "archer")

    meta["orcs"].values.map { |orc| orc["src"] }
        .concat(meta["buildings"].values.map { |b| b["src"] }, meta["ui"].values).each do |src|
      response = get("/assets/#{src}")
      expect(response.status).to eq(200), src
      expect(response.content_type).to eq("image/webp")
    end
  end

  it "only serves plain asset file names" do
    expect(get("/assets/../dashboard_app.rb").status).to eq(404)
    expect(get("/assets/%2e%2e%2fdashboard_app.rb").status).to eq(404)
    expect(get("/assets/missing.webp").status).to eq(404)
    expect(get("/assets/assets.txt").status).to eq(404)
  end

  it "keeps the default page unless asked" do
    expect(get("/", page: :dashboard).body).to include("<title>Runeforge</title>")
    expect { described_class.new(env, page: :nope, hub:) }.to raise_error(Runeforge::Error, /unknown dashboard page/)
  end
end
