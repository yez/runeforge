# frozen_string_literal: true

module Runeforge
  # Model providers: which API key a model needs. With an API key every provider is driven by
  # Runeforge's own agent on the ruby_llm gem (see AgentRunner); Claude Code is used when it's
  # asked for, or when the only credential is a Claude subscription token.
  #
  # runeforge.yml names a model, optionally as "provider/model":
  #
  #   agent:
  #     model: gemini-pro-latest                 # provider inferred from the name
  #     roles:
  #       coder: { model: claude-sonnet-5-5 }
  #
  # Provider names are ruby_llm's. For an OpenAI-compatible service ruby_llm has no provider for
  # (Together, Groq, Fireworks, a local server), use `provider: openai` with `api_base:`.
  module Providers
    Provider = Data.define(:name, :key_var)

    REGISTRY = {
      "anthropic" => Provider.new(name: "anthropic", key_var: "ANTHROPIC_API_KEY"),
      "openai" => Provider.new(name: "openai", key_var: "OPENAI_API_KEY"),
      "gemini" => Provider.new(name: "gemini", key_var: "GEMINI_API_KEY"),
      "deepseek" => Provider.new(name: "deepseek", key_var: "DEEPSEEK_API_KEY"),
      "mistral" => Provider.new(name: "mistral", key_var: "MISTRAL_API_KEY"),
      "openrouter" => Provider.new(name: "openrouter", key_var: "OPENROUTER_API_KEY"),
      "xai" => Provider.new(name: "xai", key_var: "XAI_API_KEY"),
      "perplexity" => Provider.new(name: "perplexity", key_var: "PERPLEXITY_API_KEY")
    }.freeze

    # Bare model names that identify their provider.
    MODEL_PATTERNS = {
      /\Aclaude/ => "anthropic", /\A(gpt-|o\d|codex|chatgpt)/ => "openai", /\Agemini/ => "gemini",
      /\Adeepseek/ => "deepseek", /\A(mistral|codestral|devstral|magistral)/ => "mistral", /\Agrok/ => "xai",
      /\Asonar/ => "perplexity"
    }.freeze

    # The model the ruby_llm agent uses when none is configured. Providers without one need
    # `agent.model` set.
    DEFAULT_MODELS = {
      "anthropic" => "claude-sonnet-5-5", "openai" => "gpt-5.6", "gemini" => "gemini-pro-latest",
      "deepseek" => "deepseek-v4-pro"
    }.freeze

    # The provider a CLI implies when no model says otherwise.
    ADAPTER_PROVIDERS = { "claude_code" => "anthropic", "codex" => "openai", "aider" => "anthropic" }.freeze

    module_function

    # [provider name, model name without any provider prefix] for a configured model.
    def split(model, provider: nil, adapter: nil)
      model = model.to_s.strip
      prefix, rest = model.split("/", 2)
      return [prefix, rest] if rest && !provider && (REGISTRY.key?(prefix) || !MODEL_PATTERNS.any? { |p, _| model.match?(p) })

      name = provider&.to_s || MODEL_PATTERNS.find { |pattern, _| model.match?(pattern) }&.last ||
             ADAPTER_PROVIDERS[adapter.to_s] || "anthropic"
      [name, model.empty? ? nil : model]
    end

    # The registered provider, or one assembled from settings for a provider Runeforge doesn't know.
    def fetch(name, key_var: nil)
      known = REGISTRY[name]
      return known.with(key_var: key_var || known.key_var) if known

      Provider.new(name:, key_var: key_var || "#{name.upcase.gsub(/[^A-Z0-9]/, '_')}_API_KEY")
    end
  end
end
