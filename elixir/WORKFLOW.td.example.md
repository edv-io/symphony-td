---
tracker:
  kind: td
  # Either enumerate the project directories explicitly:
  projects:
    - ~/Projects/edv-intel
    - ~/Projects/edv-dashboard
  # Or auto-discover every td-tracked directory via the `td-all` wrapper:
  # scope: all
  filter_label: symphony
  active_states:
    - open
    - in_progress
  terminal_states:
    - closed
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  # Each issue lives in a different repo. Symphony injects per-issue env vars
  # into hooks (SYMPHONY_ISSUE_REPO_URL, SYMPHONY_ISSUE_PROJECT_DIR, etc.) so
  # the after_create hook can clone the right tree.
  after_create: |
    if [ -z "$SYMPHONY_ISSUE_REPO_URL" ]; then
      echo "Symphony did not provide SYMPHONY_ISSUE_REPO_URL; aborting workspace bootstrap" >&2
      exit 1
    fi
    git clone --depth 1 "$SYMPHONY_ISSUE_REPO_URL" .
    if command -v mise >/dev/null 2>&1 && [ -f mise.toml ]; then
      mise trust && mise install
    fi
agent:
  max_concurrent_agents: 2
  max_turns: 20
codex:
  command: codex --config 'model="gpt-5.5"' app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on td issue {{ issue.identifier }}.

{% if attempt %}
Continuation context:

- Retry attempt #{{ attempt }} because the issue is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

Issue context:

- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- Labels: {{ issue.labels }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
(No description provided.)
{% endif %}

When you are done, do exactly one of these:

1. If the workflow's `terminal_states` includes `closed`, complete the work and
   submit it for review with the `td_cli` tool: `{ "subcommand": "review",
   "issue_id": "{{ issue.identifier }}" }`. Then leave a single comment summarizing
   what was done.
2. If you need clarification, leave a comment via `td_cli` and stop.

Do not call `td_cli` for `show`/`comments`/anything read-only — your prompt
already contains the issue context you need.

Use the in-repo `td` skill (under `.codex/skills/td`) for the full reference
on `td_cli` calls.
