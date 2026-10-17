# frozen_string_literal: true

require "digest"

module Runeforge
  # What each step is for and what earlier steps left for it, so one agent's work helps the next:
  #
  # - items: a plan, its tickets (one step each) and each ticket's requirements (its sub-bullets).
  # - links: how items relate (parent-child, blocks, duplicates, overlaps, extends, built-by,
  #   supersedes, discovered-from, conflicts-with), so a step never builds what another owns.
  # - anchors: the exact identifiers in an item's text (routes, data-testid values, paths, fields),
  #   which find duplicate and overlapping work without a model.
  # - claims: a requirement has one open owner (items.task_id); a step skips what's claimed or done.
  # - code refs, coverage and facts: which code does what, which tests pin which requirement, and
  #   what agents learned, from handoffs (see Handoff) and diffs, checked against git first.
  #
  # Only Runeforge writes here. Agents read the brief built from it (see Brief) and write
  # .runeforge/handoff.json; nothing an agent claims is kept until it's been checked.
  class Ledger
    OPEN = %w[open in_progress].freeze
    CLOSED = %w[done already_built superseded].freeze
    LINK_TYPES = %w[parent-child blocks duplicates overlaps built-by extends supersedes discovered-from conflicts-with related].freeze
    FACT_KINDS = %w[convention command layout gotcha ux].freeze
    REF_ROLES = %w[implements tests entrypoint helper fixture config].freeze

    attr_reader :db, :config

    def initialize(db, config)
      @db = db
      @config = config || {}
    end

    def enabled? = @config["enabled"] != false

    def items = db[:runeforge_items]

    def links = db[:runeforge_links]

    def anchors = db[:runeforge_anchors]

    def refs = db[:runeforge_code_refs]

    def coverage = db[:runeforge_coverage]

    def facts = db[:runeforge_facts]

    def find(id) = items.where(id: id.to_s).first

    # --- items from plans ------------------------------------------------------------------------

    # The plan's items: the plan, one ticket per PlanFile item and a requirement per sub-bullet
    # (or one for a ticket without any). Idempotent: a plan started again keeps its items.
    # Returns the ticket ids, in order. Also proposes links to other plans' items (see #relate!).
    def plan_items!(repo:, plan:, parsed:)
      return [] unless enabled?

      root = self.class.root_id(plan)
      upsert(id: root, repo:, plan_id: plan[:id], kind: "plan", title: parsed.title, body: nil, position: 0)
      tickets = parsed.items.each_with_index.map do |step, index|
        ticket = "#{root}.t#{index + 1}"
        upsert(id: ticket, repo:, plan_id: plan[:id], parent_id: root, kind: "ticket", title: step.title, body: step.body,
               position: index + 1)
        link!(repo:, from: ticket, to: root, type: "parent-child", by: "parser")
        link!(repo:, from: ticket, to: "#{root}.t#{index}", type: "blocks", by: "parser") if index.positive?
        self.class.requirements(step.body).each_with_index do |text, position|
          id = "#{ticket}.r#{position + 1}"
          upsert(id:, repo:, plan_id: plan[:id], parent_id: ticket, kind: "requirement", title: text.lines.first.to_s.strip[0, 120],
                 body: text, position: position + 1)
          link!(repo:, from: id, to: ticket, type: "parent-child", by: "parser")
          index_anchors!(repo, id, text)
        end
        index_anchors!(repo, ticket, step.body)
        ticket
      end
      JSON.parse(plan[:replaces] || "[]").each do |name|
        items.where(repo:, kind: "plan").where(Sequel.like(:id, "#{Build.slug(name)}-p%")).select_map(:id).each do |old|
          link!(repo:, from: root, to: old, type: "supersedes", by: "inbox")
        end
      end
      tickets.each { |ticket| relate!(repo, ticket) }
      tickets
    end

    # A plan's item id: "plan-d-money-p4", as its step tasks are named.
    def self.root_id(plan) = "#{Build.slug(plan[:name]).then { |s| s.empty? ? 'plan' : s }}-p#{plan[:id]}"

    # Items for a task that didn't come from an inbox plan (`runeforge build`, a ticket): one
    # ticket with its requirements, keyed by the task id. Returns the ticket id.
    def task_items!(task, input)
      return nil unless enabled?

      ticket = "#{task[:id]}.t1"
      return ticket if find(ticket)

      body = [input["title"], input["description"]].compact.join("\n")
      upsert(id: ticket, repo: task[:repo], kind: "ticket", title: input["title"] || task[:title], body:, position: 1)
      self.class.requirements(body).each_with_index do |text, position|
        id = "#{ticket}.r#{position + 1}"
        upsert(id:, repo: task[:repo], parent_id: ticket, kind: "requirement", title: text.lines.first.to_s.strip[0, 120],
               body: text, position: position + 1)
        link!(repo: task[:repo], from: id, to: ticket, type: "parent-child", by: "parser")
        index_anchors!(task[:repo], id, text)
      end
      index_anchors!(task[:repo], ticket, body)
      relate!(task[:repo], ticket)
      claim!(task[:repo], [ticket], task[:id])
      ticket
    end

    # A ticket's requirements: the text before its first sub-bullet, then each sub-bullet with
    # the lines under it. A ticket with neither is one requirement: its whole text.
    SUB_ITEM = /\A(\s+)(?:[-*+]|\d+[.)])\s+/

    def self.requirements(body)
      lines = body.to_s.lines(chomp: true)
      head = []
      parts = []
      indent = nil
      lines.drop(1).each do |line|
        match = line.match(SUB_ITEM)
        if match && (indent.nil? || match[1].size <= indent)
          indent ||= match[1].size
          parts << [line.strip]
        elsif parts.any?
          parts.last << line.strip
        else
          head << line.strip
        end
      end
      intro = ([lines.first.to_s.sub(/\A(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/, "").strip] + head).reject(&:empty?).join("\n")
      reqs = parts.map { |part| part.reject(&:empty?).join("\n").sub(/\A(?:[-*+]|\d+[.)])\s+/, "") }
      reqs.unshift(intro) if intro.lines.size > 1 || reqs.empty?
      reqs.reject(&:empty?)
    end

    # The ticket items a task builds, and their requirements.
    def tickets_of(task_id) = items.where(task_id: task_id.to_s, kind: "ticket").order(:position).all

    def requirements_of(ticket_ids) = items.where(parent_id: Array(ticket_ids), kind: "requirement").order(:parent_id, :position).all

    def children(id) = items.where(parent_id: id.to_s).order(:position).all

    # --- claims ----------------------------------------------------------------------------------

    # Gives the tickets (and their requirements) to the task. A ticket owned by a task that's
    # still running stays with it; one whose task failed or was cancelled can be claimed again.
    # Returns the ids claimed.
    def claim!(repo, ticket_ids, task_id)
      return [] unless enabled?

      claimed = []
      db.transaction do
        Array(ticket_ids).each do |id|
          row = find(id)
          next unless row
          next if row[:task_id] && row[:task_id] != task_id && active_task?(row[:task_id])

          ids = [id] + items.where(parent_id: id).select_map(:id)
          items.where(id: ids).exclude(status: CLOSED + ["conflict"]).update(task_id:, status: "in_progress", updated_at: Runeforge.now)
          items.where(id: ids, status: CLOSED).update(task_id:) if row[:task_id].nil?
          claimed << id
        end
      end
      claimed
    end

    # A step that failed gives its open items back, for the plan's retry to claim.
    def release!(task_id)
      return unless enabled?

      items.where(task_id: task_id.to_s, status: "in_progress").update(status: "open", updated_at: Runeforge.now)
    end

    # --- relationships -----------------------------------------------------------------------------

    # Anchors that say little because many items have them (`booking_id` in every ledger rule).
    COMMON = 0.3
    STRONG = %w[route testid path symbol].freeze

    # Links a new ticket and its requirements to other plans' items that share their anchors:
    # duplicates (nearly the same anchors), extends (overlaps finished work it says it changes),
    # or overlaps. Returns the links made.
    def relate!(repo, ticket_id)
      made = []
      own = [ticket_id] + items.where(parent_id: ticket_id).select_map(:id)
      plan = find(ticket_id)&.dig(:plan_id)
      total = [anchors.where(repo:).distinct.select(:item_id).count, 1].max
      kind_of = items.where(id: own).select_hash(:id, :kind)
      own.each do |id|
        mine = anchors.where(item_id: id).all
        next if mine.empty?

        common = mine.select { |a| anchors.where(repo:, kind: a[:kind], value: a[:value]).distinct.select(:item_id).count.to_f / total > COMMON && total >= 10 }
        useful = mine - common
        next if useful.empty?

        others = anchors.where(repo:, value: useful.map { |a| a[:value] }).exclude(item_id: own).all.group_by { |a| a[:item_id] }
        others.each do |other_id, shared|
          other = find(other_id)
          next unless other && other[:kind] == kind_of[id]
          next if plan && other[:plan_id] == plan

          strong = shared.count { |a| STRONG.include?(a[:kind]) }
          next if strong.zero? && shared.size < 3

          theirs = anchors.where(item_id: other_id).count
          overlap = shared.map { |a| a[:value] }.uniq.size.to_f / [useful.map { |a| a[:value] }.uniq.size, theirs].max
          text = find(id)[:body].to_s
          type = if overlap >= 0.6 && strong >= 1 then "duplicates"
                 elsif CLOSED.include?(other[:status]) && text.match?(/\b(?:chang|deliberately|instead|no longer|replac|now )/i) then "extends"
                 else "overlaps"
                 end
          note = "shares #{shared.map { |a| a[:value] }.uniq.first(4).join(', ')}"
          made << link!(repo:, from: id, to: other_id, type:, by: "anchors", note:)
        end
      end
      made.compact
    end

    def link!(repo:, from:, to:, type:, by:, note: nil)
      raise Error, "unknown link type #{type}" unless LINK_TYPES.include?(type)
      return nil if from == to
      return nil if links.where(from_id: from, to_id: to, type:).count.positive?

      links.insert(repo:, from_id: from, to_id: to, type:, created_by: by, note: note&.to_s&.[](0, 500), created_at: Runeforge.now)
      { from:, to:, type:, note: }
    end

    def links_of(id, types: nil)
      scope = links.where(Sequel.|({ from_id: id.to_s }, { to_id: id.to_s }))
      scope = scope.where(type: types) if types
      scope.order(:id).all
    end

    # Items related to these (their links, either way, except parent-child), as [item, link].
    def related(ids, types: LINK_TYPES - %w[parent-child blocks])
      ids = Array(ids)
      rows = links.where(type: types).where(Sequel.|({ from_id: ids }, { to_id: ids })).all
      rows.filter_map do |link|
        other = ids.include?(link[:from_id]) ? link[:to_id] : link[:from_id]
        next if ids.include?(other)

        (item = find(other)) && [item, link]
      end.uniq { |item, link| [item[:id], link[:type]] }
    end

    # --- anchors -----------------------------------------------------------------------------------

    ROUTE = %r{\b(GET|POST|PUT|PATCH|DELETE)\s+`?(/[^\s`'")]+)}
    TESTID = /data-testid=["'`]?([A-Za-z0-9_<>\-:.]+)/
    CODE = /`([^`\n]{2,120})`/

    # The exact identifiers in a piece of text, as [kind, value]: routes ("GET /api/x/:p"),
    # data-testid values, file paths, symbols (`createBooking`, `Foo::Bar`) and snake_case fields.
    def self.anchors(text)
      text = text.to_s
      found = text.scan(ROUTE).map { |verb, path| ["route", "#{verb} #{normalize_route(path)}"] }
      found += text.scan(TESTID).flatten.map { |id| ["testid", id.sub(/<.*\z/, "")] }
      text.scan(CODE).flatten.each do |code|
        code = code.strip
        next if code.match?(ROUTE)

        if code.match?(%r{\A[\w.-]+(?:/[\w.\-*]+)+\z}) || code.match?(/\A[\w-]+\.(?:rb|js|mjs|ts|tsx|jsx|py|go|rs|java|kt|swift|md|json|yml|yaml|css|html|erb|sql)\z/)
          found << (code.start_with?("/") ? ["route", normalize_route(code)] : ["path", code])
        elsif code.match?(/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)+\z/)
          found << ["field", code]
        elsif code.match?(/\A(?:[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*|[a-z]+[A-Z][A-Za-z0-9]*)(?:\(\))?\z/)
          found << ["symbol", code.delete_suffix("()")]
        end
      end
      found.uniq
    end

    def self.normalize_route(path) = path.sub(/[?#].*\z/, "").gsub(%r{/:[\w]+}, "/:p").gsub(%r{/<[^>]+>}, "/:p").delete_suffix("/")

    def anchors_of(id) = anchors.where(item_id: id.to_s).select_map(%i[kind value])

    # --- what steps hand on ------------------------------------------------------------------------

    # A planner's checked handoff (see Handoff#planner): its requirements' tests become coverage,
    # their code refs are kept, and requirements it marks conflict or already built say so.
    # A requirement id outside this step's tickets that it names with tests is coverage for that
    # item too (and a built-by link when it says already_built).
    def record_plan!(task, handoff, sha:)
      return unless enabled? && handoff

      own = owned_ids(task[:id])
      Array(handoff["requirements"]).each do |req|
        id = resolve(task, req["id"])
        next unless id

        Array(req["tests"]).each { |test| add_coverage(task[:repo], id, test["path"], test["name"]) }
        Array(req["code"]).each { |ref| add_ref(task, id, ref, source: "handoff", role: ref["role"] || "implements") }
        if req["status"] == "already_built" && !own.include?(id)
          link!(repo: task[:repo], from: id, to: tickets_of(task[:id]).first&.dig(:id) || task[:id], type: "built-by",
                by: "planner@#{task[:id]}", note: "the planner of #{task[:id]} found it built (#{sha.to_s[0, 7]})")
        end
      end
      record_facts!(task, handoff["facts"], by: "planner")
    end

    # A coder's checked handoff: where each requirement is implemented. Ids from other steps
    # become built-by links, verified when this step's tests pass at merge (see #close_step!).
    def record_code!(task, handoff)
      return unless enabled? && handoff

      own = owned_ids(task[:id])
      ticket = tickets_of(task[:id]).first&.dig(:id)
      Array(handoff["implemented"]).each do |entry|
        id = resolve(task, entry["id"])
        next unless id

        Array(entry["code"]).each { |ref| add_ref(task, id, ref, source: "handoff", role: "implements") }
        link!(repo: task[:repo], from: id, to: ticket, type: "built-by", by: "coder@#{task[:id]}") if ticket && !own.include?(id)
      end
      record_facts!(task, handoff["facts"], by: "coder")
    end

    # The step's requirements contradict documented or tested behaviour: they wait for a person.
    def conflict!(task, cites, reason)
      return unless enabled?

      ids = owned_ids(task[:id])
      items.where(id: ids).update(status: "conflict", close_reason: reason.to_s[0, 1000], updated_at: Runeforge.now)
      ids.each do |id|
        Array(cites).first(10).each { |cite| link!(repo: task[:repo], from: id, to: "cite:#{cite}"[0, 160], type: "conflicts-with", by: "planner@#{task[:id]}", note: cite) }
      end
    end

    # After a step merged (or was found already built): its items close, the code it changed
    # gets pointers, older pointers to files it changed go stale, every locked test that exists
    # at the merge passed there, and built-by claims backed by passing tests close their items.
    def close_step!(task, sha:, already: false, changed: [], test_names: {}, oids: {}, exists: ->(_path) { true })
      return unless enabled?

      status = already ? "already_built" : "done"
      reason = "#{already ? 'found already built' : 'built'} by #{task[:id]} (#{sha.to_s[0, 7]})"
      items.where(task_id: task[:id]).exclude(status: CLOSED + ["conflict"])
           .update(status:, closed_sha: sha, close_reason: reason, updated_at: Runeforge.now)
      ticket = tickets_of(task[:id]).first
      changed.each do |path|
        refs.where(repo: task[:repo], path:, stale: false).exclude(task_id: task[:id]).exclude(blob: oids[path]).update(stale: true)
        next if test_names.key?(path)

        add_ref(task, ticket&.dig(:id), { "path" => path }, source: "diff", role: "implements", oid: oids[path]) if ticket
      end
      test_names.each do |path, names|
        own_reqs = requirements_of(ticket&.dig(:id)).map { |r| r[:id] }
        target = own_reqs.empty? ? [ticket&.dig(:id)].compact : [ticket[:id]]
        target.each { |id| names.empty? ? add_coverage(task[:repo], id, path, nil) : names.each { |n| add_coverage(task[:repo], id, path, n) } }
      end
      # The suite passed on this commit before it merged, so every locked test that's in it passed.
      coverage.where(repo: task[:repo]).select_map(:test_path).uniq.each do |path|
        coverage.where(repo: task[:repo], test_path: path).update(last_passed_sha: sha) if exists.call(path)
      end
      # Built-by claims on later items, now that the code and tests they cite have passed.
      links.where(type: "built-by", to_id: ticket&.dig(:id).to_s).select_map(:from_id).each do |id|
        next unless coverage.where(item_id: id).exclude(last_passed_sha: nil).count.positive?

        items.where(id:, status: OPEN).update(status: "already_built", closed_sha: sha,
                                              close_reason: "built by #{task[:id]} (#{sha.to_s[0, 7]}), its tests pass",
                                              updated_at: Runeforge.now)
      end
      compact!(task[:repo])
    end

    # Whether every requirement this task owns is already built: closed by an earlier step, or
    # built by one with tests covering it that passed. Then the step needs no planner session.
    def covered?(task_id)
      reqs = items.where(task_id: task_id.to_s, kind: "requirement").all
      return false if reqs.empty?

      reqs.all? { |req| covered_item?(req) }
    end

    def covered_item?(item)
      return true if %w[done already_built].include?(item[:status]) && item[:task_id] != nil && item[:closed_sha]
      return false unless coverage.where(item_id: item[:id]).exclude(last_passed_sha: nil).count.positive?

      links.where(from_id: item[:id], type: %w[built-by duplicates]).count.positive?
    end

    # Why the task's requirements are covered, for the plan.done that skips its planner.
    def coverage_reason(task_id)
      reqs = items.where(task_id: task_id.to_s, kind: "requirement").all
      reqs.map do |req|
        by = links.where(from_id: req[:id], type: %w[built-by duplicates]).first
        tests = coverage.where(item_id: req[:id]).exclude(last_passed_sha: nil).limit(3).all
                        .map { |c| c[:test_name] ? "#{c[:test_path]} > #{c[:test_name]}" : c[:test_path] }
        "- #{short_id(req[:id])} #{req[:title]}: #{req[:close_reason] || "built by #{by&.dig(:to_id)}"}#{tests.any? ? "; tests: #{tests.join(', ')}" : ''}"
      end.join("\n")
    end

    # --- discovered work ---------------------------------------------------------------------------

    # Work agents found outside their step that can queue as a plan of its own, after these
    # checks: it has evidence (a path that exists, with a line, or a command); it isn't already
    # an item (by anchors, or nearly the same title); the step's plan wasn't itself discovered
    # work (no chains); and the plan hasn't queued max_discovered already. The rest are kept as
    # items that wait for a person. Returns [{title:, why:, evidence:, id:}] to queue.
    def discoveries!(task, found, plan_meta: {}, exists: ->(_path) { false })
      return [] unless enabled?

      ticket = tickets_of(task[:id]).first
      return [] unless ticket

      root = ticket[:parent_id] || ticket[:id]
      queued = items.where(repo: task[:repo], kind: "discovered", status: "open").where(Sequel.like(:id, "#{root}.d%")).count
      limit = @config.fetch("max_discovered", 3).to_i
      out = []
      Array(found).first(10).each_with_index do |entry, index|
        title = entry["title"].to_s.strip[0, 120]
        evidence = entry["evidence"].to_s.strip[0, 500]
        next if title.empty?

        path = evidence[%r{\A([\w./-]+?)(?::\d+)?(?:\s|\z)}, 1]
        has_evidence = (path && path.include?("/") || path.to_s.include?(".")) && exists.call(path) || evidence.match?(/\A`?[\w.\/-]+ .+/) && evidence.size > 10
        next unless has_evidence

        text = "#{title}\n#{entry['why']}\n#{evidence}"
        next if duplicate_discovery?(task[:repo], title, text)

        id = "#{root}.d#{Digest::SHA256.hexdigest(title)[0, 6]}"
        next if find(id)

        chain = plan_meta["discovered_from"].to_s.strip != ""
        can_queue = !chain && queued < limit
        upsert(id:, repo: task[:repo], plan_id: ticket[:plan_id], parent_id: root, kind: "discovered", title:,
               body: text[0, 2000], position: 100 + index, status: can_queue ? "open" : "blocked")
        items.where(id:).update(close_reason: chain ? "found by discovered work: waits for a person" : "over the limit of #{limit} per plan: waits for a person") unless can_queue
        index_anchors!(task[:repo], id, text)
        link!(repo: task[:repo], from: id, to: ticket[:id], type: "discovered-from", by: "#{entry['by'] || 'agent'}@#{task[:id]}", note: evidence)
        next unless can_queue

        queued += 1
        out << { title:, why: entry["why"].to_s[0, 1000], evidence:, id: }
      end
      out
    end

    def duplicate_discovery?(repo, title, text)
      words = Memory.words(title)
      found = Ledger.anchors(text).map(&:last)
      return true if found.any? && anchors.where(repo:, value: found).exclude(kind: "field").count.positive?

      items.where(repo:).exclude(kind: "plan").select_map(:title).any? do |other|
        theirs = Memory.words(other)
        shared = (words & theirs).size
        shared >= 3 && shared.to_f / [words.size, theirs.size].max >= 0.6
      end
    end

    # --- refs, coverage, facts ---------------------------------------------------------------------

    def add_ref(task, item_id, ref, source:, role:, oid: nil)
      path = ref["path"].to_s
      return if path.empty?

      role = REF_ROLES.include?(role) ? role : "implements"
      row = { repo: task[:repo], item_id:, task_id: task[:id], path:, symbol: ref["symbol"]&.to_s&.[](0, 255),
              line_start: ref["line_start"], line_end: ref["line_end"], role:, blob: oid || ref["blob"],
              note: ref["note"]&.to_s&.[](0, 300), source: }
      existing = refs.where(repo: task[:repo], item_id:, path:, symbol: row[:symbol]).first
      if existing
        refs.where(id: existing[:id]).update(row.compact.merge(stale: false))
      else
        refs.insert(row.merge(stale: false, created_at: Runeforge.now))
      end
    end

    def add_coverage(repo, item_id, path, name)
      return if path.to_s.empty?
      return if coverage.where(item_id:, test_path: path, test_name: name).count.positive?

      coverage.insert(repo:, item_id:, test_path: path, test_name: name, locked: true, created_at: Runeforge.now)
    end

    def refs_for(item_ids, include_stale: false)
      scope = refs.where(item_id: Array(item_ids))
      scope = scope.where(stale: false) unless include_stale
      scope.order(Sequel.desc(:id)).all
    end

    def coverage_for(item_ids) = coverage.where(item_id: Array(item_ids)).order(:test_path, :id).all

    # Upserts each fact by key: the same key from a later step replaces the text and counts as a
    # confirmation. Over max_facts, the least confirmed and least recently used go.
    def record_facts!(task, list, by:)
      Array(list).first(10).each do |fact|
        key = fact["key"].to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 100]
        text = fact["text"].to_s.strip[0, 400]
        kind = FACT_KINDS.include?(fact["kind"]) ? fact["kind"] : "convention"
        next if key.empty? || text.empty?

        fields = { kind:, text:, paths: JSON.generate(Array(fact["paths"]).grep(String).first(5)), source_task: task[:id],
                   created_by: by, updated_at: Runeforge.now }
        existing = facts.where(repo: task[:repo], key:).first
        if existing
          facts.where(id: existing[:id]).update(fields.merge(confirmations: existing[:confirmations] + 1))
        else
          facts.insert(fields.merge(repo: task[:repo], key:, confirmations: 1, created_at: Runeforge.now))
        end
      end
      prune_facts!(task[:repo])
    end

    def prune_facts!(repo)
      max = @config.fetch("max_facts", 200).to_i
      count = facts.where(repo:).count
      return if count <= max

      ids = facts.where(repo:).order(:confirmations, Sequel.asc(:last_used_at, nulls: :first), :id).limit(count - max).select_map(:id)
      facts.where(id: ids).delete
    end

    # Facts for a step: conventions, commands and layout first, then the gotchas and UX findings
    # that share its words. Marks them used.
    def facts_for(repo, query, ui: false, limit: 8)
      rows = facts.where(repo:).all
      return [] if rows.empty?

      terms = Memory.words(query)
      scored = rows.map do |row|
        shared = (terms & Memory.words("#{row[:key]} #{row[:text]} #{row[:paths]}")).size
        base = %w[convention command layout].include?(row[:kind]) ? 2 : 0
        base -= 3 if row[:kind] == "ux" && !ui
        [row, base + shared + (row[:confirmations] * 0.5)]
      end
      chosen = scored.select { |row, score| score >= 2 || %w[convention command].include?(row[:kind]) }
                     .sort_by { |row, score| [-score, -row[:id]] }.first(limit).map(&:first)
      facts.where(id: chosen.map { |row| row[:id] }).update(last_used_at: Runeforge.now) if chosen.any?
      chosen
    end

    # A UX reviewer's findings, kept as facts so the next step's coder sees them first time.
    def record_ux!(task, issues)
      list = Array(issues).first(10).map do |issue|
        { "key" => "ux-#{Digest::SHA256.hexdigest(issue['problem'].to_s)[0, 10]}", "kind" => "ux",
          "text" => "#{issue['screen'].to_s.empty? ? '' : "#{issue['screen']}: "}#{issue['problem']}#{issue['fix'].to_s.empty? ? '' : " Fix: #{issue['fix']}"}" }
      end
      record_facts!(task, list, by: "ux_reviewer")
    end

    # --- compaction --------------------------------------------------------------------------------

    # Closed items of plans more than compact_after_plans back keep their title, close reason,
    # anchors, links and pointers; their text goes (the plan file in runeforge/done/ has it).
    def compact!(repo)
      keep = @config.fetch("compact_after_plans", 3).to_i
      plan_ids = items.where(repo:, kind: "plan").exclude(plan_id: nil).order(Sequel.desc(:plan_id)).select_map(:plan_id).uniq
      old = plan_ids.drop(keep)
      return if old.empty?

      items.where(repo:, plan_id: old, status: CLOSED, compacted_at: nil).exclude(kind: "plan")
           .update(body: nil, compacted_at: Runeforge.now)
    end

    # --- helpers -----------------------------------------------------------------------------------

    # "t2.r3" within the task's plan, or a full id. Nil for an id the ledger doesn't know.
    def resolve(task, id)
      id = id.to_s.strip
      return nil if id.empty?
      return id if find(id)

      ticket = tickets_of(task[:id]).first
      root = ticket && (ticket[:parent_id] || ticket[:id].sub(/\.t\d+\z/, ""))
      candidates = [root && "#{root}.#{id}", ticket && "#{ticket[:id]}.#{id}"].compact
      candidates.find { |candidate| find(candidate) }
    end

    # "plan-d-money-p4.t2.r3" -> "t2.r3".
    def short_id(id) = id.to_s[/\.(t\d+(?:\.[rd]\w+)?)\z/, 1] || id.to_s

    def owned_ids(task_id) = items.where(task_id: task_id.to_s).select_map(:id)

    private

    def upsert(id:, repo:, kind:, title:, body:, position:, plan_id: nil, parent_id: nil, status: "open")
      now = Runeforge.now
      if (row = find(id))
        fields = { title: title.to_s[0, 500], position: }
        fields[:body] = body unless row[:compacted_at]
        items.where(id:).update(fields.merge(updated_at: now))
      else
        items.insert(id:, repo:, plan_id:, parent_id:, kind:, title: title.to_s[0, 500], body:, position:, status:,
                     created_at: now, updated_at: now)
      end
    end

    def index_anchors!(repo, id, text)
      anchors.where(item_id: id).delete
      self.class.anchors(text).first(60).each do |kind, value|
        anchors.insert(repo:, item_id: id, kind:, value: value[0, 500])
      end
    end

    def active_task?(task_id)
      task = db[:runeforge_tasks].where(id: task_id).first
      task && !%w[failed cancelled].include?(task[:status])
    end
  end
end
