# frozen_string_literal: true

module Helpers
  def self.included(base)
    base.let(:tmpdir) { File.realpath(Dir.mktmpdir("runeforge-spec")) }
    base.let(:db) { Backends.connect(backend, tmpdir) }
    base.after do
      db.disconnect if respond_to?(:backend)
      FileUtils.rm_rf(tmpdir)
    end
  end

  def sh!(*cmd, dir:)
    out, err, status = Open3.capture3(*cmd, chdir: dir)
    raise "#{cmd.join(' ')} failed: #{err}" unless status.success?

    out
  end

  # A bare "origin" with a main branch, plus a tiny shell-based test suite.
  def make_origin
    work = File.join(tmpdir, "origin-work")
    origin = File.join(tmpdir, "origin.git")
    FileUtils.mkdir_p(File.join(work, "test"))
    File.write(File.join(work, "README.md"), "demo\n")
    File.write(File.join(work, "test", "run.sh"), <<~SH)
      status=0
      for t in test/*_test.sh; do
        [ -e "$t" ] || continue
        sh "$t" || { echo "FAIL $t"; status=1; }
      done
      exit $status
    SH
    sh!("git", "init", "-q", "-b", "main", dir: work)
    sh!("git", "add", "-A", dir: work)
    sh!("git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "init", dir: work)
    sh!("git", "clone", "-q", "--bare", work, origin, dir: tmpdir)
    origin
  end

  # A fake agent CLI. The body decides what the planner and coder do; both print a usage line.
  def fake_agent(plan:, code:)
    path = File.join(tmpdir, "fake_agent_#{SecureRandom.hex(3)}.sh")
    File.write(path, <<~SH)
      case "$RUNEFORGE_PROMPT" in
        *"planning agent"*)
      #{plan}
          ;;
        *)
      #{code}
          ;;
      esac
      echo '{"input_tokens":100,"output_tokens":20,"cost_usd":0.01}'
    SH
    path
  end

  PLAN_GREETING = <<~SH
    mkdir -p test
    printf 'Say hello to Runeforge.\\n' > .runeforge/spec.md
    printf 'grep -q "Hello, Runeforge" lib/greeting.txt\\n' > test/greeting_test.sh
  SH

  CODE_GREETING = <<~SH
    mkdir -p lib
    printf 'Hello, Runeforge\\n' > lib/greeting.txt
  SH

  class FakeGitHub
    attr_reader :calls

    # opens_prs: false behaves like the real client does for remotes that aren't on GitHub.
    def initialize(opens_prs: true)
      @calls = []
      @opens_prs = opens_prs
    end

    def find_or_create_pull(**args)
      @calls << args
      "https://github.com/acme/demo/pull/1" if @opens_prs
    end
  end

  class FakeJira
    def configured? = false
  end

  def build_env(overrides = {})
    settings = Runeforge::Config.deep_merge(
      {
        "home" => File.join(tmpdir, "home"),
        "poll_seconds" => 0.01,
        "heartbeat_seconds" => 0.05,
        "sandbox" => { "mode" => "none", "timeout_seconds" => 60 },
        "agent" => { "adapter" => "command", "command" => "true" }
      },
      overrides
    )
    config = Runeforge::Config.new(Runeforge::Config.deep_merge(Runeforge::Config::DEFAULTS, settings))
    Runeforge::Environment.new(config, db:).tap do |env|
      env.github = FakeGitHub.new
      env.jira = FakeJira.new
    end
  end

  def add_repo(env, name: "demo", url: make_origin)
    env.repos.add(name:, url:, test_command: "sh test/run.sh")
  end

  # Runs the supervisor and one all-roles worker in turn until the task reaches a status.
  def drive(env, task_id, until_status:, steps: 60)
    supervisor = Runeforge::Supervisor.new(env)
    worker = Runeforge::Worker.new(env, roles: Runeforge::Roles.names)
    steps.times do
      supervisor.tick
      task = env.tasks.find!(task_id)
      return task if Array(until_status).include?(task[:status])

      worker.work_once
    end
    raise "task #{task_id} stuck in #{env.tasks.find!(task_id)[:status]}"
  end
end
