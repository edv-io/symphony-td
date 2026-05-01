---
name: td
description: |
  Use Symphony's `td_cli` client tool for tracker writes against a `td`
  (https://github.com/4ier/td) database — comments, state transitions,
  handoffs — when running inside a Symphony td-mode app-server session.
---

# td (Tracker)

Use this skill for tracker writes during Symphony app-server sessions when the
workflow is configured for td (`tracker.kind: td` in `WORKFLOW.md`).

## Primary tool

Symphony exposes a `td_cli` client tool that runs an allowlisted subset of the
`td` CLI against the project that owns the current issue. The tool reuses
Symphony's configured project list — you do not pass paths from the agent unless
you have a specific reason to override.

Tool input:

```json
{
  "subcommand": "comment",
  "issue_id": "td-2c2676",
  "args": ["body of the comment"],
  "project_dir": null
}
```

Tool behavior:

- One CLI invocation per tool call.
- `subcommand` MUST be one of:
  `start`, `unstart`, `review`, `approve`, `reject`,
  `done`, `close`, `comment`, `handoff`, `log`, `block`, `unblock`.
- Destructive operations (`delete`, `restore`, `update`) are not exposed and
  will be rejected by the dispatcher.
- `project_dir` defaults to fan-out lookup across configured projects. Only
  set it when you have a specific path to scope the call.
- A non-zero td exit code is reported as an `error.message` with the captured
  stdout/stderr; treat that as a failed write.

## Common workflows

### Comment on the current issue

Append a progress note as the agent works:

```json
{
  "subcommand": "comment",
  "issue_id": "td-2c2676",
  "args": ["Reproduced the bug locally; root cause is in src/foo.ex line 42."]
}
```

### Submit work for human review

When the implementation is complete and you want the human to verify:

```json
{ "subcommand": "review", "issue_id": "td-2c2676" }
```

Then leave a single comment summarizing what was done. The orchestrator will
stop when the issue moves to a non-active state.

### Close work

If the workflow's `terminal_states` includes `closed`/`done` and you want to
mark the issue done directly (no review):

```json
{ "subcommand": "done", "issue_id": "td-2c2676" }
```

td requires a self-close exception when the closer is also the implementer;
Symphony adds `--self-close-exception symphony` automatically on `done`/`close`.

### Capture handoff state

For long-running issues that span multiple Codex turns, record what's done and
what remains so a future continuation has structured context:

```json
{
  "subcommand": "handoff",
  "issue_id": "td-2c2676",
  "args": [
    "--done", "Wrote the adapter",
    "--done", "Added unit tests",
    "--remaining", "Wire the dynamic tool",
    "--decision", "Used fan-out instead of an in-memory cache",
    "--uncertain", "Whether td-all section parsing handles symlinks"
  ]
}
```

### Log a quick note

`log` is the lighter-weight alternative to a comment, attached to the focused
issue:

```json
{ "subcommand": "log", "issue_id": "td-2c2676", "args": ["checked CI; green"] }
```

### Mark blocked

When external input is required:

```json
{
  "subcommand": "block",
  "issue_id": "td-2c2676",
  "args": ["-m", "Waiting on access to the staging cluster."]
}
```

## Tips

- Keep comments narrow and factual. The human review path consumes them.
- Don't loop `comment` calls inside a turn — batch your update into one comment
  before yielding.
- Prefer `review` over `done` unless the workflow's `terminal_states` makes
  `closed` the agent's success state.
- If you need to read issue state you already received in the prompt, don't
  call `td_cli` for `show` — it's a write tool. Use the issue context Symphony
  injected into your prompt.
