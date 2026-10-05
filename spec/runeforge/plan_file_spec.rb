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
