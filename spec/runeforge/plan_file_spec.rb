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

  it "keeps a prompt as one step even when it looks like a list" do
    plan = described_class.parse("- do this\n- and that\n", list: false, source: "prompt")
    expect(plan.steps.size).to eq(1)
  end
end

RSpec.describe Runeforge::PlanFile, "plans organized by headings" do
  it "makes each step heading one step, bullets included (the WordReel roadmap)" do
    plan = described_class.parse(File.read(File.expand_path("../fixtures/wordreel_roadmap.md", __dir__)))

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
