# Symphony (td-driven fork)

> **This is a fork of [openai/symphony](https://github.com/openai/symphony) with the tracker rewired
> from Linear to [`td`](https://github.com/marcus/sidecar) — a local SQLite-backed task CLI.** Use upstream
> if you want Linear; use this fork if your work lives in td across one or more project directories.

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

## How this fork differs from upstream

| | upstream | `symphony-td` |
| --- | --- | --- |
| Tracker | Linear (GraphQL API) | `td` CLI across one or more project dirs |
| WORKFLOW.md `tracker.kind` | `linear` | `td` |
| Issue identifier | `TEAM-123` | `td-2c2676` |
| Workspace bootstrap | one repo hardcoded in the after_create hook | per-issue `$SYMPHONY_ISSUE_REPO_URL` env var, derived from the task's project dir |
| Codex client tool | `linear_graphql` (unbounded GraphQL) | `td_cli` (allowlisted subcommands) |
| Workflow states | Linear-defined (Todo / In Progress / Human Review / Merging / Done / …) | td states (open / in_progress / in_review / closed / blocked) |
| Auth | `LINEAR_API_KEY` | none — `td` runs locally |

The Linear adapter is still in the codebase and remains the default. Set `tracker.kind: td` in
`WORKFLOW.md` to switch.

See [`elixir/WORKFLOW.td.example.md`](elixir/WORKFLOW.td.example.md) for a complete td-mode template,
and [`.codex/skills/td/SKILL.md`](.codex/skills/td/SKILL.md) for the agent-side `td_cli` reference.

## Safety gate

Symphony auto-claims any open issue in the configured `active_states` and runs Codex unattended
against it. To prevent it from picking up *every* td task, the td adapter requires a label gate
(`tracker.filter_label`, default `symphony`). Only tasks carrying that label are eligible; you opt
each task in by adding the label.

## Workspace reliability

Long-running agents can continue across multiple Codex turns in the same workspace. Configure
`hooks.before_turn` in `WORKFLOW.md` to refresh that workspace between turns, for example by
fetching `origin/main` and rebasing the feature branch before the next turn starts. Hook failures are
logged and ignored so a failed refresh does not kill the active run.

## Run td-mode locally

Prerequisites:

- [`mise`](https://mise.jdx.dev/) (manages the Elixir/Erlang toolchain pinned in `elixir/mise.toml`)
- [`codex`](https://developers.openai.com/codex/) on `PATH` (`codex --version` should work)
- [`td`](https://github.com/marcus/sidecar) on `PATH` for the tracker calls; `td-all` if you want
  `scope: all` auto-discovery
- A Git checkout of every project you want Symphony to act on (so the after_create hook can derive
  the repo URL from `git -C <dir> remote get-url origin`)

```sh
# 1. Get the build
git clone https://github.com/alex-edv/symphony-td ~/Projects/symphony-td
cd ~/Projects/symphony-td/elixir
mise trust && mise install
mise exec -- mix deps.get
mise exec -- mix compile
mise exec -- mix build           # produces ./bin/symphony

# 2. Author your local workflow (gitignored — never commit your project list)
cp WORKFLOW.td.example.md ../WORKFLOW.local.md
# edit ../WORKFLOW.local.md:
#   - set tracker.scope: all  (or list explicit projects)
#   - keep tracker.filter_label: symphony
#   - tweak agent.max_concurrent_agents to taste (start with 1–2)

# 3. Opt a td task in by adding the symphony label
td update <issue-id> --labels "...,symphony"

# 4. Start the orchestrator (long-running)
cd ~/Projects/symphony-td/elixir
mise exec -- ./bin/symphony ../WORKFLOW.local.md
```

Symphony polls td every `polling.interval_ms`, claims any open `symphony`-labelled issue, creates a
fresh workspace under `workspace.root`, runs the `after_create` hook (which clones the issue's
project repo using `$SYMPHONY_ISSUE_REPO_URL`), launches Codex in app-server mode, and feeds it the
prompt body from `WORKFLOW.local.md` with `{{ issue.* }}` interpolated. To stop everything: Ctrl-C
the process; running agents exit and workspaces stay around for inspection.

To watch what's happening live, tail the log directory you set in `--logs-root` (default
`./log`):

```sh
tail -f ~/Projects/symphony-td/elixir/log/*.log
```

To remove an issue from Symphony's queue mid-run, drop the `symphony` label or move it to a
`terminal_states` value (`closed`).

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
