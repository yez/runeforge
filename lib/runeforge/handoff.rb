# frozen_string_literal: true

module Runeforge
  # .runeforge/handoff.json: what a planner or coder leaves for the agents after it (see
  # Prompts.handoff_section). Agent-written, so it's data: every path must exist at the commit,
  # every symbol and test name must be in that file, and anything that doesn't check out is
  # dropped (and listed, for the log) rather than stored. A handoff that's missing or broken
  # costs nothing: the step goes on, and the ledger still learns from its diff.
  module Handoff
    FILE = "handoff.json"
    MAX_BYTES = 65_536
    STATUSES = %w[new already_built conflict].freeze
    Checked = Data.define(:data, :dropped)

    module_function

    def read(workspace)
      raw = workspace.read_meta_text(FILE, max_bytes: MAX_BYTES)
      data = raw && JSON.parse(raw)
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, Workspace::UnsafeFile
      nil
    end

    # file: ->(path) { the file's text at the commit, or nil }.
    def check(data, role:, file:)
      return nil unless data.is_a?(Hash)

      dropped = []
      out = {}
      if role == :planner
        out["requirements"] = list(data["requirements"]).filter_map do |req|
          id = req["id"].to_s.strip[0, 160]
          next drop(dropped, "a requirement without an id") if id.empty?

          status = STATUSES.include?(req["status"]) ? req["status"] : "new"
          tests = list(req["tests"], strings: true).filter_map { |test| check_test(test, file, dropped) }
          code = list(req["code"]).filter_map { |ref| check_ref(ref, file, dropped) }
          cites = list(req["cites"], strings: true).filter_map { |cite| check_cite(cite, file, dropped) }
          { "id" => id, "status" => status, "tests" => tests, "code" => code, "cites" => cites }
        end
      else
        out["implemented"] = list(data["implemented"]).filter_map do |entry|
          id = entry["id"].to_s.strip[0, 160]
          next drop(dropped, "an implemented entry without an id") if id.empty?

          { "id" => id, "code" => list(entry["code"]).filter_map { |ref| check_ref(ref, file, dropped) } }
        end
      end
      out["facts"] = list(data["facts"]).filter_map do |fact|
        text = fact["text"].to_s.strip
        next drop(dropped, "a fact without text") if text.empty? || fact["key"].to_s.strip.empty?

        { "key" => fact["key"].to_s[0, 100], "kind" => fact["kind"].to_s, "text" => text[0, 400],
          "paths" => list(fact["paths"], strings: true).map(&:to_s).select { |path| file.call(path) }.first(5) }
      end
      out["discovered"] = list(data["discovered"]).first(10).filter_map do |entry|
        next if entry["title"].to_s.strip.empty?

        { "title" => entry["title"].to_s[0, 120], "why" => entry["why"].to_s[0, 1000], "evidence" => entry["evidence"].to_s[0, 500] }
      end
      Checked.new(data: out, dropped:)
    end

    def drop(dropped, why)
      dropped << why
      nil
    end

    def list(value, strings: false)
      Array(value).first(50).select { |entry| strings ? entry.is_a?(String) || entry.is_a?(Hash) : entry.is_a?(Hash) }
    end

    # "test/file.test.js > the test's name", or {"path", "name"}: kept when the file has that name.
    def check_test(test, file, dropped)
      path, name = test.is_a?(Hash) ? [test["path"], test["name"]] : test.to_s.split(/\s+>\s+/, 2)
      path = path.to_s.strip
      text = file.call(path)
      return drop(dropped, "test #{path}: no such file") unless text
      return { "path" => path, "name" => nil } if name.to_s.strip.empty?

      name = name.strip
      return { "path" => path, "name" => name[0, 300] } if text.include?(name)

      # "describe > it": nested names, each in the file; the test's own name is the last.
      parts = name.split(/\s+>\s+/)
      return { "path" => path, "name" => parts.last[0, 300] } if parts.size > 1 && parts.all? { |part| text.include?(part) }

      drop(dropped, "test #{path} > #{name}: not in that file")
    end

    def check_ref(ref, file, dropped)
      path = ref["path"].to_s.strip
      text = file.call(path)
      return drop(dropped, "code #{path}: no such file") unless text

      symbol = ref["symbol"].to_s.strip
      line = nil
      unless symbol.empty?
        index = text.lines.index { |l| l.include?(symbol) }
        return drop(dropped, "code #{path} #{symbol}: not in that file") unless index

        line = index + 1
      end
      { "path" => path, "symbol" => symbol.empty? ? nil : symbol[0, 255], "line_start" => line,
        "note" => ref["note"].to_s.strip[0, 300], "role" => ref["role"].to_s }.reject { |_k, v| v.nil? || v == "" }
    end

    # "README.md:65" (that line exists) or "test/x.test.js > a test name".
    def check_cite(cite, file, dropped)
      cite = cite.is_a?(Hash) ? [cite["path"], cite["name"] || cite["line"]].compact.join(" > ") : cite.to_s.strip
      if (match = cite.match(/\A(.+?):(\d+)\z/))
        text = file.call(match[1])
        return cite if text && text.lines.size >= match[2].to_i
      elsif cite.include?(" > ")
        path, name = cite.split(/\s+>\s+/, 2)
        text = file.call(path)
        return cite if text&.include?(name)
      elsif file.call(cite)
        return cite
      end
      drop(dropped, "cite #{cite}: not found")
    end
  end

  # Test names in a test file: it("..."), test('...'), describe(`...`), rspec `it "..." do`,
  # Python `def test_x`, Go `func TestX`. For coverage rows when a handoff doesn't name tests.
  module TestNames
    CALL = /\b(?:it|test|specify|scenario)\s*\(?\s*(["'`])((?:(?!\1).){1,300})\1/
    DEF = /^\s*(?:async\s+)?def\s+(test_\w+)|^func\s+(Test\w+)/

    module_function

    def in(text)
      text = text.to_s
      (text.scan(CALL).map { |_q, name| name } + text.scan(DEF).flatten.compact).uniq.first(200)
    end
  end
end
