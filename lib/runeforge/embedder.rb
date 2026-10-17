# frozen_string_literal: true

require "net/http"
require "uri"

module Runeforge
  # Embeddings for the code index and lessons, made on this machine's side of the sandbox: the
  # agents' containers never see a model or a key, only the text Runeforge hands them.
  #
  # memory.embedding_provider picks how:
  # - ollama: a local model (e.g. nomic-embed-text) through Ollama's /api/embed, at
  #   memory.embedding_url (default http://127.0.0.1:11434). Works with a Claude subscription,
  #   which can't make embeddings, and uses the Mac's GPU, which containers can't.
  # - anything else ruby_llm knows (openai, gemini, ...), with the key in memory.embedding_key_env.
  # No embedding_model means no embeddings: the index searches by anchors and words alone.
  class Embedder
    OLLAMA_URL = "http://127.0.0.1:11434"
    BATCH = 32

    attr_reader :model

    def initialize(config = {}, http: nil)
      @config = config || {}
      @model = @config["embedding_model"].to_s.strip
      @http = http
    end

    def enabled? = !@model.empty?

    def ollama? = @config["embedding_provider"].to_s == "ollama"

    def url = (@config["embedding_url"].to_s.strip.empty? ? OLLAMA_URL : @config["embedding_url"].to_s.strip.chomp("/"))

    # Models trained with task prefixes embed much better with them: nomic-embed-text was trained
    # with "search_query: " and "search_document: ", and without them every chunk looked alike.
    PREFIXES = { /nomic-embed/ => { query: "search_query: ", document: "search_document: " },
                 /\A(?:mxbai-embed|snowflake-arctic-embed)/ => { query: "Represent this sentence for searching relevant passages: ", document: "" } }.freeze

    def prefix(kind) = PREFIXES.find { |pattern, _| model.match?(pattern) }&.last&.fetch(kind, "").to_s

    # One vector per text, each normalised to length 1; nil when embeddings are off or the
    # model can't be reached (the caller falls back to words). kind: :query for a search, else
    # :document.
    def embed(texts, kind: :document)
      return nil unless enabled?
      return [] if texts.empty?

      texts = texts.map { |text| "#{prefix(kind)}#{text}" }
      texts.each_slice(BATCH).flat_map { |batch| raw(batch) }.map { |vector| self.class.normalize(vector) }
    rescue StandardError => e
      warn_once("runeforge: embeddings from #{ollama? ? "Ollama at #{url}" : @config['embedding_provider'] || 'ruby_llm'} " \
                "failed (#{e.class}: #{e.message.lines.first&.strip}); searching by words instead")
      nil
    end

    # Whether the model answers, for `runeforge doctor`: [ok, message].
    def check
      return [true, "no embedding model set (searching by anchors and words)"] unless enabled?

      vector = raw(["runeforge check"]).first
      [true, "#{model} answers (#{vector.size} dimensions)"]
    rescue StandardError => e
      hint = ollama? ? " Start Ollama and run `ollama pull #{model}`." : ""
      [false, "#{model} didn't answer: #{e.message.lines.first&.strip}.#{hint}"]
    end

    def self.normalize(vector)
      norm = Math.sqrt(vector.sum { |x| x * x })
      norm.zero? ? vector : vector.map { |x| x / norm }
    end

    def self.pack(vector) = vector.pack("e*")

    def self.unpack(blob) = blob.to_s.unpack("e*")

    def self.dot(a, b)
      return 0.0 unless a.size == b.size

      sum = 0.0
      a.each_index { |i| sum += a[i] * b[i] }
      sum
    end

    private

    def raw(batch)
      return @http.call(batch, model) if @http

      ollama? ? ollama(batch) : ruby_llm(batch)
    end

    def ollama(batch)
      uri = URI("#{url}/api/embed")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 120) do |http|
        http.post(uri.path, JSON.generate(model:, input: batch), "Content-Type" => "application/json")
      end
      raise Error, "HTTP #{response.code}: #{response.body.to_s[0, 200]}" unless response.is_a?(Net::HTTPSuccess)

      vectors = JSON.parse(response.body)["embeddings"]
      raise Error, "no embeddings in the answer" unless vectors.is_a?(Array) && vectors.size == batch.size

      vectors
    end

    def ruby_llm(batch)
      require "ruby_llm"
      provider = @config["embedding_provider"].to_s
      key = ENV.fetch(@config["embedding_key_env"].to_s, nil)
      context = RubyLLM.context { |config| config.public_send(:"#{provider}_api_key=", key) if key && !provider.empty? }
      vectors = context.embed(batch, model:, provider: provider.empty? ? nil : provider.to_sym).vectors
      vectors.first.is_a?(Array) ? vectors : [vectors]
    end

    def warn_once(message)
      return if @warned

      @warned = true
      warn message
    end
  end
end
