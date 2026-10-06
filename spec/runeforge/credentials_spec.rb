# frozen_string_literal: true

RSpec.describe "Agent credentials" do
  let(:backend) { "sqlite" }
  let(:vars) { %w[RUNEFORGE_LLM_API_KEY RUNEFORGE_ANTHROPIC_API_KEY RUNEFORGE_GEMINI_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY] }

  around do |example|
    saved = vars.to_h { |name| [name, ENV.fetch(name, nil)] }
    vars.each { |name| ENV.delete(name) }
    example.run
  ensure
    saved.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
  end

  def env_for(adapter: "claude_code", mode: "docker", **settings)
    build_env(Runeforge::Config.deep_merge({ "agent" => { "adapter" => adapter, "command" => nil }, "sandbox" => { "mode" => mode } }, settings))
  end

  describe Runeforge::Environment do
    it "passes the API key into the container under the agent CLI's own name" do
      ENV["RUNEFORGE_LLM_API_KEY"] = "sk-ant-api"
      ENV["CLAUDE_CODE_OAUTH_TOKEN"] = "sk-ant-oat"
      expect(env_for.agent_key_env).to eq("ANTHROPIC_API_KEY" => "sk-ant-api")
    end

    it "falls back to a Claude subscription token when there is no API key" do
      ENV["RUNEFORGE_LLM_API_KEY"] = "  "
      ENV["CLAUDE_CODE_OAUTH_TOKEN"] = "sk-ant-oat"
      expect(env_for.agent_key_env).to eq("CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat")
      expect { env_for.check_agent_credentials! }.not_to raise_error
    end

    it "doesn't hand a Claude token to agents that can't use one" do
      ENV["CLAUDE_CODE_OAUTH_TOKEN"] = "sk-ant-oat"
      expect(env_for(adapter: "codex").agent_key_env).to eq({})
    end

    it "stops before work starts when a sandboxed agent has no credentials" do
      expect { env_for.check_agent_credentials! }.to raise_error(Runeforge::Error) { |error|
        expect(error.message).to include("The planner (and the coder) has no credentials for the default model (anthropic)",
                                         "RUNEFORGE_ANTHROPIC_API_KEY  an API key", "RUNEFORGE_LLM_API_KEY  an API key",
                                         "CLAUDE_CODE_OAUTH_TOKEN", "claude setup-token")
      }
      expect { env_for(adapter: "codex").check_agent_credentials! }.to raise_error(Runeforge::Error) { |error|
        expect(error.message).not_to include("setup-token")
      }
    end

    it "doesn't ask for credentials when agents run locally, in a dry run, or as a plain command" do
      expect { env_for(mode: "none").check_agent_credentials! }.not_to raise_error
      expect { env_for("dry_run" => { "enabled" => true }).check_agent_credentials! }.not_to raise_error
      expect { env_for(adapter: "command", "agent" => { "adapter" => "command", "command" => "true" }).check_agent_credentials! }
        .not_to raise_error
    end
  end

  describe "models and keys per role" do
    it "gives each role the CLI and key of its own model" do
      ENV["RUNEFORGE_LLM_API_KEY"] = "sk-ant-default"
      ENV["RUNEFORGE_GEMINI_API_KEY"] = "gemini-key"
      env = env_for(adapter: nil, "agent" => { "model" => "claude-sonnet-4-5", "roles" => { "planner" => { "model" => "gemini-2.5-pro" } } })

      expect(env.agent("planner").label).to eq("ruby_llm/gemini-2.5-pro")
      expect(env.agent_key_env("planner")).to eq("GEMINI_API_KEY" => "gemini-key")
      expect(env.agent("coder").label).to eq("ruby_llm/claude-sonnet-4-5")
      expect(env.agent_key_env("coder")).to eq("ANTHROPIC_API_KEY" => "sk-ant-default")
    end

    it "never sends the default model's key to another provider" do
      ENV["RUNEFORGE_LLM_API_KEY"] = "sk-ant-default"
      env = env_for(adapter: nil, "agent" => { "model" => "claude-sonnet-4-5", "roles" => { "coder" => { "model" => "gemini-2.5-pro" } } })
      expect(env.agent_key_env("coder")).to eq({})
      expect { env.check_agent_credentials! }.to raise_error(Runeforge::Error, /The coder has no credentials for gemini-2.5-pro \(gemini\).*RUNEFORGE_GEMINI_API_KEY/m)
    end

    it "reaches any OpenAI-compatible service through provider: openai and api_base" do
      ENV["MY_TOGETHER_KEY"] = "together-key"
      env = env_for("agent" => { "roles" => { "coder" => {
                      "model" => "meta-llama/Llama-3.3-70B", "provider" => "openai",
                      "api_base" => "https://api.together.xyz/v1", "key_env" => "MY_TOGETHER_KEY"
                    } } })
      expect(env.agent("coder").label).to eq("ruby_llm/meta-llama/Llama-3.3-70B")
      expect(env.agent_key_env("coder")).to eq("OPENAI_API_KEY" => "together-key")
      expect(env.agent("coder").adapter.run_env).to include("RUNEFORGE_API_BASE" => "https://api.together.xyz/v1",
                                                            "RUNEFORGE_PROVIDER" => "openai")
    ensure
      ENV.delete("MY_TOGETHER_KEY")
    end

    it "estimates cost from pricing when the CLI doesn't report it" do
      env = env_for(adapter: nil, "agent" => { "model" => "gemini-2.5-pro", "pricing" => { "input_per_mtok" => 1.25, "output_per_mtok" => 10 } })
      output = JSON.generate("result" => "ok", "input_tokens" => 400_000, "output_tokens" => 50_000, "cost_usd" => 0)
      expect(env.agent("planner").usage(output)).to have_attributes(input_tokens: 400_000, output_tokens: 50_000, cost_cents: 100)
    end
  end

  describe "choosing the agent" do
    it "runs API keys on the ruby_llm agent and a Claude subscription token on Claude Code" do
      ENV["CLAUDE_CODE_OAUTH_TOKEN"] = "sk-ant-oat"
      env = env_for(adapter: nil, "agent" => { "model" => "claude-sonnet-4-5" })
      expect(env.agent("coder").adapter.name).to eq("claude_code")
      expect(env.agent_key_env("coder")).to eq("CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat")

      ENV["RUNEFORGE_ANTHROPIC_API_KEY"] = "sk-ant-api"
      env = env_for(adapter: nil, "agent" => { "model" => "claude-sonnet-4-5" })
      expect(env.agent("coder").adapter.name).to eq("ruby_llm")
      expect(env.agent_key_env("coder")).to eq("ANTHROPIC_API_KEY" => "sk-ant-api")
    end

    it "offers the subscription token for Claude models even when it picked the API-key agent" do
      env = env_for(adapter: nil, "agent" => { "model" => "claude-sonnet-5-5", "oauth_token_env" => "RUNEFORGE_CLAUDE_TOKEN" })
      expect { env.check_agent_credentials! }.to raise_error(Runeforge::Error) { |error|
        expect(error.message).to include("has no credentials for claude-sonnet-5-5 (anthropic)",
                                         "RUNEFORGE_CLAUDE_TOKEN  a Claude subscription token", "must be exported")
      }
    end

    it "gives the ruby_llm agent a model for its provider when none is set" do
      ENV["RUNEFORGE_GEMINI_API_KEY"] = "gemini-key"
      expect(env_for(adapter: nil).agent("coder").label).to eq("ruby_llm/claude-sonnet-5-5")
      expect(env_for(adapter: nil, "agent" => { "provider" => "gemini" }).agent("coder").label).to eq("ruby_llm/gemini-pro-latest")
      expect { env_for(adapter: nil, "agent" => { "provider" => "mistral" }).agent("coder") }
        .to raise_error(Runeforge::Error, /set agent.model \(or agent.roles.coder.model\) for the mistral provider/)
      expect(env_for(adapter: "claude_code").agent("coder").label).to eq("claude_code") # Claude Code picks its own
    end

    it "keeps an adapter that's named explicitly" do
      ENV["RUNEFORGE_ANTHROPIC_API_KEY"] = "sk-ant-api"
      expect(env_for(adapter: "claude_code").agent("coder").adapter.name).to eq("claude_code")
    end
  end

  describe Runeforge::Adapters::ClaudeCode do
    # The output of the failed run that prompted this: no credentials in the container.
    let(:not_logged_in) do
      '{"type":"result","subtype":"success","is_error":true,"num_turns":1,"terminal_reason":"api_error",' \
        '"result":"Not logged in · Please run /login","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}'
    end

    it "reads the CLI's error from its JSON output" do
      adapter = described_class.new(provider: Runeforge::Providers.fetch("anthropic"))
      expect(adapter.failure_detail("noise\n#{not_logged_in}\n")).to eq("Not logged in · Please run /login")
      expect(adapter.failure_detail('{"is_error":false,"result":"ok"}')).to be_nil
      expect(adapter.failure_detail("not json")).to be_nil
      expect(adapter.oauth_env).to eq("CLAUDE_CODE_OAUTH_TOKEN")
    end

    it "explains a failed planning run instead of an empty stderr tail" do
      bin = File.join(tmpdir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "claude"), "#!/bin/sh\necho '#{not_logged_in}'\nexit 1\n")
      File.chmod(0o755, File.join(bin, "claude"))
      original_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{bin}:#{original_path}"
      env = env_for(mode: "none")
      add_repo(env)
      Runeforge::Intake.new(env).create(repo: "demo", id: "T-1", title: "Greet", description: "Say hello")
      task = drive(env, "T-1", until_status: "failed")

      expect(task[:error]).to include("planning failed: agent exited with status 1: Not logged in · Please run /login",
                                      "CLAUDE_CODE_OAUTH_TOKEN")
    ensure
      ENV["PATH"] = original_path if original_path
    end
  end
end
