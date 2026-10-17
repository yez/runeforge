# frozen_string_literal: true

require "digest"
require "yaml"

module Runeforge
  # A markdown plan: a prompt, a file given to `runeforge build`, or a file in a project's
  # runeforge/inbox/. A task list runs as one step per unchecked item; anything else is one step.
  #
  # Inbox plans may start with YAML front matter:
  #
  #   ---
  #   title: CSV export
  #   after: reports-page       # wait until that plan is done
  #   replaces: csv-export-v1   # unlock that plan's acceptance tests
  #   max_attempts: 3
  #   steps: auto               # how many tasks the steps become (see .group)
  #   ---
  class PlanFile
    Step = Data.define(:title, :body) do
      # Identifies the step across runs, so a build run again (or resumed) knows which steps an
      # earlier run finished. Checking a step off, or re-indenting it, keeps its key.
      def key = PlanFile.step_key(body)
    end

    def self.step_key(body)
      normalized = body.to_s.gsub(/\[[ xX]\]\s*/, "").gsub(/\s+/, " ").strip.downcase
      Digest::SHA256.hexdigest(normalized)[0, 16]
    end

    ITEM = /\A {0,3}(?:[-*+]|\d+[.)])\s+(?:\[([ xX])\]\s+)?(.*)\z/
    FRONT_MATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)/m
    NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/

    # checked_steps: the steps already checked off in the text, which don't run but whose tests
    # stay locked (see BuildProgress).
    attr_reader :title, :text, :steps, :meta, :checked_steps

    # list: false treats the whole text as one step (a prompt typed on the command line).
    def self.parse(text, list: true, source: "plan")
      meta, body = front_matter(text.to_s)
      raise Error, "nothing to build: the #{source} is empty" if body.strip.empty?

      new(body, meta, list:)
    end

    def self.front_matter(text)
      match = text.match(FRONT_MATTER)
      return [{}, text] unless match

      data = YAML.safe_load(match[1]) || {}
      raise Error, "the plan's front matter must be a YAML mapping" unless data.is_a?(Hash)

      [normalize(data), text[match[0].length..]]
    rescue Psych::SyntaxError => e
      raise Error, "the plan's front matter is not valid YAML: #{e.message}"
    end

    # discovered_from: written by Runeforge on a plan it queued from work an agent found (see
    # Ledger#discoveries); such a plan's own findings wait for a person instead of queueing.
    KEYS = %w[title after replaces max_attempts steps ux_review discovered_from].freeze
    # The keys people write (discovered_from is Runeforge's own).
    PUBLIC_KEYS = (KEYS - %w[discovered_from]).freeze
    # ux_review: auto (the planner decides whether a step changes the UI), always or never.
    UX_REVIEW = %w[auto always never].freeze
    # Names people reach for that no spell checker would map to the real key.
    SYNONYMS = { "retries" => "max_attempts", "retry" => "max_attempts", "attempts" => "max_attempts",
                 "depends_on" => "after", "depends" => "after", "needs" => "after", "supersedes" => "replaces" }.freeze

    def self.normalize(data)
      names = ->(value) { Array(value).map(&:to_s).map(&:strip).reject(&:empty?) }
      meta = {
        "title" => data["title"]&.to_s&.strip,
        "after" => names.call(data["after"]),
        "replaces" => names.call(data["replaces"]),
        "max_attempts" => data["max_attempts"],
        "steps" => data["steps"].is_a?(String) ? data["steps"].strip.downcase : data["steps"],
        "ux_review" => ux_review(data["ux_review"]),
        "discovered_from" => data["discovered_from"]&.to_s&.strip
      }
      bad = (meta["after"] + meta["replaces"]).grep_v(NAME)
      raise Error, "not a plan name in the front matter: #{bad.join(', ')}" if bad.any?
      if meta["max_attempts"] && !(meta["max_attempts"].is_a?(Integer) && meta["max_attempts"].positive?)
        raise Error, "max_attempts in the front matter must be a positive whole number"
      end
      unless meta["steps"].nil? || %w[auto each].include?(meta["steps"]) || (meta["steps"].is_a?(Integer) && meta["steps"].positive?)
        raise Error, "steps in the front matter must be auto, each, or a positive whole number"
      end

      unless meta["ux_review"].nil? || UX_REVIEW.include?(meta["ux_review"])
        raise Error, "ux_review in the front matter must be auto, always or never"
      end

      meta.reject { |_key, value| value.nil? || value == "" }.merge("warnings" => unknown_keys(data.keys)).reject { |_k, v| v == [] }
    end

    # YAML reads `ux_review: yes` as true; true and false mean always and never.
    def self.ux_review(value)
      case value
      when true then "always"
      when false then "never"
      when nil then nil
      else value.to_s.strip.downcase
      end
    end

    # A misspelled key would otherwise be dropped without a word (`retries: 3` sets nothing).
    def self.unknown_keys(keys)
      (keys.map(&:to_s) - KEYS).map do |key|
        suggestion = SYNONYMS[key.downcase] || DidYouMean::SpellChecker.new(dictionary: PUBLIC_KEYS).correct(key).first
        "unknown front matter key `#{key}` (ignored)#{suggestion ? "; did you mean `#{suggestion}`?" : "; known keys: #{PUBLIC_KEYS.join(', ')}"}"
      end
    end

    HEADING = /\A(\#{1,6})\s+(.+?)\s*#*\s*\z/
    # Headings that name a unit of work: "Step 3: ...", "Phase 2 - ...", "Milestone 1", "4. ...".
    STEP_HEADING = /\A(?:\[[ xX]\]\s*)?(?:(?:step|phase|milestone|stage|part|task|sprint)\b\s*\d*|\d+[.):]?\s)/i
    CHECKED_HEADING = /\A\[[xX]\]\s*/

    # Steps from a document organized by headings ("### Step 1: ...", "## Phase 2 ..."): each
    # section under such a heading is one step, bullets included. The heading level with the
    # most step-like headings wins (the deeper one on a tie), so steps inside phases beat the
    # phases. Headings checked off ("### [x] Step 1") are skipped. Nil when fewer than two.
    def self.heading_steps(text, checked: [])
      headings = []
      fence = false
      lines = text.lines(chomp: true)
      lines.each_with_index do |line, index|
        fence = !fence if line.lstrip.start_with?("```", "~~~")
        next if fence || !(match = line.match(HEADING))

        headings << { index:, level: match[1].size, text: match[2].strip }
      end
      levels = headings.select { |h| h[:text].match?(STEP_HEADING) }.group_by { |h| h[:level] }
      level, chosen = levels.max_by { |lvl, list| [list.size, lvl] }
      return nil if chosen.nil? || chosen.size < 2

      steps = chosen.filter_map do |heading|
        stop = headings.find { |h| h[:index] > heading[:index] && h[:level] <= level }&.dig(:index) || lines.size
        title = heading[:text].sub(CHECKED_HEADING, "").gsub(/[*_`]/, "").strip
        body = lines[heading[:index]...stop].join("\n").strip.sub(/\n+(?:-{3,}|\*{3,}|_{3,})\s*\z/, "")
        step = Step.new(title: title[0, 72], body:)
        if heading[:text].match?(CHECKED_HEADING)
          checked << step
          next
        end

        step
      end
      raise Error, "every step heading is already checked off" if steps.empty?

      steps
    end

    # Top-level list items become steps; indented lines under an item belong to it, nested list
    # items included ("  - a sub-bullet" is part of its ticket, not a step of its own). The first
    # item's indent is the top level. Checked items ("- [x] ...") are already done and skipped.
    # Fewer than two items means "one step".
    def self.list_steps(text, checked: [])
      items = []
      current = nil
      top = nil
      text.each_line(chomp: true) do |line|
        indent = line[/\A[ \t]*/].gsub("\t", "    ").size
        match = line.match(ITEM)
        if match && (top.nil? || indent <= top)
          top ||= indent
          current = { done: match[1].to_s.casecmp?("x"), lines: [match[2]] }
          items << current
        elsif current && (line.strip.empty? || indent > top.to_i)
          current[:lines] << line
        else
          current = nil
        end
      end
      return nil if items.size < 2

      steps = items.map { |item| [item[:done], Step.new(title: item[:lines].first.strip[0, 72], body: item[:lines].join("\n").strip)] }
      checked.concat(steps.select(&:first).map(&:last))
      open = steps.reject(&:first).map(&:last)
      raise Error, "every item in the task list is already checked off" if open.empty?

      open
    end

    # Joins consecutive steps into tasks. mode: "auto" or "each" (the default: one task per step,
    # so each task has one ticket's deliverable and the ledger tracks it on its own), or a whole
    # number N (at most N tasks, as even as they can be, in order).
    def self.group(steps, mode)
      group_indexes(steps.size, mode).map do |indexes|
        part = steps.values_at(*indexes)
        next part.first if part.size == 1

        head = part.first.title
        more = " (+#{part.size - 1} more)"
        title = head.size + more.size > 72 ? "#{head[0, 71 - more.size]}…#{more}" : "#{head}#{more}"
        Step.new(title:, body: part.map(&:body).join("\n\n"))
      end
    end

    # Which of the plan's items (its tickets, in order) each task builds: [[0], [1], [2]], or
    # [[0, 1], [2]] with steps: 2.
    def self.group_indexes(size, mode)
      count = mode.is_a?(Integer) ? [mode, size].min : size
      return Array.new(size) { |index| [index] } if count >= size

      per, extra = size.divmod(count)
      start = 0
      Array.new(count) do |index|
        length = per + (index < extra ? 1 : 0)
        (start...(start + length)).to_a.tap { start += length }
      end
    end

    def initialize(text, meta, list:)
      @text = text
      @meta = meta
      heading = text[/^\#{1,6}\s+(.+)$/, 1]
      first_line = text.lines.map(&:strip).find { |line| !line.empty? }
      @title = (meta["title"] || heading || first_line).sub(/\A(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/, "").strip[0, 72]
      checked = []
      steps = list ? (self.class.heading_steps(text, checked:) || self.class.list_steps(text, checked: checked.clear)) : nil
      @checked_steps = steps.nil? || steps.empty? ? [] : checked
      # items: the plan's tickets before steps: N groups them; step_items: which items each step has.
      @items = steps.nil? || steps.empty? ? [Step.new(title: @title, body: text.strip)] : steps
      @step_items = self.class.group_indexes(@items.size, meta["steps"] || "auto")
      @steps = steps.nil? || steps.empty? ? @items : self.class.group(steps, meta["steps"] || "auto")
    end

    attr_reader :items, :step_items

    def multi_step? = steps.size > 1

    def warnings = meta.fetch("warnings", [])
  end
end
