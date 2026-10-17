# frozen_string_literal: true

require "digest"

module Runeforge
  # A project's code, split into chunks (a function, a route handler, a component, a test block)
  # once per file version, so the brief can hand each agent the code its step needs instead of
  # every session reading the whole project again (see Brief). Runs on the host from the host
  # clone; files are keyed by git object id, so indexing a commit only reads the files it changed.
  #
  # Search ranks exact anchors first (a route or data-testid the ticket names), then pointers
  # the ledger holds for related items, then embeddings (when memory.embedding_model is set),
  # then BM25 over words, and finally pulls in one hop of imports: a chunk's tests and helpers.
  class CodeIndex
    CHUNK_CHARS = 4000
    MAX_CHUNK_LINES = 120
    WINDOW = 60
    SOURCE = /\.(?:rb|rake|js|mjs|cjs|jsx|ts|tsx|vue|svelte|py|go|rs|java|kt|kts|swift|cs|php|ex|exs|erb|haml|slim|sql|css|scss|html|sh)\z/
    SKIP = %r{(?:\A|/)(?:node_modules|vendor|dist|build|coverage|tmp|\.git|\.runeforge|public/assets|Pods|DerivedData)/|\Aruneforge/|
              \.min\.(?:js|css)\z|(?:package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile\.lock|Cargo\.lock|poetry\.lock)\z}x
    LANG = { /\.(?:js|mjs|cjs|jsx|ts|tsx|vue|svelte)\z/ => "js", /\.(?:rb|rake|erb)\z/ => "ruby", /\.py\z/ => "python",
             /\.go\z/ => "go", /\.rs\z/ => "rust", /\.(?:java|kt|kts)\z/ => "jvm", /\.swift\z/ => "swift" }.freeze

    # Lines that start a chunk, per language: [pattern, kind]. Routes start one at any indent;
    # the rest only near the left margin, so a nested helper stays with its function.
    STARTS = {
      "js" => [
        [/\A\s*(?:\w+)\.(get|post|put|patch|delete)\(\s*["'`](\/[^"'`]*)/, "route"],
        [/\A {0,2}(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/, "function"],
        [/\A {0,2}(?:export\s+)?(?:const|let)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[\w$]+)\s*=>/, "function"],
        [/\A {0,2}(?:export\s+(?:default\s+)?)?class\s+([A-Za-z_$][\w$]*)/, "class"],
        [/\A {0,2}(?:describe|test|it)\(\s*["'`]([^"'`]+)/, "test"]
      ],
      "ruby" => [
        [/\A {0,4}(?:class|module)\s+([A-Z][\w:]*)/, "class"],
        [/\A {0,4}def\s+(self\.)?([\w?!=]+)/, "function"],
        [/\A {0,2}(?:RSpec\.)?(?:describe|context|it)\s+["']?([^"'\n]+)/, "test"],
        [/\A\s*(get|post|put|patch|delete)\s+["'](\/[^"']*)/, "route"]
      ],
      "python" => [
        [/\A {0,4}(?:async\s+)?def\s+(\w+)/, "function"],
        [/\A {0,4}class\s+(\w+)/, "class"],
        [/\A\s*@\w+\.(get|post|put|patch|delete|route)\(\s*["'](\/[^"']*)/, "route"]
      ],
      "go" => [[/\Afunc\s+(?:\([^)]*\)\s*)?(\w+)/, "function"], [/\Atype\s+(\w+)\s+struct/, "class"]],
      "rust" => [[/\A {0,4}(?:pub\s+)?(?:async\s+)?fn\s+(\w+)/, "function"], [/\A(?:pub\s+)?(?:struct|enum|impl|trait)\s+(\w+)/, "class"]],
      "jvm" => [[/\A {0,4}(?:public|private|protected|internal)?\s*(?:static\s+)?(?:fun|class|interface|object)\s+(\w+)/, "class"]],
      "swift" => [[/\A {0,4}(?:public\s+|private\s+)?(?:func|struct|class|enum|protocol|extension)\s+(\w+)/, "function"]]
    }.freeze
    IMPORTS = {
      "js" => [/\bimport\s+(?:[^"';]+?\s+from\s+)?["']([^"']+)["']/, /\brequire\(\s*["']([^"']+)["']\s*\)/, /\bimport\(\s*["']([^"']+)["']\s*\)/],
      "ruby" => [/\brequire_relative\s+["']([^"']+)["']/],
      "python" => [/^\s*from\s+(\.[\w.]*)\s+import/, /^\s*import\s+([\w.]+)/]
    }.freeze

    Result = Data.define(:path, :symbol, :kind, :line_start, :line_end, :text, :score, :why) do
      def label = "#{path}:#{line_start}-#{line_end}#{symbol ? " #{symbol}" : ''}"
    end

    attr_reader :db, :config

    def initialize(db, config, repos:, embedder:)
      @db = db
      @config = config || {}
      @repos = repos
      @embedder = embedder
    end

    def enabled? = @config["enabled"] != false

    def files = db[:runeforge_code_files]

    def chunks = db[:runeforge_chunks]

    def vectors = db[:runeforge_chunk_vectors]

    # Indexes the repository at a commit: chunks every source file version it hasn't seen, and
    # embeds chunks without a vector for the model. Returns { files:, chunks:, new_files: }.
    def index!(repo, sha)
      return nil unless enabled?

      tree = tree(repo, sha)
      known = files.where(repo:, blob: tree.values.uniq).select_map(:blob)
      fresh = tree.reject { |_path, blob| known.include?(blob) }.uniq { |_path, blob| blob }
      fresh.each do |path, blob|
        text = @repos.blob(repo, blob)
        next files.insert(repo:, blob:, lang: nil, imports: "[]", created_at: Runeforge.now) if text.include?("\u0000")

        add_file(repo, path, blob, text)
      end
      embed_missing!(repo, tree.values.uniq) if @embedder&.enabled?
      count = chunks.where(repo:, blob: tree.values.uniq).count
      state = { repo:, sha:, files: tree.size, chunks: count, model: @embedder&.enabled? ? @embedder.model : nil, indexed_at: Runeforge.now }
      db[:runeforge_index_state].where(repo:, sha:).delete
      db[:runeforge_index_state].insert(state)
      { files: tree.size, chunks: count, new_files: fresh.size }
    end

    # The source files at a commit: { path => blob }, without vendored, built or oversized files.
    def tree(repo, sha)
      max = @config.fetch("max_file_kb", 200).to_i * 1024
      out = Git.run("ls-tree", "-r", "-l", "-z", sha, dir: @repos.path(repo))
      out.split("\u0000").each_with_object({}) do |entry, tree|
        meta, path = entry.split("\t", 2)
        _mode, type, blob, size = meta.to_s.split
        next unless type == "blob" && path && path.match?(SOURCE) && !path.match?(SKIP) && size.to_i <= max

        tree[path] = blob
      end
    end

    # Ranked chunks for a step. query: its text; anchors: [[kind, value]] from the ledger;
    # boost: { path => [symbol or nil, ...] } for pointers the ledger holds on related items.
    # ui: the step names a screen, so the project's stylesheets are likely to change too.
    def search(repo, sha, query:, anchors: [], boost: {}, limit: 30, ui: false)
      tree = tree(repo, sha)
      by_blob = tree.each_with_object(Hash.new { |h, k| h[k] = [] }) { |(path, blob), map| map[blob] << path }
      rows = chunks.where(repo:, blob: by_blob.keys).all
      return [] if rows.empty?

      docs = rows.flat_map { |row| by_blob[row[:blob]].map { |path| row.merge(path:) } }
      scores = Hash.new(0.0)
      why = Hash.new { |h, k| h[k] = [] }
      key = ->(doc) { [doc[:path], doc[:id]] }

      anchor_scores(docs, anchors).each { |doc, score, hit| scores[key.(doc)] += score; why[key.(doc)] << hit }
      docs.each do |doc|
        symbols = boost[doc[:path]]
        next unless symbols

        hit = symbols.compact.find { |symbol| doc[:symbol] == symbol || doc[:text].include?(symbol) }
        scores[key.(doc)] += hit ? 6.0 : 3.0
        why[key.(doc)] << "ledger#{hit ? " #{hit}" : ''}"
      end
      bm25(docs, query).each { |doc, score| scores[key.(doc)] += score * 5 }
      vector_scores(docs, query).each do |doc, score|
        scores[key.(doc)] += score * @config.fetch("meaning_weight", 1.0).to_f
        why[key.(doc)] << "meaning #{score.round(2)}"
      end

      ranked = docs.select { |doc| scores[key.(doc)].positive? }.sort_by { |doc| [-scores[key.(doc)], doc[:path], doc[:line_start]] }
      resolved = imports_in(repo, tree)
      hop!(ranked.first(8), docs, scores, why, key, resolved)
      hubs!(docs, scores, why, key, resolved)
      styles!(docs, scores, why, key) if ui
      ranked = docs.select { |doc| scores[key.(doc)].positive? }.sort_by { |doc| [-scores[key.(doc)], doc[:path], doc[:line_start]] }
      # Each file's best chunk first, then their second and third: a map of 20 lines names as many
      # files as it can rather than three chunks of the same one.
      per_file = Hash.new(0)
      ranked = ranked.select { |doc| (per_file[doc[:path]] += 1) <= 3 }
      rank = Hash.new(0)
      ranked = ranked.each_with_index.sort_by { |doc, i| [(rank[doc[:path]] += 1), i] }.map(&:first)
      ranked.first(limit).map do |doc|
        Result.new(path: doc[:path], symbol: doc[:symbol], kind: doc[:kind], line_start: doc[:line_start], line_end: doc[:line_end],
                   text: doc[:text], score: scores[key.(doc)].round(2), why: why[key.(doc)].uniq.first(3))
      end
    end

    # --- chunking ----------------------------------------------------------------------------------

    def self.lang(path) = LANG.find { |pattern, _| path.match?(pattern) }&.last

    # [{symbol:, kind:, line_start:, line_end:, text:}] for one file.
    def self.chunk(path, text)
      lines = text.lines
      return [] if lines.empty?

      starts = STARTS.fetch(lang(path).to_s, []).then do |patterns|
        lines.each_with_index.filter_map do |line, index|
          pattern, kind = patterns.find { |regex, _| line.match?(regex) }
          next unless pattern

          match = line.match(pattern)
          symbol = kind == "route" ? "#{match[1].upcase} #{match[2]}" : match.captures.compact.last
          kind = "component" if kind == "function" && symbol.to_s.match?(/\A[A-Z]/) && lang(path) == "js"
          kind = "test" if path.match?(%r{(?:\A|/)(?:test|tests|spec|__tests__)/|[._-](?:test|spec)\.}) && kind != "route"
          [index, symbol.to_s.strip[0, 200], kind]
        end
      end
      return windows(lines, 0, lines.size, nil, "window") if starts.empty?

      out = []
      out.concat(windows(lines, 0, starts.first[0], nil, "window")) if starts.first[0] >= 3
      starts.each_with_index do |(start, symbol, kind), i|
        stop = starts[i + 1]&.first || lines.size
        out.concat(windows(lines, start, stop, symbol, kind))
      end
      out
    end

    def self.windows(lines, from, to, symbol, kind)
      return [] if to <= from || lines[from...to].join.strip.empty?
      return [piece(lines, from, to, symbol, kind)] if to - from <= MAX_CHUNK_LINES

      (from...to).step(WINDOW).map { |start| piece(lines, start, [start + WINDOW, to].min, symbol, kind) }
    end

    def self.piece(lines, from, to, symbol, kind)
      text = lines[from...to].join
      { symbol:, kind:, line_start: from + 1, line_end: to, text: text[0, CHUNK_CHARS],
        signature: lines[from...to].find { |l| !l.strip.empty? }.to_s.strip[0, 200] }
    end

    def self.imports(path, text) = IMPORTS.fetch(lang(path).to_s, []).flat_map { |regex| text.scan(regex).flatten }.uniq.first(50)

    # A relative import, as a path in the tree: "./db.js" from server/app.js -> server/db.js.
    def self.resolve(from, spec, tree)
      return nil unless spec.start_with?(".")

      base = File.expand_path(spec, "/#{File.dirname(from)}").delete_prefix("/")
      candidates = [base, *%w[.js .mjs .ts .tsx .jsx .rb .py].map { |ext| "#{base}#{ext}" },
                    *%w[index.js index.ts index.jsx].map { |name| File.join(base, name) }]
      candidates.find { |candidate| tree.key?(candidate) }
    end

    private

    def add_file(repo, path, blob, text)
      db.transaction do
        files.insert(repo:, blob:, lang: self.class.lang(path), imports: JSON.generate(self.class.imports(path, text)), created_at: Runeforge.now)
        self.class.chunk(path, text).each do |piece|
          chunks.insert(repo:, blob:, symbol: piece[:symbol], kind: piece[:kind], line_start: piece[:line_start], line_end: piece[:line_end],
                        content_hash: Digest::SHA256.hexdigest("#{path}\n#{piece[:text]}"), signature: piece[:signature], text: piece[:text])
        end
      end
    end

    def embed_missing!(repo, blobs)
      model = @embedder.model
      have = vectors.where(model:).select(:content_hash)
      missing = chunks.where(repo:, blob: blobs).exclude(content_hash: have).select(:content_hash, :symbol, :signature, :text).all
                      .uniq { |row| row[:content_hash] }
      missing.each_slice(Embedder::BATCH) do |batch|
        got = @embedder.embed(batch.map { |row| embed_text(row) })
        return unless got

        batch.zip(got).each do |row, vector|
          vectors.insert(content_hash: row[:content_hash], model:, dims: vector.size, vector: Sequel.blob(Embedder.pack(vector)))
        end
      end
    end

    def embed_text(row) = "#{row[:symbol]}\n#{row[:signature]}\n#{row[:text][0, 1500]}"

    def anchor_scores(docs, anchors)
      return [] if anchors.empty?

      docs.filter_map do |doc|
        text = doc[:text].gsub(%r{/:\w+}, "/:p").gsub(/\/\$\{[^}]+\}/, "/:p")
        hits = anchors.select do |kind, value|
          probe = kind == "route" ? value.split(" ", 2).last : value
          probe.size >= 3 && text.include?(probe)
        end
        next if hits.empty?

        score = hits.sum { |kind, _| %w[route testid].include?(kind) ? 6.0 : kind == "field" ? 1.0 : 3.0 }
        [doc, score, "anchor #{hits.first(2).map(&:last).join(', ')}"]
      end
    end

    # BM25 over each chunk's path, symbol and text, scaled so the best chunk scores 1.
    def bm25(docs, query, k1: 1.2, b: 0.75)
      terms = Memory.words(query)
      return [] if terms.empty?

      tokens = docs.map { |doc| Memory.words("#{doc[:path].tr('/._-', ' ')} #{doc[:symbol]} #{doc[:text]}") }
      avg = tokens.sum(&:size).to_f / [tokens.size, 1].max
      df = Hash.new(0)
      tokens.each { |words| words.each { |word| df[word] += 1 } }
      n = docs.size
      raw = docs.zip(tokens).filter_map do |doc, words|
        set = words.tally
        score = terms.sum do |term|
          f = set[term].to_i
          next 0.0 if f.zero?

          idf = Math.log(1 + ((n - df[term] + 0.5) / (df[term] + 0.5)))
          idf * (f * (k1 + 1)) / (f + (k1 * (1 - b + (b * words.size / [avg, 1].max))))
        end
        [doc, score] if score.positive?
      end
      top = raw.map(&:last).max.to_f
      top.zero? ? [] : raw.map { |doc, score| [doc, score / top] }
    end

    def vector_scores(docs, query)
      return [] unless @embedder&.enabled?

      query_vector = @embedder.embed([query.to_s[0, 4000]], kind: :query)&.first
      return [] unless query_vector

      have = vectors.where(model: @embedder.model, content_hash: docs.map { |d| d[:content_hash] }.uniq).all
                    .to_h { |row| [row[:content_hash], Embedder.unpack(row[:vector])] }
      sims = docs.filter_map { |doc| (vector = have[doc[:content_hash]]) && [doc, Embedder.dot(vector, query_vector)] }
      return [] if sims.size < 2

      # Models differ in how alike unrelated text looks (nomic-embed-text puts most code near 0.6),
      # so what counts is a chunk's place among this project's chunks: the best scores 1, the
      # median 0, and only the top 20 above the median count.
      values = sims.map(&:last).sort
      median = values[values.size / 2]
      top = values.last
      return [] if top - median < 1e-6

      sims.sort_by { |_doc, score| -score }.first(20).filter_map do |doc, score|
        scaled = (score - median) / (top - median)
        [doc, scaled.round(3)] if scaled.positive?
      end
    end

    # { path => [paths it imports] } at the commit.
    def imports_in(repo, tree)
      imports = files.where(repo:, blob: tree.values.uniq).all.to_h { |row| [row[:blob], JSON.parse(row[:imports] || "[]")] }
      tree.to_h { |path, blob| [path, imports.fetch(blob, []).filter_map { |spec| self.class.resolve(path, spec, tree) }] }
    end

    # Files most of the project imports (the app's entry point, its database module, the web
    # client's API helper) are touched by most cross-cutting steps; on Courtside a step adding
    # idempotency keys changed server/app.js and server/db.js while its words named neither.
    def hubs!(docs, scores, why, key, resolved)
      degree = Hash.new(0)
      resolved.each { |from, deps| deps.each { |dep| degree[dep] += 1 unless from.match?(%r{(?:\A|/)(?:test|spec|tests)/}) } }
      top = degree.values.max.to_i
      return if top < 2

      degree.select { |_path, n| n >= 2 }.each do |path, n|
        best = docs.select { |doc| doc[:path] == path }.min_by { |doc| doc[:line_start] }
        next unless best

        scores[key.(best)] += 1.5 * n / top
        why[key.(best)] << "imported by #{n} files"
      end
    end

    FRONT_END = %r{\.(?:jsx|tsx|vue|svelte|erb|haml|slim|html)\z|(?:\A|/)(?:web|client|frontend|app/views|app/components)/}

    # A step that names a screen is mostly built in the front end, and usually restyles it. Its
    # words (book, slot, week) match the server's code just as well, so front-end files get a lift.
    def styles!(docs, scores, why, key)
      docs.each do |doc|
        if doc[:path].match?(/\.(?:css|scss)\z/) && doc[:line_start] == 1
          scores[key.(doc)] += 3.0
          why[key.(doc)] << "stylesheet"
        elsif doc[:path].match?(FRONT_END) && scores[key.(doc)].positive?
          scores[key.(doc)] += 2.0
          why[key.(doc)] << "front end"
        end
      end
    end

    # One hop from the best chunks: the files they import, and the test files that import them.
    # A neighbour gets one bonus, from its best-scoring neighbour, however many import it.
    def hop!(top, docs, scores, why, key, resolved)
      bonus = {}
      top.map { |doc| doc[:path] }.uniq.each do |path|
        base = scores[key.(top.find { |d| d[:path] == path })]
        neighbours = resolved.fetch(path, []) + resolved.select { |_other, deps| deps.include?(path) }.keys
        neighbours.uniq.each do |other|
          best = docs.select { |doc| doc[:path] == other }.max_by { |doc| scores[key.(doc)] }
          next unless best

          note = resolved.fetch(other, []).include?(path) ? "imports #{File.basename(path)}" : "imported by #{File.basename(path)}"
          bonus[key.(best)] = [base * 0.3, note] if bonus[key.(best)].nil? || bonus[key.(best)][0] < base * 0.3
        end
      end
      bonus.each do |k, (amount, note)|
        scores[k] += amount
        why[k] << note
      end
    end
  end
end
