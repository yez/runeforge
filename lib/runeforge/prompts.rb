# frozen_string_literal: true

module Runeforge
  module Prompts
    module_function

    def plan(task:, input:, test_globs:, test_command:, locked_paths: [])
      sections = ["You are the planning agent for task #{task[:id]}."]
      if input["context"]
        sections << "## The whole request (you are doing step #{input['step']})\n#{input['context']}"
        sections << "## This step\n#{[input['title'], input['description']].compact.join("\n\n")}"
      else
        sections << "## The request\n#{[input['title'] || task[:title], input['description']].compact.join("\n\n")}"
      end
      if locked_paths.any?
        sections << "## Existing acceptance tests\nThese are locked from earlier steps. Keep them passing; change them only if this step truly requires it.\n" +
                    locked_paths.map { |path| "- #{path}" }.join("\n")
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
           {"test_command": "...", "setup_command": "...", "tools": ["..."]}
           - test_command runs the whole suite and exits non-zero on failure. Call the test runner directly
             (e.g. `python -m pytest`, `npx vitest run`, `bundle exec rspec`), not a script the coder could edit.#{"\n             This project already runs its tests with `#{test_command}`; that stays in use, so you can leave test_command out." unless test_command.to_s.strip.empty?}
           - setup_command installs dependencies (e.g. `npm install`), or leave it out.
           - tools lists the command-line programs the tests need (e.g. ["node", "npm"]).

        ## Rules
        - Do not implement the step itself. Another agent will, and it cannot change your test files.
        - Do not commit. Leave your changes in the working tree.
      JOB
      sections.join("\n\n")
    end

    def code(task:, attempt:, locked_paths:, test_command:, feedback: nil)
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
        Run the tests with: `#{test_command}`
        Do not commit. Leave your changes in the working tree.
      PROMPT
      sections << "## Feedback from the previous attempt\n#{feedback}\n" if feedback && !feedback.to_s.strip.empty?
      sections.join("\n")
    end
  end
end
