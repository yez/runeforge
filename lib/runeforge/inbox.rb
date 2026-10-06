# frozen_string_literal: true

module Runeforge
  # Plans committed to a project's runeforge/inbox/ become tasks, one plan per repository at a time,
  # in the order they arrived on the base branch. See docs/plans/inbox.md.
  #
  # - Only committed files on the base branch count. Arrival is the first-parent position of the
  #   commit that added the file (renames keep it); edits keep a plan's place, while a failed plan
  #   that's edited goes to the back. Filenames only break ties.
  # - Each unchecked task-list item is its own task, branch and merge (one shared runeforge/inbox
  #   branch with manual_merge). The integrator moves the finished plan to runeforge/done/.
  # - A plan that finished without being merged pauses its repository's queue until the work
  #   lands or the plan is removed from the inbox.
  #
  # The supervisor calls #poll every inbox.poll_seconds. Every state change is a plan.<status> event.
  class Inbox
    DIR = "runeforge"
    INBOX = "runeforge/inbox"
    DONE = "runeforge/done"
    SHARED_BRANCH = "runeforge/inbox"
    WAITING = %w[queued blocked].freeze
    ACTIVE = %w[queued blocked running unmerged].freeze

    README = <<~MD
      # Runeforge inbox

      Commit a markdown plan to `inbox/` and Runeforge builds it: plans run one at a time, in the
      order they arrived on this branch (not by file name). A task list runs one task per unchecked
      item; any other file is one task. Finished plans move to `done/` with a short summary.

      Optional front matter:

      ```markdown
      ---
      title: CSV export
      after: reports-page      # wait until inbox/reports-page.md is done
      replaces: csv-export-v1  # unlock that plan's acceptance tests, to change or reverse it
      max_attempts: 3
      ---
      ```

      - Edit a queued plan and it keeps its place; edit a running one and it restarts.
      - Edit a failed plan to try again (it goes to the back of the queue).
      - Delete a plan to drop or cancel it.
      - Coding agents can't change anything in this folder.

      `runeforge inbox` shows the queue. Background workers (`runeforge up`) build the plans.
    MD

    # The files a project starts with.
    def self.scaffold = { "#{DIR}/README.md" => README, "#{INBOX}/.gitkeep" => "", "#{DONE}/.gitkeep" => "" }

    def self.plan_path?(path)
      path.start_with?("#{INBOX}/") && path.end_with?(".md") && !File.basename(path).casecmp?("README.md") &&
        !File.basename(path).start_with?(".")
    end

    def self.plan_name(path) = File.basename(path, ".md")

    attr_reader :env

    def initialize(env)
      @env = env
    end

    def plans = env.db[:runeforge_plans]

    def manual?(repo_name) = env.manual_merge?(repo_name)

    # Checks every registered repository. Returns the errors, one per repository that failed.
    def poll
      env.repos.list.filter_map do |repo|
        poll_repo(repo[:name])
        nil
      rescue Error => e
        "#{repo[:name]}: #{e.message}"
      end
    end

    def poll_repo(name)
      repo = env.repos.fetch(name)
      base = env.repos.refresh(name)
      entries = scan(name, base)
      sync(repo, entries)
      advance(repo, base, entries)
    end

    # The repository's plans in queue order: what's running, then waiting, then the rest.
    def queue(name)
      rank = { "running" => 0, "unmerged" => 1, "queued" => 2, "blocked" => 2 }
      plans.where(repo: name.to_s).exclude(status: "superseded").all
           .sort_by { |p| [rank.fetch(p[:status], 3), rank.key?(p[:status]) ? p[:arrival] : -p[:id], p[:path]] }
    end

    # --- reading the inbox ---------------------------------------------------------------------

    # path => { blob:, arrival:, updated: } for every plan file on the base branch.
    def scan(name, base)
      blobs = env.repos.files(name, base, INBOX).select { |path, _| self.class.plan_path?(path) }
      return {} if blobs.empty?

      positions, count = history(name, base)
      blobs.to_h do |path, blob|
        [path, { blob:, **positions.fetch(path, { arrival: count, updated: count }) }]
      end
    end

    # Walks the base branch's first-parent history of the inbox once, oldest first, giving each
    # file the position of the commit that added it (following renames) and of its latest change.
    def history(name, base)
      log = Git.run("-c", "core.quotePath=false", "log", "--first-parent", "--diff-merges=first-parent", "--reverse",
                    "-M", "--name-status", "--format=@@%H", base, "--", INBOX, dir: env.repos.path(name))
      positions = {}
      index = 0
      log.each_line(chomp: true) do |line|
        next index += 1 if line.start_with?("@@")
        next if line.empty?

        status, *paths = line.split("\t")
        case status[0]
        when "A", "C" then positions[paths.last] ||= { arrival: index, updated: index }
        when "M", "T" then (positions[paths.last] ||= { arrival: index, updated: index })[:updated] = index
        when "D" then positions.delete(paths.last)
        when "R"
          moved = positions.delete(paths.first) || { arrival: index }
          positions[paths.last] = moved.merge(updated: index)
        end
      end
      [positions, index + 1]
    end

    # --- recording plan versions -----------------------------------------------------------------

    def sync(repo, entries)
      name = repo[:name]
      rows = plans.where(repo: name).all
      active = rows.select { |row| ACTIVE.include?(row[:status]) }

      # A plan moved to a new path, unchanged, is the same plan.
      gone = active.reject { |row| entries.key?(row[:path]) }
      entries.each do |path, entry|
        next if rows.any? { |row| row[:path] == path }

        renamed = gone.find { |row| row[:blob] == entry[:blob] && WAITING.include?(row[:status]) }
        next unless renamed

        update(renamed, path:, name: self.class.plan_name(path))
        gone.delete(renamed)
        rows.find { |row| row[:id] == renamed[:id] }[:path] = path
      end

      entries.each { |path, entry| record(repo, path, entry, rows) }
      gone.each { |row| removed(row) }
    end

    def record(repo, path, entry, rows)
      same = rows.find { |row| row[:path] == path && row[:blob] == entry[:blob] }
      return if same && same[:status] != "superseded"

      previous = rows.select { |row| row[:path] == path && row[:id] != same&.dig(:id) }.max_by { |row| row[:id] }
      arrival =
        case previous&.dig(:status)
        when "queued", "blocked", "running" then previous[:arrival] # edited: keeps its place
        when nil then entry[:arrival]
        else entry[:updated] # edited after failing, or a new plan at a finished plan's path
        end
      if previous && %w[queued blocked running].include?(previous[:status])
        cancel_task(previous, "the plan was edited; restarting with the new version") if previous[:status] == "running"
        update(previous, status: "superseded", reason: "replaced by a newer version")
      end

      fields = { arrival:, updated: entry[:updated], status: "queued", reason: nil, step: 0, steps: nil, task_id: nil,
                 task_ids: "[]", waiting_sha: nil }
      fields.merge!(front_matter(repo[:name], entry[:blob]))
      if same
        update(same, **fields)
      else
        now = Runeforge.now
        id = plans.insert(repo: repo[:name], path:, name: self.class.plan_name(path), blob: entry[:blob],
                          created_at: now, updated_at: now, **fields)
        emit(plans.where(id:).first)
      end
    end

    def front_matter(name, blob)
      parsed = PlanFile.parse(env.repos.blob(name, blob), source: "plan")
      { title: parsed.title, after: JSON.generate(parsed.meta.fetch("after", [])),
        replaces: JSON.generate(parsed.meta.fetch("replaces", [])) }
    rescue Error => e
      { title: nil, after: "[]", replaces: "[]", status: "failed", reason: e.message }
    end

    def removed(row)
      case row[:status]
      when "queued", "blocked" then update(row, status: "dropped", reason: "removed from the inbox")
      when "running"
        # Its own move to done/ landed with the last step's merge; #advance will finish it.
        task = row[:task_id] && env.tasks.find(row[:task_id])
        return if task && (task[:merged_sha] || task[:status] == "done")

        cancel_task(row, "the plan was removed from the inbox")
        update(row, status: "cancelled", reason: "removed from the inbox")
      end
      # Unmerged plans are settled in #advance: removal there means the work landed or was given up.
    end

    # --- running plans ---------------------------------------------------------------------------

    def advance(repo, base, entries)
      name = repo[:name]
      running = plans.where(repo: name, status: "running").first
      return progress(repo, running, base) if running

      paused = plans.where(repo: name, status: "unmerged").order(:arrival).first
      if paused
        return block_waiting(name, "waiting for #{paused[:name]} to be merged") unless settle(repo, paused, base, entries)
        return if plans.where(repo: name, status: "running").any?
      end
      start_next(repo, base)
    end

    def progress(repo, plan, base)
      task = env.tasks.find(plan[:task_id])
      return update(plan, status: "failed", reason: "its task #{plan[:task_id]} is missing") unless task

      case task[:status]
      when "done" then step_done(repo, plan, task, base)
      when "failed", "cancelled", "blocked"
        update(plan, status: "failed", reason: "#{task[:id]} #{task[:status]}: #{task[:error]}")
      end
    end

    def step_done(repo, plan, task, base)
      unless manual?(repo[:name]) || task[:merged_sha]
        update(plan, status: "unmerged", step: plan[:step] + 1, waiting_sha: task[:head_sha],
                     reason: "not merged into #{repo[:base_branch]}; the work is on #{task[:branch]}")
        return block_waiting(repo[:name], "waiting for #{plan[:name]} to be merged")
      end

      continue(repo, update(plan, step: plan[:step] + 1), base)
    end

    # An unmerged plan is settled once its work has landed (however it was merged) or it was
    # removed from the inbox. Returns true when the queue can move again.
    def settle(repo, plan, base, entries)
      landed = env.repos.landed?(repo[:name], plan[:waiting_sha], base:)
      return false unless landed || !entries.key?(plan[:path])

      continue(repo, plan, base, removed: !landed)
      true
    end

    # After a step: the next step, or the plan is finished. `removed`: the plan left the inbox
    # while its work was still unmerged, so it's given up.
    def continue(repo, plan, base, removed: false)
      if removed
        update(plan, status: "dropped", waiting_sha: nil, reason: "removed from the inbox before its work was merged")
      elsif plan[:step] >= plan[:steps].to_i
        update(plan, status: "done", waiting_sha: nil, reason: nil, locked: own_locked(plan))
      else
        start_step(repo, update(plan, waiting_sha: nil), base)
      end
    end

    def start_next(repo, base)
      name = repo[:name]
      finished = plans.where(repo: name, status: "done").select_map(:name)
      plans.where(repo: name, status: WAITING).order(:arrival, :path).all.each do |plan|
        waiting = JSON.parse(plan[:after] || "[]") - finished
        if waiting.any?
          update(plan, status: "blocked", reason: "waiting on #{waiting.join(', ')}")
          next
        end
        # Another supervisor may have started it; only one wins.
        next unless plans.where(id: plan[:id], status: WAITING).update(status: "running", updated_at: Runeforge.now).positive?

        start_plan(repo, plan, base) # the row as it was, so the change to running is recorded
        break
      end
    end

    def start_plan(repo, plan, base)
      parsed = parsed(repo[:name], plan)
      update(plan, status: "running", steps: parsed.steps.size, step: 0, reason: nil,
                   inherited: JSON.generate(carried_tests(repo, plan, base).keys))
      start_step(repo, plans.where(id: plan[:id]).first, base)
    rescue Error => e
      done = e.message.include?("already checked off")
      update(plan, status: done ? "done" : "failed", reason: done ? "every item was already checked off" : e.message)
    end

    def start_step(repo, plan, base)
      name = repo[:name]
      parsed = parsed(name, plan)
      step = parsed.steps.fetch(plan[:step])
      multi = parsed.multi_step?
      branch, start = branch_and_base(name, plan, multi, base)
      id = "#{Build.slug(plan[:name]).then { |s| s.empty? ? 'plan' : s }}-p#{plan[:id]}#{multi ? "-s#{plan[:step] + 1}" : ''}"
      budgets = env.config["budgets"]
      task = env.tasks.find(id) || env.tasks.create(
        id:, workflow: "inbox", repo: name, base_sha: start, branch:, title: multi ? step.title : parsed.title,
        mailbox: env.mailbox("inbox"), locked_paths: carried_tests(repo, plan, start),
        input: {
          "title" => multi ? step.title : parsed.title, "description" => step.body,
          "context" => (multi ? parsed.text : nil), "step" => (multi ? "#{plan[:step] + 1} of #{parsed.steps.size}" : nil),
          "queued" => queued_titles(name, plan),
          "plan" => { "id" => plan[:id], "path" => plan[:path], "name" => plan[:name],
                      "last" => plan[:step] + 1 == parsed.steps.size }
        }.compact,
        max_attempts: parsed.meta["max_attempts"] || budgets["max_attempts"], token_budget: budgets["token_budget"],
        deadline_at: budgets["max_task_minutes"] && (Runeforge.now + (budgets["max_task_minutes"] * 60))
      )
      ids = (JSON.parse(plan[:task_ids] || "[]") + [task[:id]]).uniq
      update(plan, status: "running", task_id: task[:id], task_ids: JSON.generate(ids), reason: nil)
    end

    # Merging: each step gets its own branch off the current base. manual_merge: every plan stacks
    # on one shared branch, which starts over from the base once everything on it has landed.
    def branch_and_base(name, plan, multi, base)
      unless manual?(name)
        suffix = multi ? "-s#{plan[:step] + 1}" : ""
        return ["runeforge/#{Build.slug(plan[:name])}-p#{plan[:id]}#{suffix}", base]
      end

      tip = env.repos.branch_sha(name, SHARED_BRANCH)
      [SHARED_BRANCH, tip && !env.repos.landed?(name, tip, base:) ? tip : base]
    end

    # Acceptance tests locked by finished plans (and by this plan's earlier steps), pinned to what
    # they are at `sha` now, minus the tests of plans this one replaces.
    def carried_tests(repo, plan, sha)
      name = repo[:name]
      replaced = JSON.parse(plan[:replaces] || "[]")
      paths = plans.where(repo: name, status: "done").exclude(name: replaced).select_map(:locked)
                   .flat_map { |json| JSON.parse(json || "[]") }
      if plan[:task_id] && (previous = env.tasks.find(plan[:task_id]))
        paths += JSON.parse(previous[:locked_paths] || "{}").keys
      end
      paths.uniq.filter_map { |path| (oid = env.repos.oid(name, sha, path)) && [path, oid] }.to_h
    end

    # The tests this plan locked itself: everything its last task locked, minus what it inherited.
    def own_locked(plan)
      task = plan[:task_id] && env.tasks.find(plan[:task_id])
      return plan[:locked] unless task

      JSON.generate(JSON.parse(task[:locked_paths] || "{}").keys - JSON.parse(plan[:inherited] || "[]"))
    end

    def queued_titles(name, plan)
      plans.where(repo: name, status: WAITING).exclude(id: plan[:id]).order(:arrival).limit(20)
           .select_map(%i[name title]).map { |plan_name, title| "#{title || plan_name} (#{plan_name})" }
    end

    def parsed(name, plan) = PlanFile.parse(env.repos.blob(name, plan[:blob]), source: "plan")

    def block_waiting(name, reason)
      plans.where(repo: name, status: WAITING).all.each { |plan| update(plan, status: "blocked", reason:) }
      nil
    end

    def cancel_task(plan, reason)
      env.tasks.cancel(plan[:task_id], reason:) if plan[:task_id]
    rescue Error
      nil # already finished
    end

    # Updates a plan and records a plan.<status> event when its status or reason changed.
    def update(plan, **fields)
      changed = fields.any? { |key, value| plan[key] != value }
      return plan unless changed

      plans.where(id: plan[:id]).update(fields.merge(updated_at: Runeforge.now))
      fresh = plans.where(id: plan[:id]).first
      emit(fresh) if fresh[:status] != plan[:status] || fresh[:reason] != plan[:reason]
      fresh
    end

    def emit(plan)
      Events.emit(env.db, "plan.#{plan[:status]}", task_id: plan[:task_id], actor: "inbox", **self.class.fields(plan).except(:task_id))
    end

    def self.fields(plan)
      plan.slice(:id, :repo, :path, :name, :title, :status, :reason, :step, :steps, :task_id, :arrival)
          .merge(after: JSON.parse(plan[:after] || "[]"), replaces: JSON.parse(plan[:replaces] || "[]"))
    end
  end
end
