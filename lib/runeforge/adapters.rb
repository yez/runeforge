# frozen_string_literal: true

require "shellwords"

module Runeforge
  # Wraps coding-agent CLIs. Each adapter supplies a shell snippet that reads the prompt from
  # $RUNEFORGE_PROMPT, and knows how to read token usage from the CLI's output.
  module Adapters
    Usage = Data.define(:input_tokens, :output_tokens, :cost_cents) do
      def self.none = new(input_tokens: 0, output_tokens: 0, cost_cents: 0)

      def total_tokens = input_tokens + output_tokens
    end

    def self.build(config, sandboxed:)
      klass = {
        "claude_code" => ClaudeCode, "codex" => Codex, "aider" => Aider, "command" => Command
      }.fetch(config.fetch("adapter")) { raise Error, "unknown agent adapter #{config.fetch('adapter').inspect}" }
      klass.new(model: config["model"], command: config["command"], sandboxed:,
                container_key_env: config["container_key_env"])
    end

    class Base
      attr_reader :model

      def initialize(model: nil, command: nil, sandboxed: true, container_key_env: nil)
        @model = model
        @command = command
        @sandboxed = sandboxed
        @container_key_env = container_key_env
      end

      def name = self.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

      def label = [name, model].compact.join("/")

      def key_env = @container_key_env || default_key_env

      def default_key_env = nil

      def command = raise NotImplementedError

      def parse_usage(_output) = Usage.none

      private

      def sandboxed? = @sandboxed

      def model_flag(flag = "--model") = model ? " #{flag} #{Shellwords.escape(model)}" : ""
    end

    class ClaudeCode < Base
      def default_key_env = "ANTHROPIC_API_KEY"

      def command
        # Inside a container the container is the permission boundary; on the host, only allow edits.
        permissions = sandboxed? ? "--dangerously-skip-permissions" : "--permission-mode acceptEdits"
        %(claude -p "$RUNEFORGE_PROMPT" --output-format json #{permissions}#{model_flag})
      end

      def parse_usage(output)
        data = JSON.parse(output.to_s.lines.reverse.find { |line| line.strip.start_with?("{") } || "{}")
        usage = data["usage"] || {}
        input = %w[input_tokens cache_creation_input_tokens cache_read_input_tokens].sum { |key| usage[key].to_i }
        Usage.new(input_tokens: input, output_tokens: usage["output_tokens"].to_i,
                  cost_cents: (data["total_cost_usd"].to_f * 100).ceil)
      rescue JSON::ParserError
        Usage.none
      end
    end

    class Codex < Base
      def default_key_env = "OPENAI_API_KEY"

      def command
        permissions = sandboxed? ? "--dangerously-bypass-approvals-and-sandbox" : "--full-auto"
        %(codex exec --json #{permissions}#{model_flag} "$RUNEFORGE_PROMPT")
      end

      # `codex exec --json` prints JSONL events; turn.completed events carry token usage.
      def parse_usage(output)
        input = output_tokens = 0
        output.to_s.each_line do |line|
          event = JSON.parse(line) rescue next
          next unless event.is_a?(Hash) && event["type"] == "turn.completed"

          usage = event["usage"] || {}
          input += usage["input_tokens"].to_i
          output_tokens += usage["output_tokens"].to_i
        end
        Usage.new(input_tokens: input, output_tokens:, cost_cents: 0)
      end
    end

    class Aider < Base
      def default_key_env = "ANTHROPIC_API_KEY"

      def command
        %(aider --yes-always --no-auto-commits --no-stream --no-check-update#{model_flag} --message "$RUNEFORGE_PROMPT")
      end

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
