# Symphony (td-driven fork)

> **This is a fork of [openai/symphony](https://github.com/openai/symphony) with the tracker rewired
> from Linear to [`td`](https://github.com/4ier/td) — a local SQLite-backed task CLI.** Use upstream
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
