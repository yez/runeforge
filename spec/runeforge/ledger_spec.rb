# frozen_string_literal: true

RSpec.describe Runeforge::Ledger do
  on_each_backend do
    let(:ledger) { described_class.new(db, Runeforge::Config::DEFAULTS["ledger"]) }
    let(:calendar) { Runeforge::PlanFile.parse(File.read(File.expand_path("../fixtures/courtside_calendar.md", __dir__))) }

    def plan_row(id, name, replaces: [])
      { id:, name:, replaces: JSON.generate(replaces) }
    end

    def task_row(id, status: "running")
      db[:runeforge_tasks].insert(id:, workflow: "inbox", status:, repo: "demo", base_sha: "a" * 40, branch: "b/#{id}",
                                  created_at: Runeforge.now, updated_at: Runeforge.now)
      db[:runeforge_tasks].where(id:).first
    end

    it "makes a plan, a ticket per item and a requirement per sub-bullet, with anchors" do
      tickets = ledger.plan_items!(repo: "demo", plan: plan_row(6, "plan-f-calendar-ui"), parsed: calendar)

      expect(tickets).to eq(%w[plan-f-calendar-ui-p6.t1 plan-f-calendar-ui-p6.t2 plan-f-calendar-ui-p6.t3])
      feed = ledger.children("plan-f-calendar-ui-p6.t1")
      expect(feed.size).to be >= 3
      expect(feed.map { |r| r[:title] }).to include(a_string_starting_with("Expanded, the feed's events are exactly"))
      expect(ledger.anchors_of("plan-f-calendar-ui-p6.t1")).to include(["route", "GET /api/members/:p/calendar.ics"])
      expect(ledger.anchors_of("plan-f-calendar-ui-p6.t2").map(&:first)).to include("testid")
      expect(ledger.links_of("plan-f-calendar-ui-p6.t2", types: ["blocks"]).first[:to_id]).to eq("plan-f-calendar-ui-p6.t1")
      # Starting the plan again keeps its items.
      ledger.plan_items!(repo: "demo", plan: plan_row(6, "plan-f-calendar-ui"), parsed: calendar)
      expect(ledger.items.where(id: "plan-f-calendar-ui-p6.t1").count).to eq(1)
    end

    it "reads routes, testids, paths, fields and symbols out of text" do
      found = described_class.anchors("`POST /api/bookings/:id/cancel` sets `cancelled_at`; see `server/routes/bookings.js`, " \
                                      "`createBooking()` and data-testid=\"slot-<local start>\"")
      expect(found).to include(["route", "POST /api/bookings/:p/cancel"], ["field", "cancelled_at"], ["path", "server/routes/bookings.js"],
                               ["symbol", "createBooking"], ["testid", "slot-"])
    end

    it "splits a ticket into its sub-bullets, or keeps it whole" do
      expect(described_class.requirements("Guests.\n  A booking may bring guests.\n  Each guest costs 1000.")).to eq(["Guests.\nA booking may bring guests.\nEach guest costs 1000."])
      reqs = described_class.requirements("Pricing.\n  Every booking has a price.\n  - Making a booking charges.\n    the price\n  - Topups add credit.")
      expect(reqs).to eq(["Pricing.\nEvery booking has a price.", "Making a booking charges.\nthe price", "Topups add credit."])
    end

    it "links another plan's item that shares strong anchors as a duplicate, and one it changes as extends" do
      first = Runeforge::PlanFile.parse("- [ ] Feed.\n  `GET /api/members/:id/calendar.ics` returns the feed.\n- [ ] Other.\n  Nothing.\n")
      ledger.plan_items!(repo: "demo", plan: plan_row(1, "feed"), parsed: first)
      ledger.items.where(Sequel.like(:id, "feed-p1.t1%")).update(status: "done", close_reason: "built by feed-p1-s1")
      again = Runeforge::PlanFile.parse("- [ ] Calendar feed.\n  `GET /api/members/:member/calendar.ics` returns the feed.\n- [ ] More.\n  x\n")
      ledger.plan_items!(repo: "demo", plan: plan_row(2, "feed-again"), parsed: again)

      link = ledger.links_of("feed-again-p2.t1", types: ["duplicates"]).first
      expect(link).to include(to_id: "feed-p1.t1")
      expect(link[:note]).to include("GET /api/members/:p/calendar.ics")

      change = Runeforge::PlanFile.parse("- [ ] Feed changes.\n  `GET /api/members/:id/calendar.ics` now leaves out lessons, " \
                                         "and `GET /api/members/:id/bookings` too.\n- [ ] x\n  y\n")
      ledger.plan_items!(repo: "demo", plan: plan_row(3, "feed-change"), parsed: change)
      expect(ledger.links_of("feed-change-p3.t1").map { |l| l[:type] }).to include("extends").or include("duplicates")
    end

    it "claims a ticket for one running task at a time, and lets a retry take it back" do
      ledger.plan_items!(repo: "demo", plan: plan_row(6, "plan-f-calendar-ui"), parsed: calendar)
      task_row("s1")
      expect(ledger.claim!("demo", ["plan-f-calendar-ui-p6.t1"], "s1")).to eq(["plan-f-calendar-ui-p6.t1"])
      expect(ledger.requirements_of("plan-f-calendar-ui-p6.t1").map { |r| r[:task_id] }.uniq).to eq(["s1"])

      task_row("s1-r2")
      expect(ledger.claim!("demo", ["plan-f-calendar-ui-p6.t1"], "s1-r2")).to be_empty
      db[:runeforge_tasks].where(id: "s1").update(status: "failed")
      ledger.release!("s1")
      expect(ledger.claim!("demo", ["plan-f-calendar-ui-p6.t1"], "s1-r2")).to eq(["plan-f-calendar-ui-p6.t1"])
      expect(ledger.find("plan-f-calendar-ui-p6.t1")).to include(task_id: "s1-r2", status: "in_progress")
    end

    it "closes a merged step, points at its code, records its tests and marks older pointers stale" do
      ledger.plan_items!(repo: "demo", plan: plan_row(6, "plan-f-calendar-ui"), parsed: calendar)
      task = task_row("s1")
      ledger.claim!("demo", ["plan-f-calendar-ui-p6.t1"], "s1")
      ledger.add_ref({ repo: "demo", id: "old" }, "plan-x.t1", { "path" => "server/app.js" }, source: "handoff", role: "implements", oid: "o1")

      ledger.close_step!(task, sha: "f" * 40, changed: %w[server/app.js server/routes/calendar.js test/calendar.test.js],
                               test_names: { "test/calendar.test.js" => ["returns an RFC 5545 calendar"] },
                               oids: { "server/app.js" => "o2", "server/routes/calendar.js" => "o3", "test/calendar.test.js" => "o4" })

      expect(ledger.find("plan-f-calendar-ui-p6.t1")).to include(status: "done", closed_sha: "f" * 40)
      expect(ledger.refs.where(task_id: "old").first[:stale]).to be(true)
      expect(ledger.refs_for(["plan-f-calendar-ui-p6.t1"]).map { |r| r[:path] }).to contain_exactly("server/app.js", "server/routes/calendar.js")
      expect(ledger.coverage_for(["plan-f-calendar-ui-p6.t1"]).first).to include(test_name: "returns an RFC 5545 calendar", last_passed_sha: "f" * 40)
    end

    it "treats a later step's requirements as covered once a step builds them with passing tests" do
      ledger.plan_items!(repo: "demo", plan: plan_row(6, "plan-f-calendar-ui"), parsed: calendar)
      first = task_row("s1")
      ledger.claim!("demo", ["plan-f-calendar-ui-p6.t1"], "s1")
      later = ledger.requirements_of("plan-f-calendar-ui-p6.t2").map { |r| r[:id] }
      handoff = { "requirements" => later.map { |id| { "id" => id.sub("plan-f-calendar-ui-p6.", ""), "status" => "already_built",
                                                       "tests" => [{ "path" => "test/grid.test.js", "name" => "grid" }], "code" => [] } } }
      ledger.record_plan!(first, handoff, sha: "c" * 40)
      ledger.close_step!(first, sha: "d" * 40, changed: [], test_names: {}, oids: {})

      task_row("s2")
      ledger.claim!("demo", ["plan-f-calendar-ui-p6.t2"], "s2")
      expect(ledger.covered?("s2")).to be(true)
      expect(ledger.coverage_reason("s2")).to include("t2.r1", "test/grid.test.js > grid")
      expect(ledger.covered?("s1")).to be(true) # its own items are done
    end

    it "queues discovered work with evidence once, at most max_discovered per plan, and never from discovered work" do
      ledger.plan_items!(repo: "demo", plan: plan_row(6, "plan-f-calendar-ui"), parsed: calendar)
      task = task_row("s1")
      ledger.claim!("demo", ["plan-f-calendar-ui-p6.t1"], "s1")
      exists = ->(path) { path == "server/routes/calendar.js" }
      found = [
        { "title" => "Feed omits lesson coach names", "why" => "SUMMARY lacks the coach", "evidence" => "server/routes/calendar.js:42" },
        { "title" => "Make it nicer", "why" => "", "evidence" => "" },
        { "title" => "Feed omits lesson coach names", "why" => "again", "evidence" => "server/routes/calendar.js:42" },
        { "title" => "Bookings list is slow", "evidence" => "missing.js:3" }
      ]
      queued = ledger.discoveries!(task, found, exists:)
      expect(queued.map { |q| q[:title] }).to eq(["Feed omits lesson coach names"])
      expect(ledger.links_of(queued.first[:id], types: ["discovered-from"]).first[:to_id]).to eq("plan-f-calendar-ui-p6.t1")
      expect(ledger.discoveries!(task, found, exists:)).to be_empty

      chained = ledger.discoveries!(task, [{ "title" => "Calendar export to CSV is missing", "evidence" => "server/routes/calendar.js:9" }],
                                    plan_meta: { "discovered_from" => "x-p1-s1" }, exists:)
      expect(chained).to be_empty
      expect(ledger.items.where(kind: "discovered", status: "blocked").count).to eq(1)
    end

    it "keeps facts by key, counts confirmations, and drops the least used over the limit" do
      task = { id: "s1", repo: "demo" }
      ledger.record_facts!(task, [{ "key" => "Test Fixture", "kind" => "convention", "text" => "club() builds a club" }], by: "planner")
      ledger.record_facts!(task, [{ "key" => "test-fixture", "kind" => "convention", "text" => "club() builds a club with two courts" }], by: "coder")
      fact = ledger.facts.where(key: "test-fixture").first
      expect(fact).to include(confirmations: 2, text: "club() builds a club with two courts")

      small = described_class.new(db, "max_facts" => 2)
      small.record_facts!(task, [{ "key" => "b", "text" => "b" }, { "key" => "c", "text" => "c" }], by: "planner")
      expect(small.facts.where(repo: "demo").select_map(:key)).to contain_exactly("test-fixture", "c").or contain_exactly("test-fixture", "b")
      expect(ledger.facts_for("demo", "booking fixture club").map { |f| f[:key] }).to include("test-fixture")
    end

    it "compacts closed items of old plans to their close reason" do
      ledger = described_class.new(db, "compact_after_plans" => 1)
      (1..2).each do |n|
        ledger.plan_items!(repo: "demo", plan: plan_row(n, "plan-#{n}"), parsed: Runeforge::PlanFile.parse("- [ ] A #{n}\n  text #{n}\n- [ ] B\n  x\n"))
      end
      ledger.items.where(plan_id: 1).exclude(kind: "plan").update(status: "done", close_reason: "built")
      ledger.compact!("demo")
      expect(ledger.find("plan-1-p1.t1")).to include(body: nil, close_reason: "built")
      expect(ledger.find("plan-2-p2.t1")[:body]).to include("text 2")
    end
  end
end
