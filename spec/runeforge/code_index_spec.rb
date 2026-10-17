# frozen_string_literal: true

RSpec.describe Runeforge::CodeIndex do
  APP = <<~JS
    import { db } from "./db.js";
    import { feed } from "./routes/calendar.js";

    export function createApp() {
      const app = express();
      app.get("/api/health", (req, res) => res.json({ ok: true }));
      app.post("/api/bookings", (req, res) => {
        const guests = req.body.guests ?? 0;
        res.status(201).json({ guests });
      });
      app.get("/api/members/:id/calendar.ics", feed);
      return app;
    }
  JS
  CALENDAR = <<~JS
    export function feed(req, res) {
      res.type("text/calendar").send("BEGIN:VCALENDAR\\r\\nVERSION:2.0");
    }
  JS
  TEST = <<~JS
    import { createApp } from "../server/app.js";
    describe("calendar feed", () => {
      it("returns a calendar", () => {});
    });
  JS

  it "splits files into route handlers, functions, components and tests" do
    chunks = described_class.chunk("server/app.js", APP)
    expect(chunks.map { |c| [c[:kind], c[:symbol]] }).to include(["function", "createApp"], ["route", "GET /api/health"],
                                                                 ["route", "POST /api/bookings"], ["route", "GET /api/members/:id/calendar.ics"])
    expect(chunks.find { |c| c[:symbol] == "POST /api/bookings" }[:text]).to include("req.body.guests")
    expect(described_class.chunk("web/src/Book.jsx", "export function Book() {\n  return <div/>;\n}\n").first[:kind]).to eq("component")
    expect(described_class.chunk("test/feed.test.js", TEST).map { |c| c[:kind] }.uniq).to eq(["window", "test"]).or eq(["test"])
    long = (1..300).map { |n| "line #{n}\n" }.join
    expect(described_class.chunk("notes.sh", long).size).to eq(5)
  end

  it "resolves relative imports to files in the tree" do
    tree = { "server/db.js" => "a", "server/routes/calendar.js" => "b", "web/src/index.js" => "c" }
    expect(described_class.resolve("server/app.js", "./db.js", tree)).to eq("server/db.js")
    expect(described_class.resolve("server/app.js", "./routes/calendar", tree)).to eq("server/routes/calendar.js")
    expect(described_class.resolve("web/main.js", "./src", tree)).to eq("web/src/index.js")
    expect(described_class.resolve("server/app.js", "express", tree)).to be_nil
  end

  on_each_backend do
    let(:repo_dir) { File.join(tmpdir, "home", "repos", "demo") }
    let(:repos) { Runeforge::RepoStore.new(db, File.join(tmpdir, "home", "repos")) }

    def commit(files)
      FileUtils.mkdir_p(repo_dir)
      sh!("git", "init", "-q", "-b", "main", dir: repo_dir) unless File.directory?(File.join(repo_dir, ".git"))
      files.each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(repo_dir, path)))
        File.write(File.join(repo_dir, path), text)
      end
      sh!("git", "add", "-A", dir: repo_dir)
      sh!("git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "c", dir: repo_dir)
      sh!("git", "rev-parse", "HEAD", dir: repo_dir).strip
    end

    def index(embedder: nil) = described_class.new(db, Runeforge::Config::DEFAULTS["index"], repos:, embedder:)

    it "indexes only file versions it hasn't seen, and leaves out vendored and lock files" do
      first = commit("server/app.js" => APP, "server/routes/calendar.js" => CALENDAR, "test/feed.test.js" => TEST,
                     "node_modules/x/index.js" => "x", "package-lock.json" => "{}", "runeforge/inbox/a.md" => "# a")
      stats = index.index!("demo", first)
      expect(stats).to include(files: 3, new_files: 3)
      second = commit("server/routes/calendar.js" => "#{CALENDAR}// changed\n")
      expect(index.index!("demo", second)).to include(files: 3, new_files: 1)
    end

    it "ranks the chunk an anchor names first, then pulls in the files it imports and that import it" do
      sha = commit("server/app.js" => APP, "server/routes/calendar.js" => CALENDAR, "test/feed.test.js" => TEST,
                   "server/db.js" => "export const db = {};\n")
      code = index
      code.index!("demo", sha)
      anchors = Runeforge::Ledger.anchors("`GET /api/members/:id/calendar.ics` returns the feed")
      results = code.search("demo", sha, query: "iCalendar feed for a member", anchors:)

      expect(results.first.label).to include("server/app.js", "GET /api/members/:id/calendar.ics")
      expect(results.first.why.first).to start_with("anchor")
      expect(results.map(&:path)).to include("server/routes/calendar.js", "test/feed.test.js")
    end

    it "adds meaning from an embedding model and caches vectors by content" do
      calls = []
      fake = lambda do |texts, _model|
        calls << texts.size
        texts.map { |t| t.include?("guests") || t.include?("guest fee") ? [1.0, 0.0] : [0.0, 1.0] }
      end
      embedder = Runeforge::Embedder.new({ "embedding_model" => "fake" }, http: fake)
      sha = commit("server/app.js" => APP, "server/routes/calendar.js" => CALENDAR)
      code = index(embedder:)
      code.index!("demo", sha)
      expect(code.vectors.count).to be_positive
      before = calls.sum
      code.index!("demo", sha)
      expect(calls.sum).to eq(before)

      results = code.search("demo", sha, query: "guest fee", anchors: [])
      expect(results.first.symbol).to eq("POST /api/bookings")
      expect(results.first.why.join).to include("meaning")
    end
  end
end
