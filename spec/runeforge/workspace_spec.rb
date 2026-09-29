# frozen_string_literal: true

RSpec.describe Runeforge::Workspace do
  let(:workspace) { described_class.create(root: tmpdir, name: "T-1-a1") }

  it "reads files the sandbox wrote" do
    workspace.write_meta("result.json", "{}")
    expect(workspace.read_meta("result.json", max_bytes: 10)).to eq("{}")
    expect(workspace.read_meta("missing.json", max_bytes: 10)).to be_nil
  end

  it "refuses to follow a symlink out of the workspace" do
    FileUtils.mkdir_p(workspace.meta_dir)
    File.symlink("/etc/hosts", File.join(workspace.meta_dir, "changes.patch"))
    expect { workspace.read_meta("changes.patch", max_bytes: 1_000_000) }.to raise_error(described_class::UnsafeFile, /symlink/)
  end

  it "ignores a .runeforge directory that was replaced by a symlink" do
    outside = File.join(tmpdir, "outside")
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, "changes.patch"), "secret")
    File.symlink(outside, workspace.meta_dir)
    expect(workspace.read_meta("changes.patch", max_bytes: 100)).to be_nil
  end

  it "refuses oversized files" do
    workspace.write_meta("agent.out", "x" * 20)
    expect { workspace.read_meta("agent.out", max_bytes: 10) }.to raise_error(described_class::UnsafeFile, /20 bytes/)
  end

  it "removes itself on cleanup" do
    workspace.cleanup!
    expect(File.exist?(workspace.path)).to be(false)
  end
end
