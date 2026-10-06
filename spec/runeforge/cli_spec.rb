# frozen_string_literal: true

RSpec.describe Runeforge::CLI do
  let(:backend) { "sqlite" }
  let(:env) { build_env("agent" => { "command" => "sh #{fake_agent(plan: Helpers::PLAN_GREETING, code: Helpers::CODE_GREETING)}" }) }

  def cli(*args)
    out = StringIO.new
    original = $stdout
    $stdout = out
    described_class.start([*args, "--database", "sqlite://#{File.join(tmpdir, 'test.db')}"])
    out.string
  ensure
    $stdout = original
  end

  before do
    add_repo(env)
    Runeforge::Intake.new(env).create(repo: "demo", id: "T-1", title: "Greet", description: "Say hello")
    drive(env, "T-1", until_status: "done")
  end

  it "shows a task's status and message history" do
    output = cli("status", "T-1")
    expect(output).to include("T-1  jira_to_pr  status: done   attempt 1/5", "branch runeforge/T-1")
    expect(output).to match(/supervisor\s+→ planner\s+plan\.request/)
    expect(output).to match(/tester\s+→ supervisor\s+test\.result/)
    expect(output).to match(/test\.result\s+\h{7}\s+done\s+passed/)
    expect(output).to match(/integrator\s+→ supervisor\s+integrate\.done/)
  end

  it "lists tasks, filtered by status" do
    expect(cli("tasks", "--status", "done")).to include("T-1", "done", "Greet")
    expect(cli("tasks", "--status", "failed")).not_to include("T-1")
  end

  it "lists and prints logs" do
    expect(cli("logs", "T-1")).to include("test.result", "-tester.log")
    tester = env.tasks.messages("T-1").find { |msg| msg.type == "test.result" }
    expect { cli("logs", "T-1", "--message", tester.id.to_s) }.not_to raise_error
  end

  it "shows a project's platform verdict, setup and recent tasks with -d DIR" do
    dir = File.join(tmpdir, "ios-app")
    FileUtils.mkdir_p(File.join(dir, "WordReel.xcodeproj"))
    File.write(File.join(dir, "WordReel.xcodeproj", "project.pbxproj"), "{}\n")
    sh!("git", "init", "-q", "-b", "main", dir:)
    sh!("git", "add", ".", dir:)
    sh!("git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init", dir:)
    env.repos.add(name: "ios", url: dir, test_command: "swift test")
    env.repos.update("ios", platform: "apple", platform_status: "incompatible", platform_note: "needs Xcode",
                            platform_checked_at: Runeforge.now)
    output = cli("status", "-d", dir)
    expect(output).to include("#{dir} (repo ios)", "Status", "incompatible", "WordReel.xcodeproj is an Xcode project",
                              "To fix", "Last check", "needs Xcode", "Merging", "Recent tasks: none", "Inbox: nothing queued")
    expect(cli("-d", dir, "status")).to eq(output)
  end

  it "shows a portable, unregistered directory and the demo repo's tasks" do
    expect(cli("status", "-d", tmpdir)).to include("not registered with runeforge yet", "portable", "compatible")
  end

  it "prints its version" do
    expect(cli("version")).to eq("runeforge #{Runeforge::VERSION}\n")
  end
end

RSpec.describe Runeforge::CLI, ".start" do
  def start(*args)
    err = StringIO.new
    original = $stderr
    $stderr = err
    status = nil
    expect(Runeforge::Build).not_to receive(:new)
    begin
      described_class.start(args)
    rescue SystemExit => e
      status = e.status
    end
    [status, err.string]
  ensure
    $stderr = original
  end

  it "refuses a single unknown word instead of building from it" do
    status, err = start("demoo")
    expect(status).to eq(1)
    expect(err).to include('unknown command "demoo". Did you mean "demo"?', "runeforge build demoo")
  end

  it "reads -d DIR before a command as that command's option, and before a prompt as build's" do
    expect(described_class.dir_first(%w[-d /src status])).to eq(%w[status -d /src])
    expect(described_class.dir_first(%w[--dir=/src status T-1])).to eq(%w[status --dir=/src T-1])
    expect(described_class.dir_first(["-d", "/src", "Add a greeting"])).to eq(["build", "-d", "/src", "Add a greeting"])
    expect(described_class.dir_first(%w[status -d /src])).to eq(%w[status -d /src])
  end

  it "refuses a word with no close command" do
    status, err = start("zzzzzz", "-d", "/tmp")
    expect(status).to eq(1)
    expect(err).not_to include("Did you mean")
  end
end

RSpec.describe Runeforge::RepoCommand do
  let(:backend) { "sqlite" }
  let(:env) { build_env.tap { |e| add_repo(e) } }

  def cli(*args)
    out = StringIO.new
    original = $stdout
    $stdout = out
    Runeforge::CLI.start([*args, "--database", "sqlite://#{File.join(tmpdir, 'test.db')}"])
    out.string
  ensure
    $stdout = original
  end

  it "sets a repository's run command and whether its README must say it" do
    env
    expect(cli("repo", "set", "demo", "--run-command", "foreman start -f Procfile.dev")).to include("run foreman start -f Procfile.dev")
    expect(env.repos.fetch("demo")).to include(run_command: "foreman start -f Procfile.dev", run_docs_required: false)
    expect(cli("repo", "set", "demo", "--require-run-docs")).to include("(README must say it)")
    expect(cli("repo", "list")).to include("RUN", "foreman start -f Procfile.dev")
  end
end
