# frozen_string_literal: true

RSpec.describe Runeforge::Memory do
  on_each_backend do
    let(:settings) { Runeforge::Config::DEFAULTS["memory"] }
    let(:memory) { described_class.new(db, settings) }

    def lesson(text, step: "Step", repo: "demo", task_id: "T-0", kind: "replan")
      memory.record(repo:, task_id:, kind:, step:, text:)
    end

    it "finds the lessons that share the step's rarer words, best first" do
      lesson("the test command `node --test test/` ran no tests: Node loads the directory as a module", step: "Add the API")
      lesson("percent splits must add up to exactly 100; the test used 99.99", step: "Exact and percent splits")
      lesson("README lacked the How to run section", step: "Project setup")

      found = memory.pitfalls(repo: "demo", query: "Add percent splits that add up to 100 percent")
      expect(found.map { |row| row[:step] }).to eq(["Exact and percent splits"])
      expect(memory.pitfalls(repo: "demo", query: "Unrelated colours and fonts")).to be_empty
    end

    it "keeps to the repo, leaves out the step's own task, and caps how much it returns" do
      lesson("percent splits rounding drops a cent", repo: "other")
      lesson("percent splits rounding drops a cent", task_id: "T-9")
      expect(memory.pitfalls(repo: "demo", query: "percent splits rounding", exclude_task: "T-9")).to be_empty
      expect(memory.pitfalls(repo: "demo", query: "percent splits rounding").size).to eq(1)

      4.times { |n| lesson("percent splits rounding #{n} #{'x' * 1500}") }
      expect(memory.pitfalls(repo: "demo", query: "percent splits rounding").sum { |row| row[:text].size })
        .to be <= described_class::MAX_CHARS
    end

    it "matches by meaning with an embedding model, and by words when embedding fails" do
      vectors = { "money" => [1.0, 0.0], "colour" => [0.0, 1.0] }
      memory = described_class.new(db, settings.merge("embedding_model" => "fake-embed"))
      memory.embedder = ->(text, _model) { text.include?("cents") || text.include?("money") ? vectors["money"] : vectors["colour"] }
      memory.record(repo: "demo", kind: "replan", step: "Splits", text: "rounding lost two cents")
      memory.record(repo: "demo", kind: "replan", step: "Theme", text: "the palette clashed")

      expect(memory.pitfalls(repo: "demo", query: "handle money").map { |row| row[:step] }).to eq(["Splits"])
      expect(memory.table.where(step: "Splits").get(:model)).to eq("fake-embed")

      memory.embedder = ->(*) { raise "provider down" }
      expect(memory.pitfalls(repo: "demo", query: "rounding lost two cents again").map { |row| row[:step] }).to eq(["Splits"])
    end

    it "remembers nothing when turned off" do
      memory = described_class.new(db, settings.merge("enabled" => false))
      memory.record(repo: "demo", kind: "failed", text: "percent splits rounding")
      expect(memory.table.count).to eq(0)
      expect(memory.pitfalls(repo: "demo", query: "percent splits rounding")).to be_empty
    end
  end
end
