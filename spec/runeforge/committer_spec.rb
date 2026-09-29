# frozen_string_literal: true

RSpec.describe Runeforge::Committer do
  let(:repo) { make_origin }
  let(:base) { sh!("git", "rev-parse", "main", dir: repo).strip }
  let(:committer) do
    described_class.new(repo, limits: Runeforge::Config::DEFAULTS["limits"].merge("max_files_changed" => 3),
                              author_name: "Runeforge", author_email: "runeforge@localhost")
  end

  # Builds a patch the way the sandbox script does: export, snapshot, change, diff.
  def patch
    dir = File.join(tmpdir, "ws-#{SecureRandom.hex(3)}")
    FileUtils.mkdir_p(dir)
    Runeforge::Git.export(base, dir: repo, to: dir)
    sh!("git", "init", "-q", dir: dir)
    sh!("git", "add", "-A", dir: dir)
    sh!("git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "base", dir: dir)
    yield dir
    sh!("git", "add", "-A", dir: dir)
    sh!("git", "diff", "--cached", "--binary", "HEAD", dir: dir)
  end

  def commit(patch_text, **opts)
    committer.commit(patch: patch_text, parent: base, branch: "runeforge/T-1",
                     message: described_class.message("runeforge: attempt 1 for T-1", "Agent-Task" => "T-1"), **opts)
  end

  it "commits the patch on top of the parent with trailers and moves the branch" do
    result = commit(patch { |dir| File.write(File.join(dir, "hello.txt"), "hi\n") })

    expect(result.changed_paths).to eq(["hello.txt"])
    expect(sh!("git", "rev-parse", "runeforge/T-1", dir: repo).strip).to eq(result.sha)
    expect(sh!("git", "rev-parse", "#{result.sha}^", dir: repo).strip).to eq(base)
    expect(sh!("git", "log", "-1", "--format=%B", result.sha, dir: repo)).to include("Agent-Task: T-1")
    expect(sh!("git", "show", "#{result.sha}:hello.txt", dir: repo)).to eq("hi\n")
  end

  it "rejects changes to locked paths" do
    text = patch { |dir| File.write(File.join(dir, "test", "run.sh"), "exit 0\n") }
    expect { commit(text, locked: ["test/run.sh"]) }
      .to raise_error(described_class::PatchRejected, /locked test files: test\/run.sh/)
  end

  it "rejects changes inside .runeforge/" do
    text = patch do |dir|
      FileUtils.mkdir_p(File.join(dir, ".runeforge"))
      File.write(File.join(dir, ".runeforge", "result.json"), "{}")
    end
    expect { commit(text) }.to raise_error(described_class::PatchRejected, /touches .runeforge/)
  end

  it "rejects paths outside the allow list" do
    text = patch { |dir| File.write(File.join(dir, "app.rb"), "x\n") }
    expect { commit(text, allow: ->(path) { path.start_with?("test/") }) }
      .to raise_error(described_class::PatchRejected, /outside the allowed paths: app.rb/)
  end

  it "rejects empty, oversized, too-wide and non-applying patches" do
    expect { commit("") }.to raise_error(described_class::PatchRejected, /no changes/)
    expect { commit("x" * 3_000_000) }.to raise_error(described_class::PatchRejected, /bytes/)
    wide = patch { |dir| 4.times { |i| File.write(File.join(dir, "f#{i}"), "x") } }
    expect { commit(wide) }.to raise_error(described_class::PatchRejected, /changes 4 files \(limit 3\)/)
    expect { commit("diff --git a/nope b/nope\n--- a/nope\n+++ b/nope\n@@ -1 +1 @@\n-a\n+b\n") }
      .to raise_error(described_class::PatchRejected, /does not apply/)
  end

  it "never leaves the branch pointing at a rejected commit" do
    text = patch { |dir| File.write(File.join(dir, "test", "run.sh"), "exit 0\n") }
    expect { commit(text, locked: ["test/run.sh"]) }.to raise_error(described_class::PatchRejected)
    expect(Runeforge::Git.run("rev-parse", "--verify", "--quiet", "runeforge/T-1", dir: repo, allow_failure: true)).to be_nil
  end
end
