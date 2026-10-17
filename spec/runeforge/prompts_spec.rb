# frozen_string_literal: true

RSpec::Matchers.define_negated_matcher :not_include, :include

RSpec.describe Runeforge::Prompts do
  let(:task) { { id: "T-1", title: "Greet", spec: "Say hello.", max_attempts: 5 } }

  it "asks the planner to record how the project runs and to require a README that says so" do
    prompt = described_class.plan(task:, input: { "title" => "Greet" }, test_globs: ["test/**/*"], test_command: "")
    expect(prompt).to include('"run_command": "...", "run_command_new": false',
                              "## How it runs", "First find how the project already runs",
                              "rename or repurpose scripts",
                              'a README.md with a "How to run" section', "`npm start` must work", "don't load from file://")
  end

  it "replaces the run conventions with one line once the project's run command is recorded" do
    prompt = described_class.plan(task:, input: { "title" => "Greet" }, test_globs: ["test/**/*"], test_command: "",
                                  run_command: "npm start")
    expect(prompt).to include("## How it runs\nThe project runs with `npm start`. Keep that working", "## Tests that can pass")
    expect(prompt).not_to include("First find how the project already runs")
  end

  it "shows the planner pitfalls from earlier steps, and nothing when there are none" do
    pitfalls = [{ step: "Step 2: API", text: "the test command ran\nno tests" }]
    prompt = described_class.plan(task:, input: { "title" => "Greet" }, test_globs: [], test_command: "", pitfalls:)
    expect(prompt).to include("## Known pitfalls in this project", "- (Step 2: API) the test command ran no tests")
    expect(described_class.plan(task:, input: {}, test_globs: [], test_command: "")).not_to include("Known pitfalls")
  end

  it "asks the planner for a UI brief and a browser test when the step changes the UI, unless the plan says never" do
    prompt = described_class.plan(task:, input: { "title" => "Greet" }, test_globs: [], test_command: "")
    expect(prompt).to include("## User interface changes", "Decide whether this step changes what a person sees",
                              "`.runeforge/ui.md`", "**Screens**", "**Match**", "desktop (1280px) and phone (390px)",
                              "A job that broadcasts a result is only done when the page shows it")
    expect(prompt).to include("update that test in this plan")
    always = described_class.plan(task:, input: {}, test_globs: [], test_command: "", ux_review: "always")
    expect(always).to include("The plan asks for a UX review of this step").and not_include("Decide whether")
    expect(described_class.plan(task:, input: {}, test_globs: [], test_command: "", ux_review: "never"))
      .not_to include("User interface changes", "ui.md")
  end

  it "gives the coder the UI brief and the bar the UX reviewer holds it to" do
    coder = ->(**opts) { described_class.code(task:, attempt: 1, locked_paths: [], test_command: "sh t.sh", **opts) }
    expect(coder.call(ui_brief: "- Screens: /builder/contact")).to include("## User interface", "- Screens: /builder/contact",
                                                                            "Reuse the app's existing partials")
    expect(coder.call).not_to include("## User interface")
  end

  it "tells the UX reviewer where the browser is and how to report" do
    browser = { services: [{ name: "selenium", image: "seleniarm/standalone-chromium" }], app_host: "rails-app",
                env: { "SELENIUM_HOST" => "selenium" }, sandboxed: true }
    prompt = described_class.ux_review(task: task.merge(title: "Contact screen"), brief: "- Screens: /contact", browser:,
                                       changed: ["app/views/contact.html.erb"], setup_command: "sh script/test_setup.sh")
    expect(prompt).to include("UX reviewer for task", "- Screens: /contact", "- app/views/contact.html.erb",
                              "`http://selenium:4444`", "`http://rails-app:<port>`", "SELENIUM_HOST=selenium",
                              "`sh script/test_setup.sh`", "1280px", "390px", "`.runeforge/ux_review.json`")
    none = described_class.ux_review(task:, brief: "x", browser: browser.merge(services: [], env: {}), changed: [])
    expect(none).to include("No browser service runs next to this container").and not_include("4444")
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

  describe "keeping the planner's prompt to what applies" do
    let(:step) { { "title" => "Guests.", "description" => "Guests.\n  A booking may bring guests.", "context" => "# Plan\n\n- [ ] Guests.\n  A booking may bring guests.\n", "step" => "1 of 3" } }

    it "asks for one test per rule, shared helpers, a short spec and a three-line ending" do
      prompt = described_class.plan(task:, input: step, test_globs: ["test/**/*"], test_command: "npx vitest run", stack: ["node"])
      expect(prompt).to include("## How many tests", "One test (`it`, `test`, `def test_`) per rule the step states",
                                "Test only what this step adds or changes", "put new\n  shared setup there",
                                "at most about 25 lines", "end with at most three lines", "## Handoff", ".runeforge/handoff.json")
      expect(prompt).to include("Assertions about behaviour this step adds don't need that walk-through")
    end

    it "keeps only the guidance for the project's stack" do
      node = described_class.plan(task:, input: step, test_globs: ["test/**/*"], test_command: "", stack: ["node"])
      expect(node).to include("JavaScript: node --test, vitest or jest", "Never `node --test <directory>`", "`npx vitest run test/foo.test.js`")
      expect(node).not_to include("XCTest", "Compiled stacks", "cargo test")
      swift = described_class.plan(task:, input: step, test_globs: [], test_command: "", stack: ["swift"])
      expect(swift).to include("XCTest", "Compiled stacks").and not_include("Never `node --test <directory>`")
      unknown = described_class.plan(task:, input: step, test_globs: [], test_command: "")
      expect(unknown).to include("XCTest", "Compiled stacks", "Never `node --test <directory>`")
      expect(described_class.stacks(["package.json", "server/app.js", "ios/App.xcodeproj/project.pbxproj"])).to eq(%w[node swift])
    end

    it "doesn't repeat the step's text, and shortens the UI section for a step that names no screen" do
      prompt = described_class.plan(task:, input: step, test_globs: [], test_command: "", ui_hint: false)
      expect(prompt).to include("## This step\nGuests.\nIt is that item in the request above (1 of 3)")
      expect(prompt.scan("A booking may bring guests.").size).to eq(1)
      expect(prompt).to include("This step names no screen.").and not_include("**Screens**")
      expect(described_class.ui_hint?("title" => "Member week grid", "description" => "UI: a new screen at /book")).to be(true)
      expect(described_class.ui_hint?("title" => "Guests", "description" => "A booking may bring guests")).to be(false)
    end

    it "puts the ledger's brief before the locked tests" do
      prompt = described_class.plan(task:, input: step, test_globs: [], test_command: "", locked_paths: ["test/a.test.js"],
                                    brief: "## Brief from earlier steps\n- t1.r1 Guests")
      expect(prompt.index("## Brief from earlier steps")).to be < prompt.index("## Existing acceptance tests")
      expect(prompt).to include("Start from the files the brief names.")
    end

    it "gives the coder its handoff, the brief and a three-line ending" do
      code = described_class.code(task:, attempt: 1, locked_paths: [], test_command: "sh t.sh", brief: "### What earlier steps learned\n- [gotcha] x")
      expect(code).to include("### What earlier steps learned", "\"implemented\"", "end with at most three lines")
    end
  end
end

