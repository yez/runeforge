# frozen_string_literal: true

module Runeforge
  module Prompts
    module_function

    def plan(task:, input:, test_globs:, test_command:, locked_paths: [], environment: nil, feedback: nil, apple: nil)
      sections = ["You are the planning agent for task #{task[:id]}."]
      if environment
        sections << "## Environment\nYou, the coder and the tests all run on #{environment}. Plan only what can be " \
                    "built and tested here; if the request needs a platform toolchain this environment lacks, " \
                    "write that to `.runeforge/blocked.md` (see below) instead of planning around it."
      end
      sections << apple_section(apple) if apple
      if input["context"]
        sections << "## The whole request (you are doing step #{input['step']})\n#{input['context']}"
        sections << "## This step\n#{[input['title'], input['description']].compact.join("\n\n")}"
      else
        sections << "## The request\n#{[input['title'] || task[:title], input['description']].compact.join("\n\n")}"
      end
      if Array(input["queued"]).any?
        sections << "## Plans queued after this one\nOther agents will build these later. Don't build any of them now, even if it seems natural; stay within this request.\n" +
                    input["queued"].map { |title| "- #{title}" }.join("\n")
      end
      if locked_paths.any?
        sections << "## Existing acceptance tests\nThese are locked from earlier steps. Keep them passing; change them only if this step truly requires it.\n" +
                    locked_paths.map { |path| "- #{path}" }.join("\n")
      end
      unless feedback.to_s.strip.empty?
        sections << "## Your previous plan was rejected\nRuneforge rejected your last plan for this step (it was discarded; " \
                    "start again from the repository as it is). Fix this specifically:\n#{feedback}"
      end
      sections << <<~JOB
        ## Your job
        1. Read what is in the repository (it may be empty) and decide how this step fits in.
        2. Write a short implementation spec to `.runeforge/spec.md`: what changes, where, and how it is verified.
        3. Write acceptance tests that fail now and will pass once this step is built. Test files must match
           one of: #{test_globs.join(', ')}
        4. If the project has no way to run tests yet, add the minimum scaffolding for that (for example a
           package.json, pyproject.toml or Gemfile, plus test configuration).
        5. Write `.runeforge/project.json` describing how to run the tests:
           {"test_command": "...", "setup_command": "...", "run_command": "...", "run_command_new": false, "tools": ["..."]}
           - test_command runs the whole suite and exits non-zero on failure. Call the test runner directly
             (e.g. `python -m pytest`, `npx vitest run`, `bundle exec rspec`), not a script the coder could edit.#{"\n             This project already runs its tests with `#{test_command}`; that stays in use, so you can leave test_command out." unless test_command.to_s.strip.empty?}
           - setup_command installs dependencies (e.g. `npm install`), or leave it out.
           - run_command is the one command that runs the project, and run_command_new says whether
             you defined it (see "How it runs" below). Leave both out for a library with nothing to run.
           - tools lists the command-line programs the tests need (e.g. ["node", "npm"]).

        ## How it runs
        Someone who has just cloned the project must be able to run it.
        1. First find how the project already runs: its README, package.json scripts, Makefile,
           Procfile*, bin/dev, justfile, Taskfile, compose.yaml. If it has a way, put that exact
           command in run_command with "run_command_new": false, and leave it alone: don't add,
           rename or repurpose scripts, and don't rewrite its instructions.
        2. Only if it has none (a new project, or nothing launches it yet), define one following
           the stack's convention, set "run_command_new": true, and make it a requirement in the
           spec: a README.md with a "How to run" section giving the install step, the run_command
           exactly, and where to look (URL and port, simulator, terminal). The reviewer rejects
           work whose README doesn't contain a run_command you defined.
        Conventions for a command you define:
        - With a package.json it runs through npm scripts and `npm start` must work, even for a
          static site ("start": "npx --yes serve ."). Frameworks keep their own scripts:
          Vite/Next/Nuxt/SvelteKit/Astro `npm run dev`, Angular `npm start`, Expo `npx expo start`.
        - Pages using <script type="module"> need a server; they don't load from file://.
        - Otherwise the stack's own command: Flask `flask --app app run`, FastAPI
          `uvicorn app.main:app --reload`, Django `python manage.py runserver`, Rails `bin/dev`,
          Go `go run .`, Rust `cargo run`, Spring Boot `./mvnw spring-boot:run`, .NET `dotnet run`,
          Laravel `php artisan serve`, Phoenix `mix phx.server`, Flutter `flutter run`, Android
          `./gradlew installDebug`. Servers read PORT with a documented default.
        - Keep it to one command where you can; put extra steps in setup_command and the README.

        ## Tests that can pass
        - Acceptance tests exercise the project's own code, in its own language and test framework
          (Swift: XCTest with `swift test`/`xcodebuild test`; Kotlin: JUnit with Gradle; Python:
          pytest; JavaScript: node --test, vitest or jest). Never substitute tests in another
          language, or tests that only check that files or words exist.
        - If this environment can't build or test the stack (its toolchain isn't here, e.g. an
          iOS or macOS app needs Xcode on a Mac), don't work around it: write the reason and what
          the project needs to `.runeforge/blocked.md`, change nothing else, and stop.
        - Run test_command once before you finish and read its output. The new tests must be found
          and run, and fail because the feature is missing (their assertions, or imports of code that
          doesn't exist yet), not because the command can't find or load them. The output must name
          your test cases: a runner crash reported as a single failing test (for example one "test"
          named after a directory, or `Cannot find module`) means the command is wrong.
        - Compiled stacks (Swift, Rust, Kotlin/Java, Go, C#) build the whole test target first, so one
          missing type stops every test and hides every assertion. There, add the smallest stubs of the
          new types and functions to the source so the suite builds: placeholder bodies that return
          empty or default values, never ones that crash or trap (`fatalError`, `panic!`, `TODO()`).
          Then the locked tests must pass and each new test must fail on its own assertion. Runeforge
          rejects a plan whose tests don't compile.
        - Work through every assertion that depends on behaviour that already exists (and that the
          locked tests pin down) by hand against the current code: follow the inputs through each
          call and check that the expected value is what that code produces. Another agent can't
          change your tests, so one assertion that contradicts a locked test fails the whole step.
        - Every assertion must be able to fail. Don't compare a value with itself or with an
          expression that always evaluates to it.
        - Node: `node --test` with no arguments finds test/**/*.test.js (and .mjs, .cjs); or list the
          files, `node --test test/*.test.js`. Never `node --test <directory>`: Node 22 loads the
          directory as a module and runs nothing.
        - `.runeforge/` is Runeforge's scratch space and is never committed. Tests and code must
          not read or write anything there (spec.md and project.json are for Runeforge only).

        ## Rules
        - Do not implement the step itself (compile-only stubs are fine). Another agent will, and it cannot change your test files.
        - Do not change anything under `runeforge/` (the project's plan inbox); such changes are rejected.
        - Do not commit. Leave your changes in the working tree.
      JOB
      sections.join("\n\n")
    end

    def code(task:, attempt:, locked_paths:, test_command:, feedback: nil, run_command: nil, run_docs_required: false, apple: nil)
      sections = [<<~PROMPT]
        You are the coding agent for task #{task[:id]}, attempt #{attempt} of #{task[:max_attempts]}.

        ## Spec
        #{task[:spec].to_s.strip.empty? ? task[:title] : task[:spec]}

        ## Acceptance tests (locked)
        These files define "done". You may read them but must not change them; a patch that
        changes them is rejected automatically.
        #{locked_paths.map { |path| "- #{path}" }.join("\n")}

        ## Your job
        Change the code so the acceptance tests and the rest of the suite pass.
        Run the tests with: `#{test_command}`#{run_section(run_command, docs_required: run_docs_required)}
        Do not change anything under `runeforge/` (the project's plan inbox); such changes are rejected.
        Do not put anything in `.runeforge/`: it's Runeforge's scratch space and is never committed.
        Do not commit. Leave your changes in the working tree.
      PROMPT
      sections << "#{apple_section(apple)}\n" if apple
      sections << "## Feedback from the previous attempt\n#{feedback}\n" if feedback && !feedback.to_s.strip.empty?
      sections.join("\n")
    end

    # What agents can't know from memory about this Mac's Apple toolchain (Platform::AppleToolchain).
    # Xcode 27 dropped Simulator.app for DeviceHub.app, and an agent writing `open -a Simulator`
    # from habit produced a run script that launched the app with no window.
    def apple_section(toolchain)
      window = toolchain.simulator_app
      simulators = toolchain.runtimes.first(2).map { |version, names| "  - iOS #{version}: #{names.first(8).join(', ')}" }
      tools = toolchain.tools.any? ? toolchain.tools.join(", ") : "none of #{Platform::APPLE_TOOLS.join(', ')}"
      <<~SECTION.chomp
        ## Apple toolchain on this machine
        - #{toolchain.xcode_version}, developer dir `#{toolchain.developer_dir}`.
        - #{window ? "Simulators are shown in `#{window}`." : 'No app to show simulators was found (neither Simulator.app nor DeviceHub.app).'}
          Xcode 27 has no Simulator.app (DeviceHub.app replaced it), so never hard-code `open -a Simulator`.
          A script that shows the simulator must find the app when it runs: `$(xcode-select -p)/Applications/Simulator.app`
          (Xcode 26 and earlier; only it takes `--args -CurrentDeviceUDID <udid>`), else
          `$(xcode-select -p)/../Applications/DeviceHub.app`, and exit non-zero if neither exists.
        - Simulators available here (use these exact names in `-destination`):
        #{simulators.any? ? simulators.join("\n") : '  - none: `xcrun simctl list devices available` is empty'}
        - Command-line tools installed: #{tools}. Don't depend on one that isn't installed.
        - Build warnings count. Fix Swift concurrency warnings: main-actor APIs (UIKit, including the haptic
          feedback generators, and SwiftUI state) must be used from `@MainActor` code, not nonisolated types.
        - A run script must fail (exit non-zero) when it can't build, install, launch or show the app, never warn and
          carry on. Runeforge runs the project's run command before merging and rejects work whose app doesn't
          launch and keep running.
      SECTION
    end

    def run_section(run_command, docs_required: false)
      return "" if run_command.to_s.strip.empty?
      return "\nThe project runs with `#{run_command}`; keep that working." unless docs_required

      "\nThe project runs with `#{run_command}`. README.md must have a How to run section with the install\n" \
        "step and that exact command; the reviewer rejects the work otherwise. Make the command work."
    end
  end
end
