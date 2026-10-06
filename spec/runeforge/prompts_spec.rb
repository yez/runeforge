# frozen_string_literal: true

RSpec.describe Runeforge::Prompts do
  let(:task) { { id: "T-1", title: "Greet", spec: "Say hello.", max_attempts: 5 } }

  it "asks the planner to record how the project runs and to require a README that says so" do
    prompt = described_class.plan(task:, input: { "title" => "Greet" }, test_globs: ["test/**/*"], test_command: "")
    expect(prompt).to include('"run_command": "...", "run_command_new": false',
                              "## How it runs", "First find how the project already runs",
                              "rename or repurpose scripts",
                              'a README.md with a "How to run" section', "`npm start` must work", "don't load from file://")
  end

  it "tells the planner how to run Node tests, and why its previous plan was rejected" do
    prompt = Runeforge::Prompts.plan(task: { id: "T-1" }, input: { "title" => "Snake" }, test_globs: ["test/**/*"], test_command: nil,
                                     feedback: "the test command `node --test test/` didn't run the acceptance tests")
    expect(prompt).to include("Never `node --test <directory>`", "a runner crash reported as a single failing test",
                              "## Your previous plan was rejected", "`node --test test/` didn't run the acceptance tests")
    expect(Runeforge::Prompts.plan(task: { id: "T-1" }, input: {}, test_globs: [], test_command: nil)).not_to include("previous plan")
  end

  it "tells the coder the run command, and asks for README docs only when Runeforge defined it" do
    required = described_class.code(task:, attempt: 1, locked_paths: [], test_command: "npm test", run_command: "npm start",
                                    run_docs_required: true)
    expect(required).to include("The project runs with `npm start`. README.md must have a How to run section")
    existing = described_class.code(task:, attempt: 1, locked_paths: [], test_command: "npm test", run_command: "make dev")
    expect(existing).to include("The project runs with `make dev`; keep that working.")
    expect(existing).not_to include("README.md must")
    without = described_class.code(task:, attempt: 1, locked_paths: [], test_command: "npm test")
    expect(without).not_to include("How to run")
  end
end
