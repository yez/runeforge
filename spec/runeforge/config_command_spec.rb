# frozen_string_literal: true

RSpec.describe Runeforge::ConfigCommand do
  let(:backend) { "sqlite" }
  let(:path) { File.join(tmpdir, "conf", "runeforge.yml") }
  let(:editor) { File.join(tmpdir, "fake-editor") }

  around do |example|
    saved = %w[VISUAL EDITOR].to_h { |name| [name, ENV.fetch(name, nil)] }
    example.run
  ensure
    saved.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
  end

  # A stand-in editor: records its arguments and replaces the file with `content`.
  def fake_editor(content)
    File.write(editor, <<~SH)
      #!/bin/sh
      echo "$@" > #{tmpdir}/editor-args
      for file; do :; done
      cat > "$file" <<'YAML'
      #{content}YAML
    SH
    File.chmod(0o755, editor)
    ENV.delete("VISUAL")
    ENV["EDITOR"] = editor
  end

  def cli(*args, stdin: StringIO.new)
    out = StringIO.new
    original_out, original_in = $stdout, $stdin
    $stdout, $stdin = out, stdin
    begin
      Runeforge::CLI.start([*args, "--config", path, "--database", "sqlite://#{File.join(tmpdir, 'test.db')}"])
    rescue SystemExit
      nil
    end
    out.string
  ensure
    $stdout, $stdin = original_out, original_in
  end

  it "creates the config with commented examples and opens it in $EDITOR" do
    fake_editor("agent:\n  model: gemini-2.5-pro\n")
    output = cli("config", "edit")

    expect(output).to include("Created #{path}", "#{path} looks good.")
    expect(File.read(File.join(tmpdir, "editor-args")).strip).to eq(path)
    expect(File.read(path)).to eq("agent:\n  model: gemini-2.5-pro\n")
  end

  it "prefers $VISUAL and passes editor arguments through" do
    fake_editor("{}\n")
    ENV["VISUAL"] = "#{editor} --wait"
    ENV["EDITOR"] = "false"
    cli("config", "edit")
    expect(File.read(File.join(tmpdir, "editor-args")).strip).to eq("--wait #{path}")
  end

  it "reports what's wrong after editing" do
    fake_editor("agent:\n  adapter: gemini\n  roles:\n    tester: { model: gpt-5 }\nmodle: x\n")
    output = cli("config", "edit")

    expect(output).to include("Problems in #{path}:", "unknown setting `modle`", "`agent.roles.tester`: only planner and coder",
                              "`agent.adapter`: unknown agent \"gemini\" (the Gemini CLI is deprecated")
  end

  it "points out broken YAML" do
    fake_editor("agent: [\n")
    expect(cli("config", "edit")).to include("is not valid YAML")
  end

  it "prints the config path and the settings in effect" do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "manual_merge: true\n")
    expect(cli("config", "path").strip).to eq(path)
    shown = cli("config", "show")
    expect(shown).to start_with("# #{path}\n")
    expect(YAML.safe_load(shown)).to include("manual_merge" => true, "merge_method" => "merge")
  end
end
