# frozen_string_literal: true

RSpec.describe Runeforge::Adapters do
  def build(name, **opts) = described_class.build({ "adapter" => name, "model" => opts[:model], "command" => opts[:command] }, sandboxed: opts.fetch(:sandboxed, true))

  it "skips Claude Code's permission prompts only inside a sandbox" do
    expect(build("claude_code").command).to include("--dangerously-skip-permissions")
    expect(build("claude_code", sandboxed: false).command).to include("--permission-mode acceptEdits")
    expect(build("claude_code", model: "claude-opus-5-5").command).to include("--model claude-opus-5-5")
  end

  it "reads Claude Code usage and cost from its JSON output" do
    output = JSON.generate("result" => "done", "total_cost_usd" => 0.123,
                           "usage" => { "input_tokens" => 10, "cache_read_input_tokens" => 5, "output_tokens" => 7 })
    usage = build("claude_code").parse_usage(output)
    expect(usage).to have_attributes(input_tokens: 15, output_tokens: 7, cost_cents: 13)
  end

  it "sums Codex turn usage from JSONL events" do
    output = [{ "type" => "turn.completed", "usage" => { "input_tokens" => 3, "output_tokens" => 4 } },
              { "type" => "item.completed" },
              { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }]
             .map { |event| JSON.generate(event) }.join("\n") + "\nnot json\n"
    expect(build("codex").parse_usage(output)).to have_attributes(input_tokens: 4, output_tokens: 5)
  end

  it "parses Aider's token lines" do
    output = "Tokens: 12k sent, 1.5k received. Cost: $0.02 message, $0.02 session.\n"
    expect(build("aider").parse_usage(output)).to have_attributes(input_tokens: 12_000, output_tokens: 1500, cost_cents: 2)
  end

  it "requires a command for the command adapter and tolerates missing usage" do
    expect { build("command").command }.to raise_error(Runeforge::Error, /agent.command/)
    expect(build("command", command: "true").parse_usage("plain text").total_tokens).to eq(0)
  end

  it "rejects unknown adapters" do
    expect { build("nope") }.to raise_error(Runeforge::Error, /unknown agent adapter/)
  end
end
