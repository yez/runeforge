# frozen_string_literal: true

module Runeforge
  # What earlier steps left for this one, assembled from the ledger and the code index for one
  # role, within ledger.brief_chars: the step's requirements and their status, related work, a
  # code map with the best few chunks inline, the tests that already pin nearby behaviour, and
  # the project's facts. The full ranked map and its chunks also go to .runeforge/context/, for
  # the agent to open when the brief isn't enough. It's a starting point, never instructions:
  # the agent is told to trust the files over it.
  class Brief
    CONTEXT = "context"

    def initialize(env, task:, repo:, input:, workspace: nil)
      @env = env
      @task = task
      @repo = repo
      @input = input || {}
      @workspace = workspace
      @ledger = env.ledger
    end

    def budget = @env.config.dig("ledger", "brief_chars").to_i.then { |n| n.positive? ? n : 10_000 }

    def sha = @task[:base_sha]

    # The planner's brief, or nil when the ledger has nothing for it.
    def planner
      tickets = ensure_items
      return nil if tickets.empty?

      reqs = @ledger.requirements_of(tickets.map { |t| t[:id] })
      own = tickets.map { |t| t[:id] } + reqs.map { |r| r[:id] }
      sections = [header,
                  requirements_section(tickets, reqs),
                  related_section(own),
                  *code_sections(own),
                  coverage_section(own),
                  facts_section(ui: Prompts.ui_hint?(@input))]
      fit(sections.compact)
    end

    # The coder's: when it continues the planner's session it already has the code map, so only
    # what the planner couldn't know (UX findings, gotchas); otherwise the planner's brief.
    def coder(continuing:)
      if continuing
        facts = facts_section(ui: !@task[:ui_brief].to_s.strip.empty?, kinds: %w[gotcha ux command])
        return facts && fit([facts])
      end
      planner
    end

    # Earlier UX findings in this project, for the reviewer to check they aren't back.
    def ux
      rows = @ledger.facts.where(repo: @task[:repo], kind: "ux").order(Sequel.desc(:confirmations), Sequel.desc(:updated_at)).limit(6).all
      return nil if rows.empty?

      "## Earlier UX findings in this project\nCheck these aren't back:\n#{rows.map { |f| "- #{f[:text]}" }.join("\n")}"
    end

    private

    # The task's tickets: claimed when its inbox step started, or made now for any other task.
    def ensure_items
      tickets = @ledger.tickets_of(@task[:id])
      return tickets if tickets.any?

      @ledger.task_items!(@task, @input) ? @ledger.tickets_of(@task[:id]) : []
    end

    def header
      "## Brief from earlier steps\nRuneforge keeps what earlier steps learned about this project, as of commit " \
        "#{sha.to_s[0, 7]}. Start from what it names; open the files rather than searching, and trust a file " \
        "over this brief where they disagree. Use the requirement ids below in .runeforge/handoff.json."
    end

    def requirements_section(tickets, reqs)
      lines = tickets.flat_map do |ticket|
        mine = reqs.select { |r| r[:parent_id] == ticket[:id] }
        ["- #{@ledger.short_id(ticket[:id])} #{ticket[:title]}", *mine.map { |r| "  - #{@ledger.short_id(r[:id])} #{status_note(r)}#{r[:title]}" }]
      end
      "### This step's requirements\n#{lines.join("\n")}"
    end

    def status_note(item)
      case item[:status]
      when "done", "already_built" then "(already built: #{item[:close_reason]}) "
      when "conflict" then "(conflict: #{item[:close_reason].to_s[0, 120]}) "
      else @ledger.covered_item?(item) ? "(built by an earlier step, its tests pass) " : ""
      end
    end

    def related_section(own)
      rows = @ledger.related(own).reject { |item, _link| item[:kind] == "plan" }.first(12)
      return nil if rows.empty?

      lines = rows.map do |item, link|
        state = item[:status] == "open" ? "not built yet" : item[:status].tr("_", " ")
        reason = item[:close_reason] ? "; #{item[:close_reason]}" : ""
        "- #{link[:type]}: #{item[:id]} #{item[:title].to_s[0, 90]} (#{state}#{reason})#{link[:note] ? ". #{link[:note]}" : ''}"
      end
      "### Related work\nOther items that touch the same things. Don't build what another item owns; " \
        "build on what's done.\n#{lines.join("\n")}"
    end

    # The code map and the best chunks inline, from the code index; with no index, the ledger's
    # pointers alone.
    def code_sections(own)
      results = search(own)
      cards = cards_for(results)
      write_context(results, cards)
      return [refs_section(own)].compact if results.empty?

      lines = @env.config.dig("index", "map_lines").to_i.then { |n| n.positive? ? n : 20 }
      map = results.first(lines).map do |r|
        card = cards[[r.path, r.symbol]] || cards[[r.path, nil]]
        "- #{r.label}#{card ? ": #{card}" : ''}"
      end
      inline = @env.config.dig("index", "inline_chunks").to_i.then { |n| n.negative? ? 3 : n }
      code = results.first(inline).map { |r| "#{r.label}\n```\n#{r.text.rstrip[0, 1800]}\n```" }
      [
        "### Code map\nWhere this step's code most likely is (more in .runeforge/context/map.md):\n#{map.join("\n")}",
        code.any? ? "### The most relevant code\n#{code.join("\n\n")}" : nil
      ].compact
    end

    def search(own)
      index = @env.code_index
      return [] unless index.enabled?

      index.index!(@task[:repo], sha)
      anchors = own.flat_map { |id| @ledger.anchors_of(id) }.uniq
      boost = Hash.new { |h, k| h[k] = [] }
      related_ids = @ledger.related(own).map { |item, _| item[:id] }
      siblings = siblings_of(own)
      @ledger.refs_for(own + related_ids + siblings).each { |ref| boost[ref[:path]] << ref[:symbol] }
      query = [@input["title"], @input["description"]].compact.join("\n")
      index.search(@task[:repo], sha, query:, anchors:, boost: boost.to_h, limit: 30, ui: Prompts.ui_hint?(@input))
    rescue Git::CommandFailed, Sequel::Error => e
      warn "runeforge: code search for #{@task[:id]} failed: #{e.message}"
      []
    end

    # The earlier tickets of the same plan, whose code this step most often builds on.
    def siblings_of(own)
      parents = @ledger.items.where(id: own, kind: "ticket").select_map(:parent_id).compact.uniq
      @ledger.items.where(parent_id: parents).exclude(id: own).select_map(:id).then do |ids|
        ids + @ledger.items.where(parent_id: ids).select_map(:id)
      end
    end

    def cards_for(results)
      paths = results.map(&:path).uniq
      @ledger.refs.where(repo: @task[:repo], path: paths, stale: false).exclude(note: nil).all
             .each_with_object({}) { |ref, map| map[[ref[:path], ref[:symbol]]] ||= ref[:note] }
    end

    def refs_section(own)
      rows = @ledger.refs_for(own + @ledger.related(own).map { |item, _| item[:id] } + siblings_of(own)).first(15)
      return nil if rows.empty?

      "### Code map\n#{rows.map { |r| "- #{r[:path]}#{r[:line_start] ? ":#{r[:line_start]}" : ''}#{r[:symbol] ? " #{r[:symbol]}" : ''}#{r[:note] ? ": #{r[:note]}" : ''}" }.join("\n")}"
    end

    def coverage_section(own)
      ids = own + @ledger.related(own).map { |item, _| item[:id] } + siblings_of(own)
      rows = @ledger.coverage_for(ids).select { |c| c[:test_name] }.uniq { |c| [c[:test_path], c[:test_name]] }.first(15)
      return nil if rows.empty?

      lines = rows.map { |c| "- #{c[:test_path]} > #{c[:test_name]} (#{@ledger.short_id(c[:item_id])})" }
      "### Tests that already pin nearby behaviour\nLocked; don't test this behaviour again, and keep it passing:\n#{lines.join("\n")}"
    end

    def facts_section(ui:, kinds: nil)
      rows = @ledger.facts_for(@task[:repo], [@input["title"], @input["description"], @task[:title]].compact.join("\n"), ui:)
      rows = rows.select { |f| kinds.include?(f[:kind]) } if kinds
      return nil if rows.empty?

      lines = rows.map do |f|
        paths = JSON.parse(f[:paths] || "[]")
        "- [#{f[:kind]}] #{f[:text]}#{paths.any? ? " (#{paths.join(', ')})" : ''}"
      end
      "### What earlier steps learned\n#{lines.join("\n")}"
    end

    # Sections dropped first when the brief is over budget: the inline code, then the tests,
    # related work, facts and the map. The header and the requirements always stay.
    DROP_ORDER = ["### The most relevant code", "### Tests that", "### Related work", "### What earlier", "### Code map"].freeze

    def fit(sections)
      sections = sections.dup
      text = sections.join("\n\n")
      DROP_ORDER.each do |prefix|
        break if text.size <= budget

        sections.reject! { |section| section.start_with?(prefix) }
        text = sections.join("\n\n")
      end
      text.size > budget ? "#{text[0, budget - 20]}\n[brief cut short]" : text
    end

    # .runeforge/context/map.md and chunks/: the whole ranked list, beyond the brief's budget.
    def write_context(results, cards)
      return unless @workspace && results.any?

      map = results.map.with_index(1) do |r, i|
        card = cards[[r.path, r.symbol]] || cards[[r.path, nil]]
        "#{i}. #{r.label} (#{r.kind}; #{r.why.join(', ')})#{card ? "\n   #{card}" : ''}"
      end
      @workspace.write_meta(File.join(CONTEXT, "map.md"),
                            "# Code map for #{@task[:id]} at #{sha.to_s[0, 7]}\n\nRanked by how likely each chunk is to matter for this step; " \
                            "the files in chunks/ hold their source.\n\n#{map.join("\n")}\n")
      results.each_with_index do |r, i|
        name = format("%02d-%s.txt", i + 1, r.path.tr("/", "_")[0, 80])
        @workspace.write_meta(File.join(CONTEXT, "chunks", name), "#{r.label}\n\n#{r.text}")
      end
    rescue SystemCallError, Workspace::UnsafeFile => e
      warn "runeforge: couldn't write .runeforge/context for #{@task[:id]}: #{e.message}"
    end
  end
end
