# frozen_string_literal: true

RSpec.describe Runeforge::Adapters do
  def build(name, model: nil, command: nil, sandboxed: true, provider: nil)
    provider_name, bare = Runeforge::Providers.split(model, provider:, adapter: name)
    described_class.build(name, provider: Runeforge::Providers.fetch(provider_name), model: bare, command:, sandboxed:)
  end

  it "skips Claude Code's permission prompts only inside a sandbox" do
    expect(build("claude_code").command).to include("--dangerously-skip-permissions")
    expect(build("claude_code", sandboxed: false).command).to include("--dangerously-skip-permissions")
    expect(build("claude_code", model: "claude-opus-5-5").command).to include("--model claude-opus-5-5")
  end

  it "reads Claude Code usage and cost from its JSON output" do
    output = JSON.generate("result" => "done", "total_cost_usd" => 0.123,
                           "usage" => { "input_tokens" => 10, "cache_read_input_tokens" => 5, "output_tokens" => 7 })
    usage = build("claude_code").parse_usage(output)
    expect(usage).to have_attributes(input_tokens: 15, output_tokens: 7, cost_cents: 13)
  end

  it "sums Codex turn usage from JSONL events and reports its errors" do
    output = [{ "type" => "turn.completed", "usage" => { "input_tokens" => 3, "output_tokens" => 4 } },
              { "type" => "item.completed" },
              { "type" => "turn.completed", "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }]
             .map { |event| JSON.generate(event) }.join("\n") + "\nnot json\n"
    expect(build("codex").parse_usage(output)).to have_attributes(input_tokens: 4, output_tokens: 5)
    failed = %({"type":"turn.failed","error":{"message":"Incorrect API key provided"}}\n)
    expect(build("codex").failure_detail(failed)).to eq("Incorrect API key provided")
  end

  it "runs Runeforge's ruby_llm agent with the model and provider, and reads its result" do
    adapter = build("ruby_llm", model: "gemini-2.5-pro")
    expect(adapter.command).to eq(%(RUNEFORGE_PROJECT_GEM_PATH="${GEM_PATH:-}" GEM_PATH=/opt/runeforge/gems ruby .runeforge/agent.rb))
    expect(build("ruby_llm", sandboxed: false).command).to include(RbConfig.ruby)
    expect(adapter.files.keys).to eq(["agent.rb"])
    expect(adapter.files["agent.rb"]).to include("module RuneforgeAgent")
    expect(adapter.run_env).to include("RUNEFORGE_MODEL" => "gemini-2.5-pro", "RUNEFORGE_PROVIDER" => "gemini",
                                       "RUNEFORGE_API_KEY_VAR" => "GEMINI_API_KEY", "RUNEFORGE_MAX_TOOL_CALLS" => "200")
    output = "→ WriteFile lib/a.rb\nDone.\n#{JSON.generate(result: 'Done.', input_tokens: 120, output_tokens: 30, cost_usd: 0.0123)}\n"
    expect(adapter.parse_usage(output)).to have_attributes(input_tokens: 120, output_tokens: 30, cost_cents: 2)
    failed = JSON.generate(error: "API key not valid. Please pass a valid API key.", input_tokens: 0, output_tokens: 0)
    expect(adapter.failure_detail(failed)).to eq("API key not valid. Please pass a valid API key.")
  end

  it "explains that the Gemini CLI adapter is gone" do
    expect { build("gemini") }.to raise_error(Runeforge::Error, /Gemini CLI is deprecated.*ruby_llm/)
  end

  it "names models for Aider as provider/model" do
    expect(build("aider", model: "openrouter/qwen/qwen3-coder").command).to include("--model openrouter/qwen/qwen3-coder")
    expect(build("aider", model: "deepseek-chat").command).to include("--model deepseek/deepseek-chat")
  end

  it "parses Aider's token lines" do
    output = "Tokens: 12k sent, 1.5k received. Cost: $0.02 message, $0.02 session.\n"
    expect(build("aider").parse_usage(output)).to have_attributes(input_tokens: 12_000, output_tokens: 1500, cost_cents: 2)
  end

  it "requires a command for the command adapter and tolerates missing usage" do
    expect { build("command").command }.to raise_error(Runeforge::Error, /agent.command/)
    expect(build("command", command: "true").parse_usage("plain text").total_tokens).to eq(0)
    expect(build("command", command: "true").key_env).to be_nil
  end

  it "rejects unknown adapters" do
    expect { build("nope") }.to raise_error(Runeforge::Error, /unknown agent adapter "nope" \(known: ruby_llm, claude_code/)
  end

  describe Runeforge::Providers do
    it "infers the provider from the model, or takes it from a prefix" do
      expect(described_class.split("claude-sonnet-4-5")).to eq(["anthropic", "claude-sonnet-4-5"])
      expect(described_class.split("gemini-2.5-pro")).to eq(["gemini", "gemini-2.5-pro"])
      expect(described_class.split("gpt-5")).to eq(["openai", "gpt-5"])
      expect(described_class.split("gemini/gemini-2.5-flash")).to eq(["gemini", "gemini-2.5-flash"])
      expect(described_class.split("openrouter/deepseek/deepseek-chat")).to eq(["openrouter", "deepseek/deepseek-chat"])
      expect(described_class.split(nil, adapter: "codex")).to eq(["openai", nil])
      expect(described_class.split(nil)).to eq(["anthropic", nil])
    end

    it "knows each provider's key variable, and accepts others" do
      expect(described_class.fetch("gemini")).to have_attributes(key_var: "GEMINI_API_KEY")
      expect(described_class.fetch("ollama_cloud")).to have_attributes(key_var: "OLLAMA_CLOUD_API_KEY")
      expect(described_class.fetch("openai", key_var: "GROQ_API_KEY")).to have_attributes(key_var: "GROQ_API_KEY")
    end
  end
end
