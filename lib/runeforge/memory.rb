# frozen_string_literal: true

module Runeforge
  # Lessons from steps that went wrong: a plan Runeforge rejected, tests the coder couldn't pass, a
  # step that failed. Before planning a step, the planner sees the few lessons most like it, so a
  # mistake made once (a test command that runs nothing, a test contradicting an earlier one) isn't
  # made again in every later step.
  #
  # Lessons are matched by the words they share with the step, weighted by how rare each word is,
  # which needs no model and suits failure messages, whose useful words are exact (file names,
  # commands, error text). With `memory.embedding_model` set they're matched by meaning instead:
  # each lesson and step is embedded (RubyLLM.embed, through `embedder`) and compared by cosine.
  class Memory
    STOPWORDS = %w[the and for that this with from are was were not but you your its has have had into than then
                   them they will would should could can all any each when what which who how why use used test tests].freeze
    # Lessons considered per search: the newest, so old projects don't make every plan slow.
    SCAN = 500
    # The planner sees at most this much (about 800 tokens), so pitfalls never crowd out the step.
    MAX_CHARS = 3200

    attr_writer :embedder

    def initialize(db, config)
      @db = db
      @config = config
    end

    def table = @db[:runeforge_lessons]

    def enabled? = @config["enabled"] != false

    def record(repo:, kind:, text:, task_id: nil, step: nil)
      return unless enabled? && !text.to_s.strip.empty?

      text = text.to_s.strip[0, 2000]
      vector = embed([step, text].compact.join("\n"))
      table.insert(repo:, task_id:, kind:, step:, text:, created_at: Runeforge.now,
                   model: vector && @config["embedding_model"], embedding: vector && Sequel.blob(vector.pack("e*")))
    end

    # Word-matched lessons from another plan must score at least this (see #by_words). Shared
    # words alone matched a guests step with series and closures lessons on Courtside: those
    # scored 2 to 2.7, so the bar sits above them.
    OTHER_PLAN_BAR = 3.0

    # The lessons most like the step, best first: from this repo, other than the step's own task.
    # plan: the step's plan ("plan-d-money-p4"): its own lessons, and Runeforge's rejections of a
    # plan (kind "plan": a test command that runs nothing, ...), which hold for the whole project,
    # count by the usual match; another plan's contested tests and failures must clear
    # OTHER_PLAN_BAR (memory.lesson_bar).
    def pitfalls(repo:, query:, exclude_task: nil, limit: @config.fetch("max_lessons", 3), plan: nil)
      return [] unless enabled?

      scope = table.where(repo:)
      scope = scope.where(Sequel.|({ task_id: nil }, Sequel.~(task_id: exclude_task))) if exclude_task
      rows = scope.order(Sequel.desc(:id)).limit(SCAN).all
      return [] if rows.empty?

      vector = rows.any? { |row| row[:embedding] } ? embed(query, kind: :query) : nil
      scored = vector ? by_meaning(rows, vector) : by_words(rows, query)
      bar = @config.fetch("lesson_bar", OTHER_PLAN_BAR).to_f
      scored = scored.select { |row, score| vector || !plan || own_plan?(row, plan) || row[:kind] == "plan" || score >= bar }
      chosen = []
      scored.sort_by { |row, score| [-score, -row[:id]] }.first(limit).each do |row, _score|
        break if (chosen.sum { |c| c[:text].size } + row[:text].size) > MAX_CHARS

        chosen << row
      end
      chosen
    end

    def self.words(text) = text.to_s.downcase.scan(/[a-z0-9_.\/-]{3,}/).reject { |word| STOPWORDS.include?(word) }.uniq

    # The plan a step task belongs to: "plan-d-money-p4-s2-r2" -> "plan-d-money-p4".
    def self.plan_of(task_id) = task_id.to_s[/\A.+?-p\d+(?=-s\d+|-r\d+|\z)/] || task_id.to_s

    private

    def own_plan?(row, plan) = row[:task_id] && self.class.plan_of(row[:task_id]) == plan

    # Rare shared words count most (inverse document frequency); a lesson must share two.
    def by_words(rows, query)
      terms = self.class.words(query)
      docs = rows.map { |row| [row, self.class.words("#{row[:step]} #{row[:text]}")] }
      frequency = Hash.new(0)
      docs.each { |_row, words| words.each { |word| frequency[word] += 1 } }
      docs.filter_map do |row, words|
        shared = terms & words
        next if shared.size < 2

        [row, shared.sum { |word| Math.log((docs.size + 1.0) / frequency[word]) } / Math.sqrt(words.size)]
      end
    end

    def by_meaning(rows, vector)
      rows.filter_map do |row|
        next unless row[:embedding]

        score = cosine(row[:embedding].to_s.unpack("e*"), vector)
        [row, score] if score >= @config.fetch("min_similarity", 0.5)
      end
    end

    def cosine(a, b)
      return 0.0 unless a.size == b.size

      dot = a.zip(b).sum { |x, y| x * y }
      norm = Math.sqrt(a.sum { |x| x * x }) * Math.sqrt(b.sum { |y| y * y })
      norm.zero? ? 0.0 : dot / norm
    end

    # Embedding is optional: without a model, or when the call fails, lessons are matched by words.
    # Through Embedder, so lessons and the code index share one model (Ollama included).
    def embed(text, kind: :document)
      model = @config["embedding_model"]
      return nil if model.to_s.empty?
      return @embedder.call(text, model) if @embedder

      Embedder.new(@config).embed([text], kind:)&.first
    rescue StandardError
      nil
    end
  end
end
