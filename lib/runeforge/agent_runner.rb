# frozen_string_literal: true

# Runeforge's own coding agent for API-key models, built on the ruby_llm gem.
#
# Runeforge copies this file into a task's workspace (.runeforge/agent.rb) and runs it inside the
# sandbox, in place of a vendor CLI. It is self-contained: it needs only Ruby and ruby_llm, never
# Runeforge itself. The model gets tools to read, search and change the files in the current
# directory and to run commands there; everything it changes becomes the task's patch.
#
# Settings come from the environment:
#   RUNEFORGE_PROMPT          the task prompt
#   RUNEFORGE_MODEL           model id; empty uses ruby_llm's default
#   RUNEFORGE_PROVIDER        ruby_llm provider slug (anthropic, gemini, openai, deepseek, ...)
#   RUNEFORGE_API_KEY_VAR     the variable holding the provider's API key (e.g. GEMINI_API_KEY)
#   RUNEFORGE_API_BASE        optional API endpoint, e.g. for OpenAI-compatible providers
#   RUNEFORGE_MAX_TOOL_CALLS  stop after this many tool calls (default 200)
#   RUNEFORGE_PROJECT_GEM_PATH  the project's GEM_PATH, restored for commands the agent runs
#
# Progress goes to stdout as plain lines; the last line is JSON:
#   {"result": "...", "input_tokens": n, "output_tokens": n, "cost_usd": x}
# or, on failure, {"error": "...", ...} with exit status 1.

require "json"
require "open3"
require "fileutils"
require "logger"
require "timeout"
require "ruby_llm"

module RuneforgeAgent
  ROOT = File.realpath(Dir.pwd)
  HIDDEN = %w[.git .runeforge].freeze
  # The .runeforge/ files the planner is asked to write; the rest of it (this script, the prompt,
  # the output logs) stays out of the agent's reach.
  META_FILES = %w[.runeforge/spec.md .runeforge/project.json].freeze
  SKIP_DIRS = %w[.git .runeforge node_modules .venv venv __pycache__ vendor/bundle target .next dist build coverage].freeze
  MAX_READ = 200_000
  MAX_OUTPUT = 12_000
  COMMAND_TIMEOUT = Integer(ENV.fetch("RUNEFORGE_COMMAND_TIMEOUT", "600"))

  INSTRUCTIONS = <<~TEXT
    You are an autonomous coding agent. The repository is the current directory; work only
    inside it. Use the tools to look around, change files and run commands (tests, builds,
    package installs). Read before you edit. Keep changes focused on the task. Do not commit;
    leave your changes in the working tree. When the task is done, reply with a short summary.
  TEXT

  class AgentError < StandardError; end

  module_function

  def say(line)
    $stdout.puts(line)
    $stdout.flush
  end

  # A path inside the workspace, never into .git or .runeforge, never out through ../ or a symlink.
  def resolve(path)
    full = File.expand_path(path.to_s.empty? ? "." : path.to_s, ROOT)
    # For a path that doesn't exist yet, resolve its nearest existing ancestor (following symlinks).
    existing = full
    existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
    real = File.join(File.realpath(existing), full.delete_prefix(existing)).chomp("/")
    raise AgentError, "#{path} is outside the repository" unless real == ROOT || real.start_with?("#{ROOT}/")

    relative = real.delete_prefix("#{ROOT}/")
    hidden = HIDDEN.any? { |dir| relative == dir || relative.start_with?("#{dir}/") }
    raise AgentError, "#{path} is not available to the agent" if hidden && !META_FILES.include?(relative)

    real
  rescue Errno::ENOENT
    raise AgentError, "#{path}: no such directory"
  end

  def relative(path) = path == ROOT ? "." : path.delete_prefix("#{ROOT}/")

  def clip(text, limit = MAX_OUTPUT)
    text = text.to_s.scrub
    text.length > limit ? "…(#{text.length - limit} characters cut)…\n#{text[-limit..]}" : text
  end

  # Commands run with the project's own gem settings, not the agent's.
  def command_env
    project = ENV.fetch("RUNEFORGE_PROJECT_GEM_PATH", "")
    { "GEM_PATH" => project.empty? ? nil : project }
  end

  class Tool < RubyLLM::Tool
    # Plain names (read_file, run_command) rather than ruby_llm's namespaced default.
    def self.tool_name = RubyLLM::Support::Utils.underscore(name.split("::").last)

    # Mistakes come back to the model as the tool's result, so it can correct them.
    def execute(**args)
      RuneforgeAgent.say("→ #{self.class.tool_name} #{args.values.first.to_s.lines.first.to_s.strip[0, 100]}")
      run(**args)
    rescue RuneforgeAgent::AgentError, SystemCallError, IOError, ArgumentError, RegexpError => e
      { error: e.message }
    end
  end

  class ListFiles < Tool
    description "Lists files under a directory of the repository (recursively, skipping .git and dependency folders)."
    parameter :path, description: "Directory relative to the repository root; '.' for the whole repository", required: false

    def run(path: ".")
      dir = RuneforgeAgent.resolve(path)
      files = []
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.each do |entry|
        next if entry.split("/").any? { |part| %w[. ..].include?(part) }
        next if RuneforgeAgent::SKIP_DIRS.any? { |skip| entry == skip || entry.start_with?("#{skip}/") || entry.include?("/#{skip}/") }
        next unless File.file?(File.join(dir, entry))

        files << entry
        break if files.size >= 1000
      end
      files.empty? ? "(no files)" : files.join("\n")
    end
  end

  class ReadFile < Tool
    description "Reads a text file from the repository."
    parameter :path, description: "File path relative to the repository root"

    def run(path:)
      file = RuneforgeAgent.resolve(path)
      raise RuneforgeAgent::AgentError, "#{path} is not a file" unless File.file?(file)

      RuneforgeAgent.clip(File.read(file), RuneforgeAgent::MAX_READ)
    end
  end

  class WriteFile < Tool
    description "Creates or replaces a whole file in the repository."
    parameter :path, description: "File path relative to the repository root"
    parameter :content, description: "The complete new contents of the file"

    def run(path:, content:)
      file = RuneforgeAgent.resolve(path)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, content)
      "wrote #{RuneforgeAgent.relative(file)} (#{content.bytesize} bytes)"
    end
  end

  class EditFile < Tool
    description "Replaces one exact piece of text in a file. old_text must appear exactly once; include enough surrounding lines to make it unique."
    parameter :path, description: "File path relative to the repository root"
    parameter :old_text, description: "The exact text to replace"
    parameter :new_text, description: "The replacement text"

    def run(path:, old_text:, new_text:)
      file = RuneforgeAgent.resolve(path)
      text = File.read(file)
      count = text.scan(old_text).size
      raise RuneforgeAgent::AgentError, "old_text was not found in #{path}" if count.zero?
      raise RuneforgeAgent::AgentError, "old_text appears #{count} times in #{path}; include more context" if count > 1

      File.write(file, text.sub(old_text) { new_text })
      "edited #{RuneforgeAgent.relative(file)}"
    end
  end

  class Search < Tool
    description "Searches file contents with a regular expression (grep -E). Returns matching lines with file names and line numbers."
    parameter :pattern, description: "Extended regular expression"
    parameter :path, description: "Directory or file to search, relative to the repository root", required: false

    def run(pattern:, path: ".")
      target = RuneforgeAgent.resolve(path)
      excludes = RuneforgeAgent::SKIP_DIRS.map { |dir| "--exclude-dir=#{File.basename(dir)}" }
      out, = Open3.capture2e("grep", "-rnIE", *excludes, "--", pattern, RuneforgeAgent.relative(target), chdir: RuneforgeAgent::ROOT)
      out.empty? ? "(no matches)" : RuneforgeAgent.clip(out)
    end
  end

  class RunCommand < Tool
    description "Runs a shell command in the repository root (tests, builds, installs). Returns the exit status and the end of its output."
    parameter :command, description: "The shell command, run with sh -c"

    def run(command:)
      output = +""
      status = nil
      Open3.popen2e(RuneforgeAgent.command_env, "sh", "-c", command, chdir: RuneforgeAgent::ROOT, pgroup: true) do |stdin, out, thread|
        stdin.close
        reader = Thread.new { out.each_line { |line| output << line } }
        unless thread.join(RuneforgeAgent::COMMAND_TIMEOUT)
          Process.kill("KILL", -thread.pid) rescue nil
          output << "\n[stopped after #{RuneforgeAgent::COMMAND_TIMEOUT} seconds]"
        end
        reader.join(5)
        status = thread.value
      end
      "exit status #{status.exitstatus || "signal #{status.termsig}"}\n#{RuneforgeAgent.clip(output)}"
    end
  end

  TOOLS = [ListFiles, ReadFile, WriteFile, EditFile, Search, RunCommand].freeze

  def configure
    provider = ENV.fetch("RUNEFORGE_PROVIDER", "").strip
    key_var = ENV.fetch("RUNEFORGE_API_KEY_VAR", "").strip
    RubyLLM.configure do |config|
      config.logger = Logger.new($stderr, level: Logger::WARN)
      config.request_timeout = 600
      config.public_send(:"#{provider}_api_key=", ENV.fetch(key_var, nil)) if !key_var.empty? && config.respond_to?(:"#{provider}_api_key=")
      base = ENV.fetch("RUNEFORGE_API_BASE", "").strip
      config.public_send(:"#{provider}_api_base=", base) if !base.empty? && config.respond_to?(:"#{provider}_api_base=")
    end
  end

  def chat
    model = ENV.fetch("RUNEFORGE_MODEL", "").strip
    provider = ENV.fetch("RUNEFORGE_PROVIDER", "").strip
    options = { model: model.empty? ? nil : model, provider: provider.empty? ? nil : provider.to_sym }.compact
    begin
      RubyLLM.chat(**options)
    rescue RubyLLM::ModelNotFoundError
      # A model too new for ruby_llm's registry: use it anyway (its cost is then unknown).
      RubyLLM.chat(**options, assume_model_exists: true)
    end
  end

  def usage(chat)
    tokens = chat.tokens
    { input_tokens: tokens.input.to_i + tokens.cache_read.to_i + tokens.cache_write.to_i,
      output_tokens: tokens.output.to_i + tokens.thinking.to_i,
      cost_usd: chat.cost.total.to_f }
  rescue StandardError
    { input_tokens: 0, output_tokens: 0, cost_usd: 0.0 }
  end

  def run
    prompt = ENV.fetch("RUNEFORGE_PROMPT", "")
    raise AgentError, "no prompt (RUNEFORGE_PROMPT is empty)" if prompt.strip.empty?

    configure
    session = chat
    limit = Integer(ENV.fetch("RUNEFORGE_MAX_TOOL_CALLS", "200"))
    calls = 0
    session.with_instructions(INSTRUCTIONS).with_tools(*TOOLS)
    session.before_tool_call { session.cancel if (calls += 1) > limit }
    say "Runeforge agent: #{session.model.id} via #{session.provider.slug}"
    begin
      response = session.ask(prompt)
    rescue RubyLLM::CancelledError
      raise AgentError, "stopped after #{limit} tool calls without finishing"
    end
    result = response.content.to_s.strip
    say result unless result.empty?
    say JSON.generate({ result: result[0, 2000] }.merge(usage(session)))
  rescue AgentError, RubyLLM::Error, RubyLLM::ConfigurationError, RubyLLM::ModelNotFoundError, ArgumentError => e
    say JSON.generate({ error: e.message.to_s.strip[0, 2000] }.merge(session ? usage(session) : {}))
    exit 1
  end
end

RuneforgeAgent.run if $PROGRAM_NAME == __FILE__
