# frozen_string_literal: true

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
  #   ---
  class PlanFile
    Step = Data.define(:title, :body)

    ITEM = /\A {0,3}(?:[-*+]|\d+[.)])\s+(?:\[([ xX])\]\s+)?(.*)\z/
    FRONT_MATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)/m
    NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/

    attr_reader :title, :text, :steps, :meta

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

    def self.normalize(data)
      names = ->(value) { Array(value).map(&:to_s).map(&:strip).reject(&:empty?) }
      meta = {
        "title" => data["title"]&.to_s&.strip,
        "after" => names.call(data["after"]),
        "replaces" => names.call(data["replaces"]),
        "max_attempts" => data["max_attempts"]
      }
      bad = (meta["after"] + meta["replaces"]).grep_v(NAME)
      raise Error, "not a plan name in the front matter: #{bad.join(', ')}" if bad.any?
      if meta["max_attempts"] && !(meta["max_attempts"].is_a?(Integer) && meta["max_attempts"].positive?)
        raise Error, "max_attempts in the front matter must be a positive whole number"
      end

      meta.reject { |_key, value| value.nil? || value == "" }
    end

    HEADING = /\A(\#{1,6})\s+(.+?)\s*#*\s*\z/
    # Headings that name a unit of work: "Step 3: ...", "Phase 2 - ...", "Milestone 1", "4. ...".
    STEP_HEADING = /\A(?:\[[ xX]\]\s*)?(?:(?:step|phase|milestone|stage|part|task|sprint)\b\s*\d*|\d+[.):]?\s)/i
    CHECKED_HEADING = /\A\[[xX]\]\s*/

    # Steps from a document organized by headings ("### Step 1: ...", "## Phase 2 ..."): each
    # section under such a heading is one step, bullets included. The heading level with the
    # most step-like headings wins (the deeper one on a tie), so steps inside phases beat the
    # phases. Headings checked off ("### [x] Step 1") are skipped. Nil when fewer than two.
    def self.heading_steps(text)
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
        next if heading[:text].match?(CHECKED_HEADING)

        title = heading[:text].sub(CHECKED_HEADING, "").gsub(/[*_`]/, "").strip
        body = lines[heading[:index]...stop].join("\n").strip.sub(/\n+(?:-{3,}|\*{3,}|_{3,})\s*\z/, "")
        Step.new(title: title[0, 72], body:)
      end
      raise Error, "every step heading is already checked off" if steps.empty?

      steps
    end

    # Top-level list items become steps; indented lines under an item belong to it. Checked
    # items ("- [x] ...") are already done and skipped. Fewer than two items means "one step".
    def self.list_steps(text)
      items = []
      current = nil
      text.each_line(chomp: true) do |line|
        if (match = line.match(ITEM))
          current = { done: match[1].to_s.casecmp?("x"), lines: [match[2]] }
          items << current
        elsif current && (line.strip.empty? || line.start_with?("  ", "\t"))
          current[:lines] << line
        else
          current = nil
        end
      end
      return nil if items.size < 2

      open = items.reject { |item| item[:done] }
      raise Error, "every item in the task list is already checked off" if open.empty?

      open.map { |item| Step.new(title: item[:lines].first.strip[0, 72], body: item[:lines].join("\n").strip) }
    end

    def initialize(text, meta, list:)
      @text = text
      @meta = meta
      heading = text[/^\#{1,6}\s+(.+)$/, 1]
      first_line = text.lines.map(&:strip).find { |line| !line.empty? }
      @title = (meta["title"] || heading || first_line).sub(/\A(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/, "").strip[0, 72]
      steps = list ? (self.class.heading_steps(text) || self.class.list_steps(text)) : nil
      @steps = steps.nil? || steps.empty? ? [Step.new(title: @title, body: text.strip)] : steps
    end

    def multi_step? = steps.size > 1
  end
end
