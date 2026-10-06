# frozen_string_literal: true

require "shellwords"

module Runeforge
  # Wraps the agents Runeforge runs in the sandbox: its own ruby_llm agent (the default for API
  # keys) or a vendor CLI. Each adapter supplies a shell snippet that reads the prompt from
  # $RUNEFORGE_PROMPT, knows how to read token usage from the output, and how to name a model.
  module Adapters
    Usage = Data.define(:input_tokens, :output_tokens, :cost_cents) do
      def self.none = new(input_tokens: 0, output_tokens: 0, cost_cents: 0)

      def total_tokens = input_tokens + output_tokens
    end

    CLASSES = {
      "ruby_llm" => -> { RubyLlm }, "claude_code" => -> { ClaudeCode }, "codex" => -> { Codex },
      "aider" => -> { Aider }, "command" => -> { Command }
    }.freeze

    def self.names = CLASSES.keys

    def self.build(name, provider:, model: nil, command: nil, sandboxed: true, settings: {})
      if name.to_s == "gemini"
        raise Error, "the gemini adapter was removed (Google's Gemini CLI is deprecated); Gemini models run on the ruby_llm agent: drop `adapter: gemini`"
      end

      klass = CLASSES.fetch(name.to_s) { raise Error, "unknown agent adapter #{name.inspect} (known: #{names.join(', ')})" }.call
      klass.new(provider:, model:, command:, sandboxed:, settings:)
    end

    class Base
      attr_reader :model, :provider

      def initialize(provider:, model: nil, command: nil, sandboxed: true, settings: {})
        @provider = provider
        @model = model
        @command = command
        @sandboxed = sandboxed
        @settings = settings
      end

      def name = self.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

      def label = [name, model_arg].compact.join("/")

      # The variable the CLI reads its API key from inside the container.
      def key_env = provider&.key_var

      # Variable the CLI reads a subscription token from, for agents that accept one instead of an
      # API key; nil for the rest.
      def oauth_env = nil

      def command = raise NotImplementedError

      def parse_usage(_output) = Usage.none

      # The CLI's own explanation when a run failed, from its output or error stream; nil if none.
      def failure_detail(_output, _errors = "") = nil

      # The agent's closing summary (its explanation of what it did or why it stopped), or nil.
      # Claude Code and Runeforge's own agent both print it as "result" in their final JSON.
      def summary(output)
        text = (last_json(output) || {})["result"]
        text.is_a?(String) && !text.strip.empty? ? text.strip : nil
      end

      # The model as this CLI expects it.
      def model_arg = model

      # Files to write into the workspace's .runeforge/ before the run: name => contents.
      def files = {}

      # Settings for the run, passed in as environment variables (never secrets).
      def run_env = {}

      private

      def sandboxed? = @sandboxed

      def model_flag(flag = "--model") = model_arg ? " #{flag} #{Shellwords.escape(model_arg)}" : ""

      # The last JSON object in some output, including one printed across several lines.
      def last_json(text)
        lines = text.to_s.lines
        (lines.size - 1).downto(0) do |index|
          next unless lines[index].lstrip.start_with?("{")

          data = JSON.parse(lines[index..].join) rescue next
          return data if data.is_a?(Hash)
        end
        nil
      end
    end

    # Runeforge's own agent (AgentRunner) on the ruby_llm gem: any provider ruby_llm supports,
    # with tools to read, search and edit the workspace and run commands in it.
    class RubyLlm < Base
      RUNNER = File.expand_path("agent_runner.rb", __dir__)
      # Where the agent image keeps ruby_llm, apart from any project's gems.
      IMAGE_GEM_PATH = "/opt/runeforge/gems"

      def files = { "agent.rb" => File.read(RUNNER) }

      def run_env
        { "RUNEFORGE_MODEL" => model.to_s, "RUNEFORGE_PROVIDER" => provider.name, "RUNEFORGE_API_KEY_VAR" => key_env.to_s,
          "RUNEFORGE_API_BASE" => @settings["api_base"].to_s,
          "RUNEFORGE_MAX_TOOL_CALLS" => (@settings["max_tool_calls"] || 200).to_s }
      end

      # In the image, ruby_llm lives in its own gem directory; unsandboxed, it's this Ruby's.
      def command
        ruby = sandboxed? ? "ruby" : Shellwords.escape(RbConfig.ruby)
        gem_path = sandboxed? ? IMAGE_GEM_PATH : Gem.path.join(":")
        %(RUNEFORGE_PROJECT_GEM_PATH="${GEM_PATH:-}" GEM_PATH=#{Shellwords.escape(gem_path)} #{ruby} .runeforge/agent.rb)
      end

      def parse_usage(output)
        data = last_json(output) || {}
        Usage.new(input_tokens: data["input_tokens"].to_i, output_tokens: data["output_tokens"].to_i,
                  cost_cents: (data["cost_usd"].to_f * 100).ceil)
      end

      def failure_detail(output, errors = "")
        error = (last_json(output) || {})["error"]
        error || errors.to_s.lines.grep(/Error|error:/).last&.strip
      end
    end

    class ClaudeCode < Base
      # A long-lived token from `claude setup-token` uses a Claude subscription instead of API credit.
      def oauth_env = "CLAUDE_CODE_OAUTH_TOKEN"

      # With --output-format json, errors such as "Not logged in" arrive as the result, not on stderr.
      def failure_detail(output, _errors = "")
        data = last_json(output) || {}
        data["is_error"] ? data["result"].to_s.strip.then { |text| text.empty? ? nil : text } : nil
      end

      def command
        # Inside a container the container is the permission boundary. On the host (`sandbox: none`,
        # chosen per project) the agent must still run the toolchain (swift test, xcodebuild), which
        # any narrower mode refuses in -p, so it gets the same full access.
        %(claude -p "$RUNEFORGE_PROMPT" --output-format json --dangerously-skip-permissions#{model_flag})
      end

      def parse_usage(output)
        data = last_json(output) || {}
        usage = data["usage"] || {}
        input = %w[input_tokens cache_creation_input_tokens cache_read_input_tokens].sum { |key| usage[key].to_i }
        Usage.new(input_tokens: input, output_tokens: usage["output_tokens"].to_i,
                  cost_cents: (data["total_cost_usd"].to_f * 100).ceil)
      end
    end

    class Codex < Base
      def command
        # As for Claude Code: --full-auto's own sandbox blocks xcodebuild's DerivedData and simulators.
        %(codex exec --json --dangerously-bypass-approvals-and-sandbox#{model_flag} "$RUNEFORGE_PROMPT")
      end

      # `codex exec --json` prints JSONL events; turn.completed events carry token usage.
      def parse_usage(output)
        input = output_tokens = 0
        events(output).each do |event|
          next unless event["type"] == "turn.completed"

          usage = event["usage"] || {}
          input += usage["input_tokens"].to_i
          output_tokens += usage["output_tokens"].to_i
        end
        Usage.new(input_tokens: input, output_tokens:, cost_cents: 0)
      end

      def failure_detail(output, _errors = "")
        event = events(output).reverse.find { |e| %w[error turn.failed].include?(e["type"]) }
        event && (event["message"] || event.dig("error", "message"))
      end

      private

      def events(output)
        output.to_s.each_line.filter_map do |line|
          event = JSON.parse(line) rescue next
          event if event.is_a?(Hash)
        end
      end
    end

    # Aider drives any provider LiteLLM supports, named "provider/model".
    class Aider < Base
      def command
        %(aider --yes-always --no-auto-commits --no-stream --no-check-update#{model_flag} --message "$RUNEFORGE_PROMPT")
      end

      def model_arg = model && "#{provider.name}/#{model}"

      # Aider prints lines like "Tokens: 12k sent, 1.2k received. Cost: $0.02 message, $0.05 session."
      def parse_usage(output)
        sent = received = 0
        cost = 0.0
        output.to_s.scan(/Tokens: ([\d.]+)(k?) sent, ([\d.]+)(k?) received\.(?: Cost: \$([\d.]+) message)?/) do |s, sk, r, rk, c|
          sent += scale(s, sk)
          received += scale(r, rk)
          cost += c.to_f
        end
        Usage.new(input_tokens: sent, output_tokens: received, cost_cents: (cost * 100).ceil)
      end

      private

      def scale(number, suffix) = (number.to_f * (suffix == "k" ? 1000 : 1)).round
    end

    # Any shell snippet. If its last output line is JSON with input_tokens/output_tokens/cost_usd,
    # that is used for accounting.
    class Command < Base
      def key_env = nil

      def command
        raise Error, "agent.command must be set when agent.adapter is 'command'" if @command.to_s.strip.empty?

        @command
      end

      def parse_usage(output)
        data = JSON.parse(output.to_s.lines.last.to_s)
        return Usage.none unless data.is_a?(Hash)

        Usage.new(input_tokens: data["input_tokens"].to_i, output_tokens: data["output_tokens"].to_i,
                  cost_cents: (data["cost_usd"].to_f * 100).ceil)
      rescue JSON::ParserError
        Usage.none
      end
    end
  end
end
