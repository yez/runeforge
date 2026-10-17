# frozen_string_literal: true

module Runeforge
  module Prompts
    module_function

    # run_command: how the project already runs, once Runeforge has recorded it. Until then the
    # planner gets the full "How it runs" conventions; afterwards one line, to keep the prompt short.
    # pitfalls: lessons from earlier steps of this project that went wrong (see Memory).
    # setup_command: the project's setup command, which Runeforge ran before the agent started;
    # setup_fixed: a person set it, so a plan can't replace it.
    # stack: the project's stacks (see .stacks); empty for a new or unrecognised project, which
    # gets the guidance for every stack. ui_hint: whether the step's text names a screen (see
    # .ui_hint?); a step that names none gets one line about ui.md instead of the whole brief.
    # brief: the ledger's brief for this step (see Brief), or nil.
    def plan(task:, input:, test_globs:, test_command:, locked_paths: [], environment: nil, feedback: nil, apple: nil,
             run_command: nil, pitfalls: [], setup_command: nil, setup_fixed: false, ux_review: "auto", stack: [],
             ui_hint: true, brief: nil)
      setup_command = setup_command.to_s.strip
      stack = Array(stack)
      sections = ["You are the planning agent for task #{task[:id]}."]
      if environment
        sections << "## Environment\nYou, the coder and the tests all run on #{environment}. Plan only what can be " \
                    "built and tested here; if the request needs a platform toolchain this environment lacks, " \
                    "write that to `.runeforge/blocked.md` (see below) instead of planning around it.\n#{working_section}"
      end
      sections << setup_section(setup_command) unless setup_command.empty?
      sections << apple_section(apple) if apple
      if input["context"]
        sections << "## The whole request (you are doing step #{input['step']})\n#{input['context']}"
        sections << this_step(input)
      else
        sections << "## The request\n#{[input['title'] || task[:title], input['description']].compact.join("\n\n")}"
      end
      if Array(input["queued"]).any?
        sections << "## Plans queued after this one\nOther agents will build these later. Don't build any of them now, even if it seems natural; stay within this request.\n" +
                    input["queued"].map { |title| "- #{title}" }.join("\n")
      end
      sections << brief.strip if brief && !brief.strip.empty?
      if locked_paths.any?
        sections << "## Existing acceptance tests\nThese are locked from earlier steps. Keep them passing; change them only if this step truly requires it.\n" +
                    locked_paths.map { |path| "- #{path}" }.join("\n")
      end
      if pitfalls.any?
        sections << "## Known pitfalls in this project\nEarlier steps here went wrong like this; don't repeat these mistakes:\n" +
                    pitfalls.map { |lesson| "- #{lesson[:step] ? "(#{lesson[:step]}) " : ''}#{lesson[:text].gsub(/\s+/, ' ')}" }.join("\n")
      end
      unless feedback.to_s.strip.empty?
        sections << "## Your previous plan was rejected\nRuneforge rejected your last plan for this step (it was discarded; " \
                    "start again from the repository as it is). Fix this specifically:\n#{feedback}"
      end
      sections << <<~JOB
        ## Your job
        1. Read what is in the repository (it may be empty) and decide how this step fits in.#{brief ? " Start from the files the brief names." : ""}
        2. Write a short implementation spec to `.runeforge/spec.md`, at most about 25 lines: the files to change,
           the decisions the coder needs, and the assertions you checked against existing code. Don't restate the request.
        3. Write acceptance tests that fail now and will pass once this step is built. Test files must match
           one of: #{test_globs.join(', ')}
        4. If the project has no way to run tests yet, add the minimum scaffolding for that (for example a
           package.json, pyproject.toml or Gemfile, plus test configuration).
        5. Write `.runeforge/project.json` describing how to run the tests:
           {"test_command": "...", "setup_command": "...", "run_command": "...", "run_command_new": false, "tools": ["..."]}
           - test_command runs the whole suite and exits non-zero on failure. Call the test runner directly
             (e.g. `python -m pytest`, `npx vitest run`, `bundle exec rspec`), not a script the coder could edit.#{"\n             This project already runs its tests with `#{test_command}`; that stays in use, so you can leave test_command out." unless test_command.to_s.strip.empty?}
           - setup_command installs dependencies and prepares what the tests need (e.g. `npm install`,
             `bin/rails db:prepare`), or leave it out. It runs in the same shell before test_command, so its
             exports apply. Keep each command to one line (at most 1000 characters, no nested quoting); put
             anything longer in a script you commit with this plan (e.g. `script/runeforge_setup.sh`) and run that.
             Commands you write here replace those an earlier plan wrote.#{"\n             This project's setup command is set for it in Runeforge (`#{setup_command}`) and stays in use, so leave setup_command out;\n             if this step needs more set up, add it to the script that command runs." if setup_fixed && !setup_command.empty?}
           - run_command is the one command that runs the project, and run_command_new says whether
             you defined it (see "How it runs" below). Leave both out for a library with nothing to run.
           - tools lists the command-line programs the tests need (e.g. ["node", "npm"]).

        #{how_it_runs(run_command)}

        ## How many tests
        - One test (`it`, `test`, `def test_`) per rule the step states. Check that rule's cases
          together in it; don't write a separate test for every input of the same rule.
        - Test only what this step adds or changes. Behaviour the locked tests already pin stays covered by them.
        - Use the project's shared test helpers (setup, fixtures, factories, request helpers), and put new
          shared setup there instead of defining it again in each test file.

        ## Tests that can pass
        - Acceptance tests exercise the project's own code, in its own language and test framework
          (#{framework_examples(stack)}). Never substitute tests in another
          language, or tests that only check that files or words exist.
        - If this environment can't build or test the stack (its toolchain isn't here, e.g. an
          iOS or macOS app needs Xcode on a Mac), don't work around it: write the reason and what
          the project needs to `.runeforge/blocked.md`, change nothing else, and stop.
        - Run only your new test files, not the whole suite: most runners take file paths
          or a filter (#{run_examples(stack)}). The new tests must be found and run, and fail because the feature is
          missing (their assertions, or imports of code that doesn't exist yet), not because the
          runner can't find or load them. The output must name your test cases:
          a runner crash reported as a single failing test (for example one "test" named after a
          directory, or `Cannot find module`) means the command is wrong. Once you finish, Runeforge runs
          test_command on your plan and sends it back if the tests don't build or run, so don't
          run the whole suite to check the locked tests: you aren't changing the code they test.
        #{compiled_section(stack)}- Where an assertion depends on behaviour that already exists (and that the locked tests pin
          down), check it by hand against the current code: follow the inputs through each call and
          check that the expected value is what that code produces, and list those assertions in the
          spec. Another agent can't change your tests, so one assertion that contradicts a locked test
          fails the whole step. Assertions about behaviour this step adds don't need that walk-through.
        - Every assertion must be able to fail. Don't compare a value with itself or with an
          expression that always evaluates to it.
        - If this step deliberately changes behaviour that a locked test from an earlier step asserts
          (a field that is removed, a label or rule that changes), update that test in this plan, to
          what the step now requires. You are the only one who can: the coder can't change locked tests,
          and one that still asserts the old behaviour makes the step impossible or leaves a stale rule
          behind.
        #{node_section(stack)}- `.runeforge/` is Runeforge's scratch space and is never committed. Tests and code must
          not read or write anything there (spec.md and project.json are for Runeforge only).

        #{ui_hint == false && ux_review == "auto" ? short_ui_section : ui_section(ux_review)}
        ## When the step is already built
        If the repository already does everything this step asks (an earlier step built it along
        with its own), don't invent work or tests that can't fail. Write `.runeforge/already_done.md`
        instead: for each requirement of the step, where the code does it and which test covers it.
        You may add tests for requirements no existing test covers; they must pass now. Change
        nothing else. Runeforge runs test_command, and if it passes the step is done without coding.

        ## Rules
        - Do not implement the step itself (compile-only stubs are fine). Another agent will, and it cannot change your test files.
        - Do not change anything under `runeforge/` (the project's plan inbox); such changes are rejected.
        - Do not commit. Leave your changes in the working tree.
        - When you finish, end with at most three lines: what you planned and anything the coder must know.
          The spec and the tests carry the rest.

        #{handoff_section(:planner)}
      JOB
      sections.join("\n\n")
    end

    # "## This step": the step's text, or only its title when that text is already in the whole
    # request shown above it (an inbox plan's item), so the prompt doesn't carry it twice.
    def this_step(input)
      body = input["description"].to_s
      squeeze = ->(text) { text.to_s.gsub(/\s+/, " ").strip }
      if !body.strip.empty? && squeeze.call(input["context"]).include?(squeeze.call(body))
        "## This step\n#{input['title']}\nIt is that item in the request above (#{input['step']}); build only that item."
      else
        "## This step\n#{[input['title'], input['description']].compact.join("\n\n")}"
      end
    end

    # What a project is built with, from its file names (Platform.scan_dir's paths): node, ruby,
    # python, go, rust, jvm, dotnet, swift. Empty for a new project or one it doesn't recognise.
    STACK_FILES = {
      "node" => /\A(?:.*\/)?package\.json\z/, "ruby" => /\A(?:.*\/)?(?:Gemfile|.*\.gemspec)\z/,
      "python" => /\A(?:.*\/)?(?:pyproject\.toml|requirements.*\.txt|setup\.py|Pipfile)\z/,
      "go" => /\A(?:.*\/)?go\.mod\z/, "rust" => /\A(?:.*\/)?Cargo\.toml\z/,
      "jvm" => /\A(?:.*\/)?(?:build\.gradle(?:\.kts)?|pom\.xml)\z/, "dotnet" => /\.(?:csproj|sln)\z/,
      "swift" => /\A(?:.*\/)?Package\.swift\z|\.xcodeproj(?:\/|\z)/
    }.freeze
    COMPILED = %w[go rust jvm dotnet swift].freeze

    def stacks(paths) = STACK_FILES.select { |_stack, pattern| paths.any? { |path| path.match?(pattern) } }.keys

    FRAMEWORKS = {
      "swift" => "Swift: XCTest with `swift test`/`xcodebuild test`", "jvm" => "Kotlin or Java: JUnit with Gradle or Maven",
      "python" => "Python: pytest", "node" => "JavaScript: node --test, vitest or jest", "ruby" => "Ruby: rspec or minitest",
      "go" => "Go: `go test`", "rust" => "Rust: `cargo test`", "dotnet" => "C#: `dotnet test`"
    }.freeze
    RUNS = {
      "node" => "`npx vitest run test/foo.test.js`, `node --test test/foo.test.js`", "python" => "`python -m pytest tests/test_foo.py`",
      "ruby" => "`bundle exec rspec spec/foo_spec.rb`", "swift" => "`swift test --filter`", "rust" => "`cargo test foo`",
      "go" => "`go test -run Foo`", "jvm" => "`./gradlew test --tests Foo`", "dotnet" => "`dotnet test --filter Foo`"
    }.freeze

    def framework_examples(stack) = (stack.empty? ? FRAMEWORKS.values_at("swift", "jvm", "python", "node") : FRAMEWORKS.values_at(*stack)).compact.join("; ")

    def run_examples(stack)
      (stack.empty? ? RUNS.values_at("node", "python", "ruby", "swift", "rust", "go") : RUNS.values_at(*stack)).compact.join(", ")
    end

    def compiled_section(stack)
      return "" unless stack.empty? || stack.intersect?(COMPILED)

      <<~TEXT
        - Compiled stacks (Swift, Rust, Kotlin/Java, Go, C#) build the whole test target first, so one
          missing type stops every test and hides every assertion. There, add the smallest stubs of the
          new types and functions to the source so the suite builds: placeholder bodies that return
          empty or default values, never ones that crash or trap (`fatalError`, `panic!`, `TODO()`).
          Then the locked tests must pass and each new test must fail on its own assertion. Runeforge
          rejects a plan whose tests don't compile.
      TEXT
    end

    def node_section(stack)
      return "" unless stack.empty? || stack.include?("node")

      <<~TEXT
        - Node: `node --test` with no arguments finds test/**/*.test.js (and .mjs, .cjs); or list the
          files, `node --test test/*.test.js`. Never `node --test <directory>`: Node 22 loads the
          directory as a module and runs nothing.
      TEXT
    end

    # Words that say a step changes a screen. A step naming none gets #short_ui_section.
    UI_WORDS = /\bUI\b|\bscreens?\b|\bpages?\b|\bbuttons?\b|\bforms?\b|\bcomponents?\b|data-testid|\bbrowser\b|\bclicks?\b|
                \blayout\b|\bviews?\b|\bnavigation\b|\bmodal\b|\bdialog\b|\bstyles?\b|\bCSS\b|\bemails?\b/xi

    def ui_hint?(input) = [input["title"], input["description"]].compact.join("\n").match?(UI_WORDS)

    # The handoff the planner and coder leave for the agents after them (see Handoff). Runeforge
    # checks every path, symbol and test name in it against the commit before keeping any of it.
    def handoff_section(role)
      own = if role == :planner
              <<~JSON.chomp
                {"requirements": [{"id": "the requirement's id from the brief, else a short name",
                                   "status": "new" | "already_built" | "conflict",
                                   "tests": ["test/file.test.js > the test's name"],
                                   "code": [{"path": "server/x.js", "symbol": "createBooking", "note": "what it does, or what to build there"}],
                                   "cites": ["README.md:65", "test/other.test.js > a test this step contradicts"]}],
              JSON
            else
              <<~JSON.chomp
                {"implemented": [{"id": "the requirement's id", "code": [{"path": "server/x.js", "symbol": "createBooking", "note": "what it does"}]}],
              JSON
            end
      <<~TEXT
        ## Handoff
        Write `.runeforge/handoff.json` for the agents who build the next steps. Runeforge checks every path,
        symbol and test name against the repository and keeps only what it finds; keep each note to one line.
        #{own}
         "facts": [{"key": "short-name", "kind": "convention" | "command" | "layout" | "gotcha",
                    "text": "one or two sentences", "paths": ["test/helpers.js"]}],
         "discovered": [{"title": "work outside this step that someone should do", "why": "...",
                         "evidence": "path:line, or a command and what it printed"}]}
        #{role == :planner ? handoff_conflict : ''}
      TEXT
    end

    def handoff_conflict
      <<~TEXT.chomp
        If the step contradicts behaviour this project documents or tests (not a missing toolchain: that's
        blocked.md), mark its requirements "conflict", cite the README lines and tests it contradicts, and
        change nothing else: Runeforge stops the step for a person to decide.
      TEXT
    end

    def short_ui_section
      "## User interface changes\nThis step names no screen. If it does change what a person sees or does, write " \
        "`.runeforge/ui.md` naming each screen, how to reach it and what to check there, for a UX reviewer who opens it in a browser.\n"
    end

    # The planner's instructions for steps that change what people see or do: a UI brief for the
    # UX reviewer, which opens those screens in a real browser before merging, and a browser test
    # for each user-facing path. Specs that only check pieces passed while the feature they made
    # up never reached the browser (a job's broadcast with no page subscribed to it).
    def ui_section(mode)
      return "" if mode == "never"

      decide = if mode == "always"
                 "The plan asks for a UX review of this step, so write `.runeforge/ui.md` even if the change looks small."
               else
                 "Decide whether this step changes what a person sees or does in the product (pages, forms, " \
                   "components, copy, flows, emails people read). If it does, write `.runeforge/ui.md`; if it " \
                   "doesn't (a model, a job, an API with no screen), don't write it."
               end
      <<~SECTION
        ## User interface changes
        #{decide} A UX reviewer opens the screens it names in a real browser, at desktop and phone
        widths, before the step is merged, and sends what falls short back to the coder.
        `.runeforge/ui.md` is the reviewer's brief, in markdown:
        - **Screens**: each screen or component this step adds or changes, the URL or route, and how to
          reach it (sign in as which kind of user, which records must exist, which clicks).
        - **What it must look like and do**: in each state that applies (empty, filled, validation
          error, loading, results arriving asynchronously, after a reload, at the limit), what the
          person should see. Write the request's UI requirements here as checks.
        - **Match**: the existing screens, partials and components it must look like (name the files),
          so it reads as part of the same product: the same form controls, buttons, spacing and
          progress elements, reused rather than restyled.
        - **Widths**: desktop (1280px) and phone (390px), unless the request says otherwise.
        For a step with UI changes, include a browser test (a system or end-to-end test in the project's
        own framework) that walks each user-facing path the step adds, the way a person would: through
        the page, waiting for asynchronous results to appear, not only checking the pieces separately.
        A job that broadcasts a result is only done when the page shows it.
      SECTION
    end

    # The UX reviewer's prompt (Roles::UxReviewer). browser: the project's browser services and the
    # app container's name on their network; changed: the files this step changed.
    def ux_review(task:, brief:, browser:, changed:, run_command: nil, setup_command: nil, earlier: nil)
      prompt = <<~PROMPT
        You are the UX reviewer for task #{task[:id]}: #{task[:title]}.
        The step's code is in this workspace. Its tests pass and its code has been reviewed; your job is
        to use it the way a person would, in a real browser, and judge whether it's good enough to ship.
        You don't change the product: anything you change outside `.runeforge/` is thrown away. Put
        every file you make (scripts, screenshots, notes) under `.runeforge/`.

        ## The UI brief (from the planner)
        #{brief.strip}

        ## The spec
        #{task[:spec].to_s.strip.empty? ? task[:title] : task[:spec].to_s.strip}

        ## Files this step changed
        #{changed.map { |path| "- #{path}" }.join("\n")}

        #{ux_browser_section(browser, run_command, setup_command)}

        ## What to do
        1. Start the app (or use the project's browser-test setup, which starts it for you) with the
           data each screen needs: create the records and the signed-in user through the project's own
           factories, seeds or models.
        2. Open every screen in the brief at desktop (1280px wide) and phone (390px) widths, and go
           through its states: empty, filled, validation errors, loading, results that arrive
           asynchronously (wait for them; a result that never shows up in the page is a blocker), and
           after a reload. Use the controls the way a person would: type, click, submit.
        3. Screenshot each screen and state to `.runeforge/ux/<screen>-<state>-<width>.png`, then open
           the screenshots with your Read tool and look at them. Judge what you see, not the markup.
        4. Screenshot one or two existing screens the brief says to match, and compare.

        ## What to judge
        - Each check in the brief: does the screen do and show what it says?
        - It works: nothing broken, stuck, empty where content belongs, or requiring a reload.
        - It looks like part of this product: the same controls, buttons, spacing, type and progress
          elements as the existing screens, not one-off styles.
        - Layout at both widths: nothing overflowing, cut off or overlapping, sensible alignment, no
          large dead space, tap targets big enough on the phone.
        - Feedback: loading, success, empty and error states say what's happening; nothing is silent.
        - Copy and accessibility: clear labels, no placeholder or debugging text, visible focus,
          readable contrast.

        Severity:
        - blocker: doesn't work or can't be completed (an error, a result that never appears, a
          checklist item that can never be met).
        - major: works, but clearly below the existing screens or misses a check in the brief.
        - minor: polish worth doing that shouldn't hold up the merge.
        Blockers and majors send the step back to the coder; be specific enough that they can fix
        each one without seeing your screenshots.

        ## Your report
        Write `.runeforge/ux_review.json`:
        {"browser": "selenium" | "chrome" | "playwright" | "none",
         "summary": "two or three sentences on the overall experience",
         "issues": [{"severity": "blocker" | "major" | "minor", "screen": "which screen and state, at which width",
                     "problem": "what a person sees and why it's a problem", "fix": "what to change, naming files where you can"}]}
        An empty issues list means it's ready. Always write the report, even if you couldn't open a
        browser: then set "browser" to "none", review the rendered HTML and templates instead, and say so
        in the summary.
      PROMPT
      earlier.to_s.strip.empty? ? prompt : "#{prompt}\n#{earlier.strip}\n"
    end

    def ux_browser_section(browser, run_command, setup_command)
      lines = ["## The browser"]
      if browser[:services].any?
        names = browser[:services].map { |service| "`#{service[:name]}` (#{service[:image]})" }.join(", ")
        lines << "A browser service runs next to this container: #{names}. A Selenium server listens on port 4444 " \
                 "of that host (`http://#{browser[:services].first[:name]}:4444`). It opens the app over the network, " \
                 "so start the app bound to 0.0.0.0 and point the browser at " \
                 "`http://#{browser[:app_host] || '$(hostname)'}:<port>`, not localhost."
      elsif browser[:sandboxed]
        lines << "No browser service runs next to this container. Look for a headless browser in the image " \
                 "(`command -v chromium chromium-browser google-chrome`, or Playwright's) and use it if there is one."
      else
        lines << "You run on the developer's machine: use a headless browser installed here (Chrome, Chromium, " \
                 "or Playwright's), and start the app on a free port on localhost."
      end
      lines << "Variables set for the browser: #{browser[:env].map { |name, value| "#{name}=#{value}" }.join(', ')}." if browser[:env].any?
      lines << "The project's setup command (`#{setup_command}`) already ran in this workspace." unless setup_command.to_s.strip.empty?
      lines << "The project runs with `#{run_command}`." unless run_command.to_s.strip.empty?
      lines << "If the project has browser tests (Capybara system specs, Playwright), the simplest way in is a throwaway " \
               "script or spec under `.runeforge/ux/` that reuses that setup: it already knows how to start the app and " \
               "reach the browser. Resize the window for each width and save a screenshot of each state."
      lines.join("\n")
    end

    # The "How it runs" section of the planner's prompt (see #plan).
    def how_it_runs(run_command)
      unless run_command.to_s.strip.empty?
        return "## How it runs\nThe project runs with `#{run_command}`. Keep that working; leave run_command and " \
               "run_command_new out of project.json."
      end

      <<~RUNS.chomp
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
      RUNS
    end

    # continuing: the coder carries on the conversation the planner (or its previous attempt) had,
    # so it already knows the project and the spec, and the prompt says what changed instead.
    def code(task:, attempt:, locked_paths:, test_command:, feedback: nil, run_command: nil, run_docs_required: false, apple: nil,
             continuing: false, setup_command: nil, ui_brief: nil, brief: nil)
      sections = [<<~PROMPT]
        #{continuing ? continuing_note(task, attempt) : coder_intro(task, attempt)}

        ## Acceptance tests (locked)
        These files define "done". You may read them but must not change them; a patch that
        changes them is rejected automatically.
        #{locked_paths.map { |path| "- #{path}" }.join("\n")}

        ## Your job
        Change the code so the acceptance tests and the rest of the suite pass.
        Run the tests with: `#{test_command}`#{run_section(run_command, docs_required: run_docs_required)}
        If a locked test can't pass as written (it contradicts the spec, another locked test, or
        itself), don't work around it and don't spend the attempt: write why, naming the test and
        the assertion, to `.runeforge/contest.md` and stop. The step then goes back to the planner.
        Do not change anything under `runeforge/` (the project's plan inbox); such changes are rejected.
        Do not put anything else in `.runeforge/`: it's Runeforge's scratch space and is never committed.
        Do not commit. Leave your changes in the working tree.
        When you finish, end with at most three lines: what you changed and anything a reviewer must know.

        #{handoff_section(:coder)}
        #{working_section}
      PROMPT
      sections << "#{setup_section(setup_command)}\n" unless setup_command.to_s.strip.empty?
      sections << "#{brief.strip}\n" unless brief.to_s.strip.empty?
      sections << "#{coder_ui_section(ui_brief)}\n" unless ui_brief.to_s.strip.empty?
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

    # Claude Code moves a command that runs past its timeout to the background, and an agent that
    # then polls for it in a loop, or starts the suite again beside it, lost 20 minutes of a step.
    def working_section
      "Run commands, the test suite included, in the foreground and wait for them to finish, even " \
        "if that takes minutes. Don't start background jobs or poll loops, and don't run two test runs at " \
        "once: they share one test database."
    end

    # For a step that changes the UI: what the UX reviewer will check in a browser, and the bar.
    def coder_ui_section(brief)
      <<~SECTION.chomp
        ## User interface
        This step changes the UI. Before it's merged, a UX reviewer opens these screens in a real browser at
        desktop and phone widths and sends back what falls short. Its brief:

        #{brief.strip}

        Build it to that bar, not just to pass the tests:
        - Reuse the app's existing partials, components, form controls, buttons and progress elements; find
          them before writing markup, and don't copy long class lists from screen to screen.
        - Make every state work in the browser: empty, filled, errors, loading, and asynchronous results
          that must reach the page (a broadcast needs a page subscribed to it). New items get the same
          controls as saved ones without a reload.
        - Check the layout at both widths, including what the page looks like with little content.
      SECTION
    end

    def setup_section(setup_command)
      <<~SECTION.chomp
        ## Setup
        Runeforge ran the project's setup command, `#{setup_command}`, in this workspace before you started
        (its output is in .runeforge/setup.out), and runs it before every test run. Run it again yourself
        after changing what it prepares (a migration, assets, dependencies) and before running the tests.
      SECTION
    end

    def coder_intro(task, attempt)
      "You are the coding agent for task #{task[:id]}, attempt #{attempt} of #{task[:max_attempts]}.\n\n" \
        "## Spec\n#{task[:spec].to_s.strip.empty? ? task[:title] : task[:spec]}"
    end

    def continuing_note(task, attempt)
      what = if attempt.to_i <= 1
               "Planning is done: Runeforge committed your spec and acceptance tests, and the working directory now " \
                 "holds that commit (your .runeforge/ notes are gone). You are now the coding agent for this step"
             else
               "Runeforge checked your last attempt and it didn't pass (feedback below). The working directory now holds " \
                 "your latest committed work; anything from a failed attempt that wasn't committed is gone"
             end
      "#{what}: attempt #{attempt} of #{task[:max_attempts]} for task #{task[:id]}. Keep to the spec you planned."
    end

    def run_section(run_command, docs_required: false)
      return "" if run_command.to_s.strip.empty?
      return "\nThe project runs with `#{run_command}`; keep that working." unless docs_required

      "\nThe project runs with `#{run_command}`. README.md must have a How to run section with the install\n" \
        "step and that exact command; the reviewer rejects the work otherwise. Make the command work."
    end
  end
end
