# Runeforge

Runeforge turns tickets into tested, merged changes by running coding-agent CLIs (Claude Code,
Codex, Aider) through a fixed workflow:

```
task → plan (spec + acceptance tests) → code → test → locked-test check → branch, PR, merge
```

It is an addition to the coding-agent ecosystem, not a replacement: the agent CLIs do the
coding; Runeforge gives them durable status, isolation, locked acceptance tests and an audit trail,
using your own database and git.

- **Messages in a database.** Agents never call each other. Each role claims commands from a
  `runeforge_messages` table (SQLite on one host, PostgreSQL for many) and replies to a
  supervisor that applies the workflow.
- **Git as the ledger.** Each task gets a branch (`runeforge/<task>`); each attempt is one
  commit with `Agent-Task` / `Agent-Message` trailers linking it back to the database.
- **Merged by default.** A task that passes its tests and the locked-test check is merged into
  the base branch: through its pull request on GitHub, directly for other remotes and local
  repositories. The next task starts from the merged result. Set `manual_merge: true` to leave
  branches and pull requests for a person to merge instead (see [Merging](#merging)).
- **Isolation.** Agent CLIs and test suites run in a throwaway container with no git, GitHub,
  JIRA or database credentials. The host turns the agent's patch into a commit itself.
- **Liveness.** Claims are leased and heartbeated. Stalled work is requeued, and dead-lettered
  (task `blocked`) after three failed deliveries.

## Usage

```sh
runeforge "Build a CLI that converts CSV to JSON, with tests"   # a prompt
runeforge plan.md                                               # a markdown task list
runeforge plan.md -d ~/code/my-app                              # iterate on an existing project
```

- A single word that isn't a command or a file is refused as a likely typo; use
  `runeforge build WORD` to build from a one-word prompt.
- **Without `-d`/`--dir`**, Runeforge asks for a directory name, creates it as a new git
  repository, builds there and merges each step into `main`.
- **With `-d DIR`**, it works on `runeforge/<name>` branches in that repository and merges them
  into the branch you had checked out. Your checkout is fast-forwarded to match, as long as you
  haven't left uncommitted changes in it; otherwise the work stays on its branch. It refuses to
  start if `DIR` has uncommitted changes. A directory that isn't a git repository yet can be
  initialised on the spot.
- **With `manual_merge: true`**, nothing is merged: the whole run builds on one
  `runeforge/<name>` branch, a new project is left checked out on it, and `-d` leaves your
  checkout alone.
- **Task lists:** each unchecked top-level list item (`- item`, `- [ ] item`, `1. item`) is one
  step, built in order, each on its own branch merged before the next starts (on one shared
  branch with `manual_merge: true`); indented lines belong to the item above, checked
  items (`- [x]`) are skipped, and the rest of the file is passed along as context. A file
  without at least two list items, or a prompt, is one step. A failed step stops the run.
- **Each step:** the planner writes a spec, acceptance tests (which become locked) and any
  scaffolding needed to run them, and says in `.runeforge/project.json` how to run the tests,
  how to run the project (`run_command`) and which tools they need. The coder then works until
  the tests pass (up to `max_attempts`).
- **Runnable results:** an existing project keeps its own launch method; Runeforge records it
  and changes nothing about it. A new project gets a README with a How to run section (npm
  projects an `npm start` script), and the reviewer rejects work whose docs don't contain the
  command Runeforge defined. `runeforge build` ends by printing it, and `runeforge repo set NAME
  --run-command ...` changes it. The conventions for common web and mobile stacks are in
  [docs/run-conventions.md](docs/run-conventions.md).
- **Missing tools:** agents run in the general-purpose image `runeforge/general:latest`
  (Python, Node, Ruby, Go, build tools, git, Claude Code). When a step needs something else,
  Runeforge asks which apt packages to add and builds a per-project image on top of it. With
  `sandbox.mode: none` it asks you to install the tool yourself instead.
- It runs in the foreground and prints each step as it happens. Ctrl-C stops it and discards
  the step in progress; finished steps stay merged (or on the branch, with `manual_merge`).

Configuration and data live in `~/.runeforge/`: settings in `~/.runeforge/runeforge.yml`, plus
the SQLite database, clones, logs and workspaces. The directory you run `runeforge` from doesn't
change its settings. `-c PATH` (or `RUNEFORGE_CONFIG=PATH`) reads another config file, and
`-db URL` (or `--database URL`) points at a different database.

## Setup and background mode

From a checkout, one command installs gems and sets everything up:

```sh
bin/setup                                   # = bundle install + runeforge init
```

With the gem installed, `runeforge init` does the same setup. Each step checks what is already
in place, so it is safe to run again:

1. Writes `~/.runeforge/runeforge.yml` (unless it exists) from flags such as `--database`, `--sandbox`, `--model`.
2. Checks git, and for a PostgreSQL URL starts the server via Homebrew when needed and creates the database.
3. Runs migrations.
4. Starts Docker Desktop (macOS), the Podman machine, or `systemctl start docker` when the sandbox needs it.
5. Builds the example agent image `runeforge/general:latest` if it is missing (`--skip-image` to skip).
6. Registers a repository if you pass `--repo-url URL --test-command CMD`.
7. Warns about missing secrets.
8. Starts the supervisor and one worker per `workers` entry in the background, then waits for
   them to register (`--no-start` to skip).

```sh
runeforge init --repo-url git@github.com:acme/api.git --repo api \
  --test-command "bundle exec rspec" --setup-command "bundle install"

runeforge ps                                         # background processes and their logs
runeforge task create --repo api --ticket DEV-101    # text fetched from JIRA when configured
runeforge task create --repo api --spec change.md    # or from a file
runeforge watch DEV-101
runeforge down                                       # stop the background processes
```

Background processes keep pid files in `<home>/run` and logs in `<home>/logs/daemons`. To run
them in the foreground instead, use `runeforge supervisor` and `runeforge worker --role ...`.

Environment variables used on the host: `RUNEFORGE_LLM_API_KEY` (a separate, spend-limited key;
the only secret that enters a container), `GITHUB_TOKEN`, `JIRA_EMAIL`, `JIRA_API_TOKEN`,
`RUNEFORGE_WEBHOOK_SECRET`. Git pushes use the host's normal git credentials.

**Models and API keys:** set the model in `runeforge.yml`. With an API key, any provider runs
on Runeforge's own agent, built on the [ruby_llm](https://rubyllm.com) gem
(`lib/runeforge/agent_runner.rb`). It runs in the sandbox with tools to list, read, search,
write and edit files and to run commands in the workspace. Each role can use its own model:

```yaml
agent:
  model: claude-sonnet-5-5          # the default for every role
  roles:
    planner: { model: gemini-pro-latest }
```

| Model (examples) | Provider | Key (host variable) |
|---|---|---|
| `claude-sonnet-5-5`, `claude-opus-5` | anthropic | `RUNEFORGE_ANTHROPIC_API_KEY` |
| `gemini-pro-latest`, `gemini-flash-latest` | gemini | `RUNEFORGE_GEMINI_API_KEY` |
| `gpt-5.6`, `o3` | openai | `RUNEFORGE_OPENAI_API_KEY` |
| `deepseek-chat`, `grok-4`, `codestral-latest`, `sonar-pro` | deepseek, xai, mistral, perplexity | `RUNEFORGE_<PROVIDER>_API_KEY` |
| `openrouter/<model>` | openrouter | `RUNEFORGE_OPENROUTER_API_KEY` |
| any OpenAI-compatible service (Together, Groq, a local server) | `provider: openai` plus `api_base:` | the role's `key_env` |

`RUNEFORGE_LLM_API_KEY` also works for the default model's provider (never for another
provider's model). A role's own `key_env` comes first. Models ruby_llm can't price can be given
`pricing` (dollars per million tokens) so budgets still work, and `max_tool_calls` (200) stops
a run that never finishes. Runeforge stops before starting if a role's agent has no key.

`adapter: claude_code` (or `codex`, `aider`, `command`) runs that CLI instead. Claude models use
Claude Code automatically when the only credential is a Claude subscription token (below).

The agent image (`docker/Dockerfile.general`, Ruby 3.3 with ruby_llm, Node 22, Claude Code)
must be rebuilt after upgrading Runeforge:
`docker build -t runeforge/general:latest -f docker/Dockerfile.general docker`.

**Using a Claude subscription instead of an API key:** your normal Claude Code login lives on
your machine, so agents in a container can't see it. Create a long-lived token for them:

```sh
claude setup-token                          # opens a browser; prints the token
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...   # add to your shell profile
```

With no `RUNEFORGE_LLM_API_KEY` set, Runeforge passes that token into the container (the
variable is `agent.oauth_token_env`). An API key wins when both are set. `runeforge build`,
`worker` and `up` stop before starting if a sandboxed agent has neither.

## Commands

| Command | What it does |
|---|---|
| `runeforge status TASK` | Task header plus every message, with heartbeat age for claimed work |
| `runeforge -d DIR status` | The project in DIR: whether it can be built here (see Platform apps), how it runs and merges, recent tasks, queued plans |
| `runeforge watch TASK` | Follows new messages until the task finishes |
| `runeforge tasks [--status S]` | Lists tasks |
| `runeforge workers` | Live workers, their current message and sandbox |
| `runeforge cancel TASK` | Stops a task; running workers kill their sandbox and discard results |
| `runeforge retry TASK --from-message N [--add-attempts K]` | Restarts coding from that message's commit |
| `runeforge logs TASK [--message N]` | Lists logs, or prints one |
| `runeforge init` | First-time setup; safe to repeat (see Quick start) |
| `runeforge up / down / ps` | Start, stop and list the background supervisor and workers |
| `runeforge webhook` | Serves `POST /webhooks/jira?token=…` for issues labelled `runeforge` |
| `runeforge dashboard [--port 9393]` | Serves the live dashboard (see below) |
| `runeforge warcamp [--port 9393]` | The same live view, drawn as an orc war camp |
| `runeforge repo set NAME [--run-command CMD] [--test-command CMD] [--require-run-docs]` | Change how a repository is tested and run |
| `runeforge config edit` | Opens `~/.runeforge/runeforge.yml` in `$VISUAL`/`$EDITOR` (creating it if needed), then checks it |
| `runeforge config path` / `config show` | The config file in use / the settings in effect, defaults included |
| `runeforge inbox [REPO] [--poll] [--all]` | The plans queued from each project's `runeforge/inbox/` |
| `runeforge demo` | Dry-run agents forever, plus the dashboard; no LLM, git or network |
| `runeforge worker --role R --dry-run` | A worker whose agents only go through the motions |

## Roles

Every step moves through these roles. The supervisor routes messages between them; only the
planner and coder run an agent. The checks and the hand-off are deterministic, so an agent
never judges its own work and never runs next to your credentials.

| Role | Agent? | Responsibilities | Runs where | Can change code? |
|---|---|---|---|---|
| **Supervisor** | No | Reads each result and sends the next command according to the workflow; enforces attempt, token and time budgets; requeues work whose worker stopped heartbeating and blocks a task after repeated failures | Host | No |
| **Planner** | Yes | Writes the spec (`.runeforge/spec.md`), acceptance tests that fail until the step is built, and any scaffolding needed to run them; reports the test command, setup command and required tools in `.runeforge/project.json`. Its test files become locked | Sandbox | Yes: tests and scaffolding |
| **Operator** | No (a person) | Foreground runs only: when the planner lists tools the sandbox lacks, or tests fail with "command not found", asks which apt packages to add and builds a per-project image (or, without a sandbox, asks you to install them) | Your terminal | No |
| **Coder** | Yes | Changes the code until the locked tests and the rest of the suite pass, using feedback from failed attempts. A patch that touches a locked test file is rejected | Sandbox | Yes, except locked tests |
| **Tester** | No | Runs the setup and test commands against the coder's commit in a fresh sandbox; the exit code is the verdict. Never writes files | Sandbox | No |
| **Reviewer** | No | Confirms every locked test file is byte-for-byte what the planner committed (by git object id) and that the change stays within size limits | Host | No |
| **Integrator** | No | Pushes the branch, opens or reuses the pull request on GitHub, comments on the JIRA ticket, and merges (unless `manual_merge`), using credentials that only exist on the host | Host | No |

A failed test run or rejected check goes back to the coder with the failure output, until the
task runs out of attempts or budget.

## How a step runs

1. A worker claims a command and leases it; a heartbeat thread keeps the lease alive.
2. The commit is exported with `git archive` into a fresh workspace. The host's `.git` is never
   mounted.
3. Inside the container, a script snapshots the tree in a throwaway repo, runs the agent CLI
   with the prompt from `.runeforge/prompt.md`, and writes everything it changed to
   `.runeforge/changes.patch`.
4. The host reads the patch (refusing symlinks and oversized files), applies it to a temporary
   index of its own bare clone, checks it against the locked tests and size limits, and commits.
5. The result message, the task update and the claim completion are written in one transaction.

The planner's patch must include at least one test file (matching `test_globs`); those test
files become locked, while any scaffolding it adds does not. The coder's patch is rejected if it
touches a locked file, and the reviewer re-checks every locked file's git object id before the
branch is pushed and merged.

## Live dashboard

`runeforge dashboard` serves an HTML page (Puma, default `http://127.0.0.1:9393/`) that shows
each role's claimed and waiting work, its live output, and every task's progress, as it happens.
It watches the database, so it sees supervisors and workers on any host.

- **Events.** Every change that matters to a viewer (a message posted, claimed, heartbeated,
  done, requeued, dead-lettered or cancelled; a task updated; a worker starting or stopping) also
  writes a row to `runeforge_events`, in the same transaction. Running agents and test suites
  add `agent.output` rows, batched about twice a second. The supervisor prunes events older
  than `events.retention_hours`.
- **Protocol.** `GET /api/state` returns a snapshot and a `cursor`; `GET /api/events?after=CURSOR`
  is a Server-Sent Events stream of everything after it (`?task=ID` narrows it). Each frame's
  `id` is the event id, so a reconnecting `EventSource` resumes where it left off. PostgreSQL
  wakes the stream with `LISTEN`/`NOTIFY`; SQLite polls. `POST /api/tasks/ID/cancel` (with an
  `X-Runeforge-Dashboard: 1` header) stops a task.
- **Access.** It binds to 127.0.0.1. Set `RUNEFORGE_DASHBOARD_TOKEN` to require `?token=`.

**Dry run.** With `dry_run.enabled: true` (or `runeforge worker --dry-run`), every role claims
real messages but, instead of running an agent, narrates canned steps for 5-10 seconds
(`dry_run.min_seconds`/`max_seconds`) and replies with a made-up result. Some results are
failures (`dry_run.failure_rate`), so retries and failed tasks happen too. `runeforge demo` runs
a supervisor, dry-run workers for every role and a feeder that keeps three tasks in flight, all in
one process with its own `~/.runeforge/demo.db`, until Ctrl-C:

```sh
runeforge demo                         # then open http://127.0.0.1:9393/
runeforge demo --warcamp               # the same, as the war camp
runeforge demo --concurrency 5 --min-seconds 2 --max-seconds 4
```

**War camp.** `runeforge warcamp` serves the same data as an RTS-style orc camp. Each role has
a building, and each worker is an orc who leaves it for a job and brings the result back:
- the planner studies the signpost by the war tent and brings back a scroll
- coders chop trees beside the lumber camp and carry logs home
- the tester hammers at the forge's anvil and stores the ingot in the chest
- the reviewer shoots at the target by the watchtower
- the integrator loads crates at the stables and hauls them out along the south road

Failures play a hit animation. Banners show the number of jobs waiting. Click an orc for its
task and live output, or Cancel to stop its task. Drag to pan and scroll to zoom. The art is
third-party; see [CREDITS.md](CREDITS.md). To rebuild it after changing `art/`, run
`python3 script/build_warcamp_assets.py` (needs Pillow and NumPy).

## Inbox

Every project gets a `runeforge/` folder: new projects in their first commit, existing
repositories with the first task Runeforge merges into them. Commit a markdown plan to
`runeforge/inbox/` on the base branch and the background supervisor (`runeforge up`) builds it:

```
runeforge/
├── README.md
├── inbox/      # commit plans here
└── done/       # finished plans, with a summary of the tasks that built them
```

- **Order:** plans run one at a time per repository, in the order they arrived on the base
  branch: the position of the commit that added each file, following renames. File names only
  break ties, and file dates are never used.
- **Plans:** same format as `runeforge plan.md`: one task per unchecked task-list item, each on
  its own branch and merged before the next; any other file is one task. The last step's merge
  also moves the plan to `done/`.
- **Front matter** (optional): `after: other-plan` waits until that plan is done;
  `replaces: other-plan` unlocks that plan's acceptance tests; `title`, `max_attempts`.
- **Changes:** edit a queued plan and it keeps its place; edit a running one and it restarts;
  edit a failed one (for example, check off the items that already merged) to queue it again
  at the back; delete one to drop or cancel it.
- **Locked tests carry over:** each plan inherits the acceptance tests of every finished plan, so
  a plan that contradicts an earlier one fails its review instead of quietly breaking it.
- **Not merged:** if a plan's work can't be merged (branch protection, conflicts), the
  repository's queue pauses until that work lands or the plan is removed from the inbox. With
  `manual_merge: true`, plans stack on one shared `runeforge/inbox` branch instead, which starts
  over from the base branch once everything on it has landed.
- Coding agents can't change anything under `runeforge/`. The planner is told which plans are
  still queued, so it doesn't build their work early.

`runeforge inbox --poll` checks now rather than waiting `inbox.poll_seconds` (60). Both
dashboards show the queue. `inbox.enabled: false` turns it off. The design is in
[docs/plans/inbox.md](docs/plans/inbox.md).

## Merging

By default every task is merged once it passes:

- **GitHub remotes:** the integrator opens the pull request, then merges it through the API
  with `merge_method` (`merge`, `squash` or `rebase`; default `merge`). Branch protection still
  applies: if GitHub refuses (required reviews or checks, conflicts), the pull request is left
  open and the task finishes with a "not merged" warning.
- **Other remotes and local repositories:** there is no pull request, so the branch is merged
  directly: a fast-forward when nothing else landed, otherwise a merge commit built in
  Runeforge's own clone. Conflicts are never resolved automatically; the branch is left for you.
  If the base branch is checked out in a local repository, that checkout is fast-forwarded only
  when it has no uncommitted changes. Merged branches are deleted.

A task that wasn't merged is still `done`; `runeforge status TASK` shows the warning and its
`merged_sha` stays empty. `manual_merge` and `merge_method` can be set per project under
`projects:` in `runeforge.yml`, keyed by the project's directory, registered repo name or git
URL (`projects: { ~/code/payments: { manual_merge: true } }`). With `manual_merge: true`, Runeforge stops after
pushing the branch and opening the pull request, as it used to.

## Platform apps

Agents and tests run in a Linux container, which can't build iOS, macOS or Android apps: those
need Xcode on a Mac, or the Android SDK. Runeforge recognizes them from the project's files
(`*.xcodeproj`, an Apple-platform `Package.swift`, a `Podfile`, `AndroidManifest.xml`) or the
request ("iOS", "SwiftUI", "Android app", ...), and checks where they would be built:

- `runeforge build` explains and asks before starting.
- The planner checks again before its agent runs. An incompatible project fails planning with
  the fix instead of being rewritten in a language the sandbox has.
- The verdict is recorded on the repository; `runeforge -d DIR status` shows it alongside a
  fresh check.

To build an Apple app, run it on a Mac with the full Xcode app (not only the Command Line Tools)
and turn the sandbox off for that project: `projects: { ~/code/wordreel: { sandbox: none } }`.
Without a sandbox the agents run on your machine with full permissions (Claude Code with
`--dangerously-skip-permissions`, Codex without its own sandbox), so they can build, test and run
the simulator, and could run any other command as you. Use it only for projects you'd trust an
agent with.

## Embedding

The supervisor and workers can run inside an app's job system:

```ruby
require "runeforge/jobs"                 # after ActiveJob or Sidekiq is loaded
Runeforge::Jobs::SupervisorJob.perform_later
Runeforge::Jobs::WorkerJob.perform_later(%w[planner coder])
```

Each job works for a bounded slice and re-enqueues itself. Mount the webhook in Rails with
`mount Runeforge::Web::WebhookApp.new => "/runeforge"`. Tables are prefixed `runeforge_` and
migrations use their own version table, so they don't collide with the app's.

Custom workflows are plain Ruby loaded from `workflow_paths`; see
`lib/runeforge/workflows/jira_to_pr.rb`.

## Development

```sh
bundle install
bundle exec rspec                                                   # SQLite
RUNEFORGE_TEST_PG_URL=postgres://localhost/runeforge_test bundle exec rspec   # + PostgreSQL
```

Container isolation specs run only when a Docker daemon is available.

## Current limits

- Restricting container egress to the LLM API and package registries is left to the Docker
  network you configure (`sandbox.network`); Runeforge doesn't filter traffic itself.
- The LLM key (or subscription token) is passed into the container by name. A proxy that keeps it out entirely is planned.
- Parallel best-of-N attempts and OpenTelemetry are not built yet.
