# frozen_string_literal: true

module Runeforge
  # Whether a project can be built where Runeforge would build it. Platform-specific apps need
  # their vendor's toolchain: Apple apps need macOS with Xcode, Android apps the Android SDK. The
  # sandbox is a Linux container with neither, so such a project needs `sandbox: none` on a
  # machine that has the toolchain. The planner checks this before spending any tokens, records
  # the verdict on the repo, and `runeforge status -d DIR` shows it.
  module Platform
    Need = Data.define(:platform, :reason)
    Environment = Data.define(:mode, :description, :apple, :android, :apple_fix)
    # What `xcodebuild` reports: a version once Xcode is installed; a problem and its fix until it
    # can build an iOS app (installed, selected, license accepted, first launch done, iOS SDK).
    Xcode = Data.define(:version, :problem, :fix) do
      def ready? = problem.nil?
    end
    XCODE_SECONDS = 60
    Verdict = Data.define(:status, :platform, :reason, :environment, :fix) do
      def incompatible? = status == "incompatible"
    end

    APPLE_TEXT = /\b(?:iOS|iPadOS|watchOS|tvOS|visionOS|iPhone|iPad|SwiftUI|UIKit|AppKit|SpriteKit|Xcode|App Store|macOS app)\b/
    ANDROID_TEXT = /\b(?:Android app|Android Studio|Jetpack Compose|Play Store)\b/
    LABELS = { "apple" => "an Apple-platform app (iOS/macOS)", "android" => "an Android app" }.freeze
    NEEDS = { "apple" => "macOS with Xcode", "android" => "the Android SDK" }.freeze

    module_function

    # What the project needs, from its files (a Proc that lists paths and one that reads a file)
    # and, unless only files should count, the request's text. Nil for portable projects.
    def detect(paths: [], read: ->(_path) {}, text: "", files_only: false)
      paths = paths.map(&:to_s)
      if (xcode = paths.find { |p| p.match?(%r{\.(?:xcodeproj|xcworkspace)(?:/|\z)}) })
        return Need.new(platform: "apple", reason: "#{xcode[%r{[^/]*\.xc(?:odeproj|workspace)}]} is an Xcode project")
      end
      if paths.include?("Package.swift") && read.call("Package.swift").to_s.match?(/\.(?:iOS|macOS|tvOS|watchOS|visionOS)\(/)
        return Need.new(platform: "apple", reason: "Package.swift targets Apple platforms")
      end
      return Need.new(platform: "apple", reason: "it has a Podfile (CocoaPods)") if paths.include?("Podfile")
      if (manifest = paths.find { |p| p.end_with?("AndroidManifest.xml") })
        return Need.new(platform: "android", reason: "#{manifest} is an Android manifest")
      end
      return nil if files_only

      if (word = text.to_s[APPLE_TEXT])
        Need.new(platform: "apple", reason: "the request mentions #{word}")
      elsif (word = text.to_s[ANDROID_TEXT])
        Need.new(platform: "android", reason: "the request mentions #{word}")
      end
    end

    # Files under a directory, relative, skipping dependency folders.
    def scan_dir(dir)
      return [[], ->(_path) {}] unless dir && File.directory?(dir)

      paths = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject do |path|
        path.split("/").any? { |part| %w[. .. .git node_modules Pods build DerivedData .runeforge].include?(part) }
      end.first(5000)
      read = ->(path) { File.file?(File.join(dir, path)) ? File.read(File.join(dir, path), 100_000) : nil }
      [paths, read]
    end

    # Language versions a project pins, by tool: { "ruby" => "3.4.7", "node" => "20" }.
    def pinned_runtimes(dir)
      read = ->(file) { File.file?(File.join(dir, file)) ? File.read(File.join(dir, file), 10_000) : nil }
      pins = {}
      read.(".tool-versions")&.each_line do |line|
        tool, version = line.split
        pins[tool == "nodejs" ? "node" : tool] = version if %w[ruby nodejs node].include?(tool) && version
      end
      pins["ruby"] = read.(".ruby-version").strip.delete_prefix("ruby-") if read.(".ruby-version")
      node = (read.(".nvmrc") || read.(".node-version"))&.strip&.delete_prefix("v")
      pins["node"] = node if node
      pins.select { |_tool, version| version.match?(/\A\d+(?:\.\d+)*\z/) }
    end

    RUNTIME_PROBE = %(ruby -e 'print RUBY_VERSION' 2>/dev/null; echo; node -p 'process.versions.node' 2>/dev/null; echo)

    # Why the project's pinned language versions (see .pinned_runtimes) aren't what its sandbox
    # image has, or nil. Checked before any tokens are spent; an image's versions are asked once.
    def runtime_mismatch(env, project, dir)
      return nil unless %w[docker podman].include?(env.sandbox_mode(project))

      pins = pinned_runtimes(dir)
      return nil if pins.empty?

      image = project[:image] || env.config.dig("sandbox", "image")
      @runtimes ||= {}
      found = @runtimes[image] ||= Dir.mktmpdir("runeforge-runtimes") do |tmp|
        run = env.new_sandbox(image:, project:, services: false).run(workdir: tmp, script: RUNTIME_PROBE)
        # A container that didn't start says nothing about the image; the planner's run will say why.
        return nil unless run.success?

        ruby, node = run.stdout.lines(chomp: true)
        { "ruby" => ruby.to_s.strip, "node" => node.to_s.strip }
      end
      wrong = version_mismatches(pins, found)
      return nil if wrong.empty?

      "the project pins #{wrong.join(' and ')}, which the sandbox image #{image} doesn't match"
    end

    # "ruby 3.4.7 (it has ruby 3.3.12)" for each pinned version `found` ({ "ruby" => "3.3.12" })
    # doesn't match. A pin matches every version that starts with it: "3.4" matches 3.4.7.
    def version_mismatches(pins, found)
      pins.filter_map do |tool, version|
        have = found[tool].to_s
        next if have.split(".").first(version.split(".").size) == version.split(".")

        "#{tool} #{version} (it has #{have.empty? ? "no #{tool}" : "#{tool} #{have}"})"
      end
    end

    # Where a project's agents and tests run, and which toolchains are there.
    def environment(env, project = nil)
      mode = env.sandbox_mode(project)
      unless mode == "none"
        image = project&.dig(:image) || env.config.dig("sandbox", "image")
        devcontainer = project&.dig(:devcontainer) && Devcontainer.describe(JSON.parse(project[:devcontainer]))
        return Environment.new(mode:, description: ["a Linux container (#{mode} sandbox, image #{image})", devcontainer].compact.join(". "),
                               apple: false, android: false, apple_fix: nil)
      end

      mac = mac?
      xcode = mac ? self.xcode : nil
      android = android_sdk?
      os = mac ? "macOS" : RUBY_PLATFORM[/linux|mingw|mswin|bsd/] || RUBY_PLATFORM
      apple_tools = if xcode&.ready?
                      window = apple_toolchain&.simulator_app
                      window ? "#{xcode.version} (simulator window: #{File.basename(window, '.app')})" : xcode.version
                    elsif xcode then [xcode.version, xcode.problem].compact.join(", but ")
                    end
      tools = [apple_tools, (android ? "the Android SDK" : nil)].compact
      Environment.new(mode:, description: "this machine (#{os}#{tools.any? ? ", #{tools.join(', ')}" : ''}), no sandbox",
                      apple: xcode&.ready? == true, android:, apple_fix: xcode&.fix)
    end

    def verdict(env, project, need)
      environment = environment(env, project)
      return Verdict.new(status: "compatible", platform: nil, reason: "a portable project", environment:, fix: nil) unless need

      ok = need.platform == "apple" ? environment.apple : environment.android
      label = LABELS.fetch(need.platform)
      if ok
        return Verdict.new(status: "compatible", platform: need.platform,
                           reason: "#{label} (#{need.reason}), built on #{environment.description}", environment:, fix: nil)
      end

      Verdict.new(status: "incompatible", platform: need.platform,
                  reason: "#{label} (#{need.reason}) needs #{NEEDS.fetch(need.platform)}, but it would be built on #{environment.description}",
                  environment:, fix: fix_for(need, environment, project))
    end

    def fix_for(need, environment, project)
      where = project && project[:url] ? project[:url] : "<the project's directory>"
      tool = NEEDS.fetch(need.platform)
      if environment.mode == "none" && need.platform == "apple"
        environment.apple_fix || "build it on a Mac with Xcode (this machine isn't one)"
      elsif environment.mode == "none"
        "install #{tool} on this machine (and set ANDROID_HOME)"
      else
        "build it on a machine with #{tool}: set `sandbox: none` for it in #{Config.locate} " \
          "(projects: { #{where}: { sandbox: none } })"
      end
    end

    def mac? = RUBY_PLATFORM.include?("darwin")

    # Checked again after XCODE_SECONDS, so a running worker notices the license being accepted.
    def xcode
      @xcode = nil if @xcode_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @xcode_at > XCODE_SECONDS
      @xcode ||= check_xcode.tap { @xcode_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    def check_xcode
      out, ok = capture("xcodebuild", "-version")
      unless ok
        return Xcode.new(version: nil, problem: "no Xcode (Command Line Tools only)",
                         fix: "install the full Xcode app, then `sudo xcode-select -s /Applications/Xcode.app`")
      end

      version = out[/^Xcode .+$/].to_s.strip
      version = "Xcode" if version.empty?
      out, ok = capture("xcodebuild", "-checkFirstLaunchStatus")
      unless ok
        return Xcode.new(version:, problem: "its license isn't accepted", fix: "accept the Xcode license: `sudo xcodebuild -license accept`") if out.include?("license")

        return Xcode.new(version:, problem: "its first-launch setup hasn't run", fix: "run `sudo xcodebuild -runFirstLaunch`")
      end
      _out, ok = capture("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")
      return Xcode.new(version:, problem: "it has no iOS SDK", fix: "install the iOS platform: `xcodebuild -downloadPlatform iOS`") unless ok

      Xcode.new(version:, problem: nil, fix: nil)
    end

    # The Apple toolchain on this machine as agents need it: which window shows simulators (Xcode 27
    # replaced Simulator.app with DeviceHub.app, so `open -a Simulator` fails there), which
    # simulators exist (so -destination names are real) and which project tools are installed.
    # simulator_app is nil when neither app is found; runtimes maps an iOS version to device
    # names, newest first.
    AppleToolchain = Data.define(:xcode_version, :developer_dir, :simulator_app, :runtimes, :tools)
    SIMULATOR_APPS = [["Applications/Simulator.app", "com.apple.iphonesimulator"],
                      ["../Applications/DeviceHub.app", "com.apple.dt.Devices"]].freeze
    APPLE_TOOLS = %w[xcodegen tuist pod fastlane].freeze

    # Nil off a Mac or without a ready Xcode. Cached like #xcode.
    def apple_toolchain
      return nil unless mac? && xcode.ready?

      @apple_toolchain = nil if @apple_toolchain_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @apple_toolchain_at > XCODE_SECONDS
      @apple_toolchain ||= detect_apple_toolchain.tap { @apple_toolchain_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    def detect_apple_toolchain(developer_dir: nil)
      dev = developer_dir || capture("xcode-select", "-p").then { |out, ok| ok ? out.strip : nil }
      AppleToolchain.new(xcode_version: xcode.version, developer_dir: dev, simulator_app: simulator_app(dev),
                         runtimes: simulator_runtimes, tools: APPLE_TOOLS.select { |tool| on_path?(tool) })
    end

    def simulator_app(dev)
      found = dev && SIMULATOR_APPS.map { |path, _| File.expand_path(path, dev) }.find { |path| File.directory?(path) }
      found || SIMULATOR_APPS.lazy.filter_map do |_, bundle_id|
        out, ok = capture("mdfind", "kMDItemCFBundleIdentifier == '#{bundle_id}'")
        ok ? out.lines.map(&:strip).find { |path| File.directory?(path) } : nil
      end.first
    end

    def simulator_runtimes
      out, ok = capture("xcrun", "simctl", "list", "devices", "available", "-j")
      return {} unless ok

      JSON.parse(out).fetch("devices", {}).filter_map do |runtime, devices|
        version = runtime[/SimRuntime\.iOS-([\d-]+)\z/, 1]&.tr("-", ".")
        names = Array(devices).map { |d| d["name"] }.compact
        [version, names] if version && names.any?
      end.sort_by { |version, _| Gem::Version.new(version) }.reverse.to_h
    rescue JSON::ParserError
      {}
    end

    def on_path?(tool)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, tool)) }
    end

    def capture(*command)
      out, status = Open3.capture2e(*command)
      [out, status.success?]
    rescue SystemCallError => e
      [e.message, false]
    end

    def android_sdk?
      [ENV.fetch("ANDROID_HOME", nil), ENV.fetch("ANDROID_SDK_ROOT", nil)].compact.any? { |dir| File.directory?(dir) }
    end
  end
end
