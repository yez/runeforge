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
      steps = list ? self.class.list_steps(text) : nil
      @steps = steps.nil? || steps.empty? ? [Step.new(title: @title, body: text.strip)] : steps
    end

    def multi_step? = steps.size > 1
  end
end
