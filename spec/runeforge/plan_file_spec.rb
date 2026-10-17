# frozen_string_literal: true

RSpec.describe Runeforge::PlanFile do
  it "reads front matter and keeps it out of the plan text" do
    plan = described_class.parse(<<~MD)
      ---
      title: CSV export
      after: reports-page
      replaces: [csv-v1, csv-v2]
      max_attempts: 3
      ---
      # Export reports

      - Add a CSV button
      - Stream large exports
    MD

    expect(plan.title).to eq("CSV export")
    expect(plan.meta).to eq("title" => "CSV export", "after" => ["reports-page"], "replaces" => %w[csv-v1 csv-v2], "max_attempts" => 3)
    expect(plan.text).to start_with("# Export reports")
    expect(plan.steps.map(&:title)).to eq(["Add a CSV button", "Stream large exports"])
  end

  it "treats a plan without front matter as before" do
    plan = described_class.parse("# Greeter\n\nSay hello.\n")
    expect(plan.meta).to eq("after" => [], "replaces" => []).or eq({})
    expect(plan.steps.size).to eq(1)
    expect(plan.title).to eq("Greeter")
  end

  it "rejects broken or nonsensical front matter" do
    expect { described_class.parse("---\nafter: [\n---\n# x\n") }.to raise_error(Runeforge::Error, /not valid YAML/)
    expect { described_class.parse("---\n- a\n---\n# x\n") }.to raise_error(Runeforge::Error, /YAML mapping/)
    expect { described_class.parse("---\nafter: ../etc\n---\n# x\n") }.to raise_error(Runeforge::Error, /not a plan name/)
    expect { described_class.parse("---\nmax_attempts: -1\n---\n# x\n") }.to raise_error(Runeforge::Error, /positive whole number/)
  end

  it "reads ux_review as auto, always or never, with yes and no meaning always and never" do
    expect(described_class.parse("---\nux_review: Always\n---\n# x\n").meta["ux_review"]).to eq("always")
    expect(described_class.parse("---\nux_review: no\n---\n# x\n").meta["ux_review"]).to eq("never")
    expect(described_class.parse("# x\n").meta).not_to have_key("ux_review")
    expect { described_class.parse("---\nux_review: sometimes\n---\n# x\n") }
      .to raise_error(Runeforge::Error, /ux_review in the front matter must be auto, always or never/)
  end

    it "warns about front matter keys it doesn't know, suggesting the one meant" do
    plan = described_class.parse("---\nretries: 3\ntitel: CSV\ncolour: red\n---\n# Export\n")
    expect(plan.warnings).to eq([
                                  "unknown front matter key `retries` (ignored); did you mean `max_attempts`?",
                                  "unknown front matter key `titel` (ignored); did you mean `title`?",
                                  "unknown front matter key `colour` (ignored); known keys: title, after, replaces, max_attempts, steps, ux_review"
                                ])
    expect(plan.meta).not_to include("max_attempts")
    expect(described_class.parse("---\ntitle: CSV\n---\n# Export\n").warnings).to eq([])
  end

  it "keeps a prompt as one step even when it looks like a list" do
    plan = described_class.parse("- do this\n- and that\n", list: false, source: "prompt")
    expect(plan.steps.size).to eq(1)
  end
end

RSpec.describe Runeforge::PlanFile, "plans organized by headings" do
  let(:roadmap) { File.read(File.expand_path("../fixtures/wordreel_roadmap.md", __dir__)) }

  it "makes each step heading one step, bullets included (the WordReel roadmap)" do
    plan = described_class.parse("---\nsteps: each\n---\n#{roadmap}")

    expect(plan.steps.size).to eq(13)
    expect(plan.steps.first.title).to eq("Step 1: Project Setup & Viewport")
    expect(plan.steps.first.body).to include("Set project aspect ratio to portrait", "Create base UI canvas")
    expect(plan.steps.map(&:title)).not_to include(a_string_including("TBD"))
    expect(plan.steps[2].body).not_to end_with("---")
  end

  it "prefers steps inside phases, skips checked headings and ignores code blocks" do
    plan = described_class.parse(<<~MD)
      # App

      ## Phase 1: Basics
      ### [x] Step 1: Done already
      - old work
      ### Step 2: Login
      - email and password
      ```markdown
      ### Step 99: not a real heading
      ```
      ## Phase 2: Extras
      ### Step 3: Settings
      - dark mode
    MD
    expect(plan.steps.map(&:title)).to eq(["Step 2: Login", "Step 3: Settings"])
    expect(plan.steps.first.body).to include("email and password", "Step 99: not a real heading")
  end

  it "keeps task lists as they were when there are no step headings" do
    plan = described_class.parse("# Greeter\n\n## Notes\n\n- Add a greeting\n- Add a farewell\n")
    expect(plan.steps.map(&:title)).to eq(["Add a greeting", "Add a farewell"])
  end
end

RSpec.describe Runeforge::PlanFile, "grouping steps into tasks" do
  def plan(items, steps: nil)
    front = steps.nil? ? "" : "---\nsteps: #{steps}\n---\n"
    described_class.parse("#{front}#{(1..items).map { |n| "- Part #{n}\n" }.join}")
  end

  it "runs one task per step however long the plan is" do
    expect(plan(3).steps.map(&:title)).to eq(["Part 1", "Part 2", "Part 3"])
    expect(plan(9).steps.size).to eq(9)
    expect(plan(9, steps: "each").steps.size).to eq(9)
  end

  it "keeps the WordReel roadmap's 13 step headings as 13 tasks" do
    plan = described_class.parse(File.read(File.expand_path("../fixtures/wordreel_roadmap.md", __dir__)))

    expect(plan.steps.size).to eq(13)
    expect(plan.steps.first.body).to include("Step 1: Project Setup")
  end

  it "groups steps when steps: N asks for at most N tasks" do
    expect(plan(9, steps: 2).steps.map(&:title)).to eq(["Part 1 (+4 more)", "Part 6 (+3 more)"])
    expect(plan(9, steps: 3).steps.first.body).to eq("Part 1\n\nPart 2\n\nPart 3")
    expect(plan(2, steps: 5).steps.size).to eq(2)
  end

  it "shortens a long group title to fit" do
    long = described_class.parse("---\nsteps: 2\n---\n- #{'x' * 80}\n- b\n- c\n- d\n")
    expect(long.steps.first.title).to end_with("… (+1 more)").and(have_attributes(size: 72))
  end

  it "refuses any other steps value" do
    expect { plan(4, steps: "some") }.to raise_error(Runeforge::Error, /steps in the front matter must be auto, each/)
    expect { plan(4, steps: 0) }.to raise_error(Runeforge::Error, /steps in the front matter/)
  end
end

RSpec.describe Runeforge::PlanFile, "nested lists" do
  it "keeps indented sub-bullets in their ticket instead of making them steps" do
    plan = described_class.parse(<<~MD)
      # Calendar

      - [ ] iCalendar feed.
        `GET /api/members/:id/calendar.ics` returns the member's bookings.
        - One `VEVENT` per active booking.
        - One `VEVENT` per series.
        - Expanded, the feed's events are exactly the member's active bookings.

      - [ ] Member week grid.
        UI: a new screen at `/book`.
        - A court picker above a grid of the week.
        * Every cell has `data-testid="slot-<local start>"`.

      - [ ] Admin closures screen.
         1. A form to add a closure.
    MD

    expect(plan.steps.map(&:title)).to eq(["iCalendar feed.", "Member week grid.", "Admin closures screen."])
    expect(plan.steps.first.body).to include("One `VEVENT` per series.", "Expanded, the feed's events")
    expect(plan.steps[1].body).to include('data-testid="slot-<local start>"')
    expect(plan.steps[2].body).to include("1. A form to add a closure.")
  end

  it "parses the Courtside calendar plan into its three tickets" do
    path = File.expand_path("../fixtures/courtside_calendar.md", __dir__)
    plan = described_class.parse(File.read(path))

    expect(plan.steps.size).to eq(3)
    expect(plan.steps.map(&:title)).to eq(["iCalendar feed.", "Member week grid.", "Admin closures screen."])
  end

  it "takes the first item's indent as the top level" do
    plan = described_class.parse("Intro\n\n  - one\n    - detail\n  - two\n")
    expect(plan.steps.map(&:title)).to eq(%w[one two])
    expect(plan.steps.first.body).to include("- detail")
  end
end
