# frozen_string_literal: true

RSpec.describe Runeforge::Config do
  around do |example|
    saved = ENV.fetch("RUNEFORGE_CONFIG", nil)
    ENV.delete("RUNEFORGE_CONFIG")
    Dir.chdir(tmpdir) { example.run }
  ensure
    saved ? ENV["RUNEFORGE_CONFIG"] = saved : ENV.delete("RUNEFORGE_CONFIG")
  end

  it "recognizes test files for Swift, Xcode, Android, the JVM and .NET, but not their sources" do
    globs = described_class::DEFAULTS["test_globs"]
    test = ->(path) { globs.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
    expect(%w[Tests/WordReelCoreTests/ViewportTests.swift WordReelTests/ViewportTests.swift
              WordReel/WordReelUITests/LaunchTests.swift app/src/test/java/com/x/FooTest.kt
              app/src/androidTest/java/com/x/MainActivityTest.kt Api.Tests/ParserTests.cs]).to all(satisfy(&test))
    expect(%w[Sources/WordReelCore/Viewport.swift Package.swift WordReel/ContentView.swift
              app/src/main/java/com/x/MainActivity.kt Api/Parser.cs]).to all(satisfy { |path| !test.call(path) })
  end

  it "reads ~/.runeforge/runeforge.yml, wherever it's run from" do
    File.write("runeforge.yml", "home: /somewhere/else\n")
    expect(described_class.locate).to eq(File.join(Dir.home, ".runeforge", "runeforge.yml"))
  end

  it "takes -c over RUNEFORGE_CONFIG over the home directory" do
    ENV["RUNEFORGE_CONFIG"] = "from-env.yml"
    expect(described_class.locate).to eq(File.join(Dir.pwd, "from-env.yml"))
    expect(described_class.locate("explicit.yml")).to eq(File.join(Dir.pwd, "explicit.yml"))
  end

  it "points out a runeforge.yml in the current directory that isn't used" do
    expect(described_class.stray_config(described_class.locate)).to be_nil
    File.write("runeforge.yml", "workers: []\n")
    expect(described_class.stray_config(described_class.locate)).to eq(File.join(Dir.pwd, "runeforge.yml"))
    expect(described_class.stray_config(File.join(Dir.pwd, "runeforge.yml"))).to be_nil # in use via -c
  end
end

RSpec.describe Runeforge::Config, "per-project settings" do
  def config(projects, **top)
    described_class.new(described_class.deep_merge(described_class::DEFAULTS, { "projects" => projects }.merge(top.transform_keys(&:to_s))))
  end

  let(:local) { { name: "emoji-tasks-ac368a", url: File.join(Dir.home, "code", "emoji-tasks") } }
  let(:github) { { name: "api", url: "git@github.com:acme/api.git" } }

  it "matches a project by its directory, repo name or git URL, and falls back to the top level" do
    by_dir = config({ "~/code/emoji-tasks/" => { "manual_merge" => true } })
    expect(by_dir.for_project(local, "manual_merge")).to be(true)
    expect(by_dir.for_project(github, "manual_merge")).to be(false)

    expect(config({ "api" => { "manual_merge" => true } }).for_project(github, "manual_merge")).to be(true)
    expect(config({ "git@github.com:acme/api" => { "merge_method" => "squash" } }).for_project(github, "merge_method")).to eq("squash")
    expect(config({ "api" => { "merge_method" => "squash" } }).for_project(github, "manual_merge")).to be(false)
    expect(config({}, manual_merge: true).for_project(local, "manual_merge")).to be(true)
    expect(config({ "~/code/emoji-tasks" => { "manual_merge" => false } }, manual_merge: true).for_project(local, "manual_merge")).to be(false)
  end

  it "only allows project-level settings, with valid values" do
    path = File.join(tmpdir, "runeforge.yml")
    File.write(path, <<~YAML)
      projects:
        ~/code/emoji-tasks: { manual_merge: "yes", merge_method: fast, poll_seconds: 1 }
        api: true
    YAML
    expect(described_class.problems(path)).to contain_exactly(
      "`projects.~/code/emoji-tasks.manual_merge` must be true or false",
      "`projects.~/code/emoji-tasks.merge_method` must be one of merge, squash, rebase",
      "`projects.~/code/emoji-tasks.poll_seconds`: only manual_merge, merge_method, sandbox can be set per project",
      "`projects.api` must be a mapping of settings"
    )
  end
end
