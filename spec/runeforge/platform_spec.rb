# frozen_string_literal: true

RSpec.describe Runeforge::Platform do
  describe ".detect" do
    it "finds Apple and Android projects from their files" do
      expect(described_class.detect(paths: ["App/WordReel.xcodeproj/project.pbxproj"]).reason).to eq("WordReel.xcodeproj is an Xcode project")
      package = ->(_path) { "platforms: [.iOS(.v17)]" }
      expect(described_class.detect(paths: ["Package.swift"], read: package).platform).to eq("apple")
      expect(described_class.detect(paths: ["Package.swift"], read: ->(_path) { "// a Linux CLI" })).to be_nil
      expect(described_class.detect(paths: ["Podfile"]).platform).to eq("apple")
      expect(described_class.detect(paths: ["app/src/main/AndroidManifest.xml"]).platform).to eq("android")
    end

    it "reads the request unless only files count" do
      expect(described_class.detect(text: "Build a word game for iPhone").reason).to eq("the request mentions iPhone")
      expect(described_class.detect(text: "An Android app for notes").platform).to eq("android")
      expect(described_class.detect(text: "Build a word game for iPhone", files_only: true)).to be_nil
      expect(described_class.detect(text: "A Rails API with a React front end")).to be_nil
    end
  end

  describe ".scan_dir" do
    it "lists project files, skipping dependency folders" do
      FileUtils.mkdir_p(File.join(tmpdir, "Pods", "X.xcodeproj"))
      FileUtils.mkdir_p(File.join(tmpdir, "app"))
      File.write(File.join(tmpdir, "app", "main.swift"), "print(1)\n")
      paths, read = described_class.scan_dir(tmpdir)
      expect(paths).to include("app/main.swift")
      expect(paths.grep(/Pods/)).to be_empty
      expect(read.call("app/main.swift")).to eq("print(1)\n")
      expect(described_class.scan_dir(nil).first).to eq([])
    end
  end

  describe ".verdict" do
    let(:backend) { "sqlite" }
    let(:apple) { Runeforge::Platform::Need.new(platform: "apple", reason: "it has a Podfile (CocoaPods)") }

    it "is compatible for portable projects anywhere" do
      verdict = described_class.verdict(build_env("sandbox" => { "mode" => "docker" }), nil, nil)
      expect(verdict).to have_attributes(status: "compatible", platform: nil, fix: nil)
    end

    it "sends an Apple app in the Linux sandbox to sandbox: none" do
      verdict = described_class.verdict(build_env("sandbox" => { "mode" => "docker" }), { name: nil, url: "/src/app" }, apple)
      expect(verdict).to be_incompatible
      expect(verdict.environment.description).to start_with("a Linux container (docker sandbox")
      expect(verdict.fix).to include("set `sandbox: none` for it", "projects: { /src/app: { sandbox: none } }")
    end

    it "is compatible on a Mac with Xcode ready to build for iOS" do
      allow(described_class).to receive_messages(mac?: true, xcode: Runeforge::Platform::Xcode.new(version: "Xcode 27.0", problem: nil, fix: nil))
      verdict = described_class.verdict(build_env("sandbox" => { "mode" => "none" }), nil, apple)
      expect(verdict.status).to eq("compatible")
      expect(verdict.environment.description).to eq("this machine (macOS, Xcode 27.0), no sandbox")
    end

    it "is incompatible off a Mac even without a sandbox" do
      allow(described_class).to receive(:mac?).and_return(false)
      verdict = described_class.verdict(build_env("sandbox" => { "mode" => "none" }), nil, apple)
      expect(verdict.fix).to eq("build it on a Mac with Xcode (this machine isn't one)")
    end
  end

  describe ".check_xcode" do
    let(:backend) { "sqlite" }
    def results(**by_flag)
      allow(described_class).to receive(:capture) { |*command| by_flag.fetch(command[1]) }
      described_class.check_xcode
    end

    let(:version) { ["Xcode 27.0\nBuild version 27A266a\n", true] }
    let(:license) { ["You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license'", false] }

    it "needs the full Xcode app" do
      xcode = results("-version" => ["xcode-select: error: tool 'xcodebuild' requires Xcode", false])
      expect(xcode).to have_attributes(version: nil, problem: "no Xcode (Command Line Tools only)")
      expect(xcode.fix).to include("sudo xcode-select -s /Applications/Xcode.app")
    end

    it "needs the license accepted" do
      xcode = results("-version" => version, "-checkFirstLaunchStatus" => license)
      expect(xcode).to have_attributes(version: "Xcode 27.0", problem: "its license isn't accepted",
                                       fix: "accept the Xcode license: `sudo xcodebuild -license accept`")
    end

    it "needs the first-launch setup" do
      xcode = results("-version" => version, "-checkFirstLaunchStatus" => ["", false])
      expect(xcode.fix).to eq("run `sudo xcodebuild -runFirstLaunch`")
    end

    it "needs the iOS SDK" do
      xcode = results("-version" => version, "-checkFirstLaunchStatus" => ["", true],
                      "--sdk" => ["xcrun: error: SDK \"iphonesimulator\" cannot be located", false])
      expect(xcode).to have_attributes(problem: "it has no iOS SDK", fix: "install the iOS platform: `xcodebuild -downloadPlatform iOS`")
    end

    it "is ready with all of them" do
      xcode = results("-version" => version, "-checkFirstLaunchStatus" => ["", true], "--sdk" => ["27.0\n", true])
      expect(xcode).to be_ready
      expect(xcode.version).to eq("Xcode 27.0")
    end

    it "describes this machine with the problem and gives its fix" do
      allow(described_class).to receive(:mac?).and_return(true)
      allow(described_class).to receive(:capture) { |*command| { "-version" => version, "-checkFirstLaunchStatus" => license }.fetch(command[1]) }
      apple = Runeforge::Platform::Need.new(platform: "apple", reason: "it has a Podfile (CocoaPods)")
      verdict = described_class.verdict(build_env("sandbox" => { "mode" => "none" }), nil, apple)
      expect(verdict.environment.description).to eq("this machine (macOS, Xcode 27.0, but its license isn't accepted), no sandbox")
      expect(verdict.fix).to eq("accept the Xcode license: `sudo xcodebuild -license accept`")
    end
  end
end
