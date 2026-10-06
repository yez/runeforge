# frozen_string_literal: true

module Runeforge
  # What earlier builds in a repository already finished. A build run again with the same plan,
  # or `runeforge resume`, skips the steps at the start that are done and starts at the first one
  # that isn't, with the done steps' tests locked. Steps are matched by content (PlanFile::Step#key),
  # not by number, so editing a step makes it, and every step after it, run again.
  class BuildProgress
    # skip: how many of the plan's steps to skip; done: the task that finished each skipped step
    # (nil for one skipped by --from with --rerun); base: the commit the next step starts from;
    # locked: the tests to lock, as they are at base; branch: the last done step's branch when the
    # next step stacks on its unmerged work (manual merging keeps using it), else nil; notes: what
    # the person should know (steps not skipped, locks dropped).
    Start = Data.define(:skip, :done, :base, :locked, :branch, :notes)

    # Activity this recent on a task that isn't finished means a build may still be driving it.
    LIVE_SECONDS = 120

    attr_reader :env, :repo

    def initialize(env, repo)
      @env = env
      @repo = repo
    end

    # The input a task was created with (its task.created payload).
    def self.task_input(env, task_id)
      row = env.db[:runeforge_messages].where(task_id: task_id.to_s, type: "task.created").first
      payload = row && Message.from_row(row).payload
      payload.is_a?(Hash) ? payload : {}
    end

    # A step's key from the input its task was created with (older tasks don't store one).
    def self.task_key(input)
      input["step_key"] || PlanFile.step_key(input["description"] || input["title"])
    end

    # Where to start `steps` (a PlanFile's), given the base branch's current commit.
    # from: start at this step number (1-based) instead of the first one that isn't done;
    # rerun: ignore earlier progress (with from, the steps before it are still skipped).
    def start(plan, base:, from: nil, rerun: false)
      steps = plan.steps
      raise Error, "--from must be between 1 and #{steps.size}" if from && !from.between?(1, steps.size)

      notes = []
      done = rerun ? [] : done_prefix(steps, base, notes)
      if from
        if from - 1 > done.size && !rerun
          step = steps[done.size]
          raise Error, "can't start at step #{from}: step #{done.size + 1} (#{step.title}) isn't done. " \
                       "Mark it done with `runeforge task mark-done TASK --sha SHA`, or pass --rerun to start there anyway"
        end
        done = rerun ? Array.new(from - 1) : done.first(from - 1)
      end

      skipped = steps.first(done.size)
      lock_sources = done.compact + (skipped + plan.checked_steps).filter_map { |step| done_by_key[step.key] }
      head = done.compact.last
      start_sha = head && stacked?(head, base) ? head[:head_sha] : base
      locked = locks_at(lock_sources, start_sha, notes)
      branch = start_sha == base ? nil : head[:branch]
      Start.new(skip: done.size, done:, base: start_sha, locked:, branch:, notes:)
    end

    # Foreground build runs in this repository, oldest first: {id:, lane:, tasks:, input:, plan:,
    # finished:, live:}. A run's tasks share its lane; its plan is the text it started from.
    def runs
      tasks = env.db[:runeforge_tasks].where(repo:, workflow: "build").exclude(lane: nil).order(:created_at, :id).all
      tasks.group_by { |t| t[:lane] }.map do |lane, rows|
        input = self.class.task_input(env, rows.first[:id])
        plan = stored_plan(input)
        # Finished when every step of its plan is done, by this run, another one or mark-done.
        finished = plan ? plan.steps.all? { |step| done_by_key.key?(step.key) } : rows.last[:status] == "done"
        {
          id: rows.first[:id].sub(/-s\d+\z/, ""), lane:, tasks: rows, input:, plan:,
          started_at: rows.first[:created_at], updated_at: rows.map { |t| t[:updated_at] }.compact.max,
          finished:,
          live: rows.any? { |t| live?(t) }
        }
      end.sort_by { |run| [run[:started_at], run[:id]] }
    end

    # The plan a run started from, rebuilt from what its first task stored.
    def stored_plan(input)
      if input["plan"].is_a?(Hash) && !input["plan"]["text"].to_s.strip.empty?
        PlanFile.parse(input["plan"]["text"], list: input["plan"]["list"] != false)
      elsif !input["context"].to_s.strip.empty?
        PlanFile.parse(input["context"])
      elsif !input["description"].to_s.strip.empty?
        PlanFile.parse(input["description"], list: false)
      end
    rescue Error
      nil
    end

    # True while a build could still be driving the task: it isn't finished, and either a worker
    # holds one of its messages or it changed in the last LIVE_SECONDS.
    def live?(task)
      return false if TERMINAL_STATUSES.include?(task[:status])

      claimed = env.db[:runeforge_messages].where(task_id: task[:id], state: "claimed")
                   .where { lease_expires_at > Runeforge.now }.count.positive?
      claimed || (task[:updated_at] && Runeforge.now - task[:updated_at] < LIVE_SECONDS)
    end

    # Records that a person finished a step themselves at `sha` (a failed or stopped task), so a
    # build run again or resumed skips it. Its tests are locked as they are at `sha`, including
    # any the person changed. Returns the updated task.
    def self.mark_done(env, task_id, sha:)
      task = env.tasks.find!(task_id)
      if task[:status] == "done"
        raise Error, "task #{task_id} is already done"
      elsif !TERMINAL_STATUSES.include?(task[:status])
        raise Error, "task #{task_id} is still #{task[:status]}; stop it with `runeforge cancel #{task_id}` first"
      end

      name = task[:repo]
      base = env.repos.refresh(name)
      dir = env.repos.path(name)
      commit = Git.run("rev-parse", "--verify", "--quiet", "#{sha}^{commit}", dir:, allow_failure: true)&.strip
      raise Error, "#{sha} isn't a commit in #{name}; commit (and merge) the fix first" if commit.to_s.empty?

      merged = env.repos.contains?(name, commit, base:) ? commit : nil
      if merged.nil? && !env.manual_merge?(name)
        branch = env.repos.fetch(name)[:base_branch]
        raise Error, "#{commit[0, 7]} isn't in #{branch}; merge the fix into #{branch} first, so the next step builds on it"
      end

      globs = env.config["test_globs"]
      test_file = ->(path) { globs.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
      changed = env.repos.changed_files(name, from: task[:base_sha], to: commit).select(&test_file)
      paths = JSON.parse(task[:locked_paths] || "{}").keys | changed
      locked = paths.to_h { |path| [path, env.repos.oid(name, commit, path)] }.compact

      env.db.transaction do
        env.tasks.update(task_id, status: "done", error: nil, head_sha: commit, merged_sha: merged,
                                  locked_paths: JSON.generate(locked))
        id = env.mailbox("cli").post(task_id:, type: "task.marked_done", recipient: "cli", commit_sha: commit,
                                     payload: { "previous_status" => task[:status], "previous_error" => task[:error],
                                                "locked_paths" => locked },
                                     dedupe_key: "#{task_id}:task.marked_done:#{commit}")
        # A record for the task's history, not a command: nothing handles it.
        env.db[:runeforge_messages].where(id:).update(state: "done") if id
      end
      env.tasks.find(task_id)
    end

    # The newest done task for each step key in this repository.
    def done_by_key
      @done_by_key ||= env.db[:runeforge_tasks].where(repo:, workflow: "build", status: "done").order(:created_at, :id).all
                          .to_h { |task| [self.class.task_key(self.class.task_input(env, task[:id])), task] }
    end

    private

    # The done tasks for the steps at the start of the plan, stopping at the first step that has
    # none, or whose work isn't in the base branch (or, unmerged, under the step before it).
    def done_prefix(steps, base, notes)
      done = []
      steps.each_with_index do |step, index|
        task = done_by_key[step.key]
        break unless task

        sha = task[:merged_sha] || task[:head_sha]
        if sha && contains?(sha, base)
          done << task
        elsif sha && task[:merged_sha].nil? && done.all? { |earlier| contains?(earlier[:merged_sha] || earlier[:head_sha], sha) }
          done << task # finished but not merged: the next step stacks on it, as in the original run
        else
          notes << "step #{index + 1} (#{step.title}) was done in task #{task[:id]}, but its work " \
                   "(#{sha.to_s[0, 7]}) isn't in the base branch any more; building it again"
          break
        end
      end
      done
    end

    # The task's work is not in the base branch, so the next step builds on top of it.
    def stacked?(task, base) = task[:merged_sha].nil? && !contains?(task[:head_sha], base)

    # The tests the given tasks locked, as they are at `sha`: an earlier step's test may have been
    # changed since by a person or a later step, and the reviewer compares against what's locked.
    def locks_at(tasks, sha, notes)
      paths = tasks.flat_map { |task| JSON.parse(task[:locked_paths] || "{}").keys }.uniq
      paths.each_with_object({}) do |path, locked|
        oid = env.repos.oid(repo, sha, path)
        oid ? locked[path] = oid : notes << "#{path} was locked by an earlier step but no longer exists; it isn't locked now"
      end
    end

    def contains?(sha, base) = env.repos.contains?(repo, sha, base:)
  end
end
