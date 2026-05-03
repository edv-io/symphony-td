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
  #
  # GH_TOKEN is also injected when agent.gh_token_keychain is set below. The
  # inline credential helper teaches git to authenticate over HTTPS using that
  # env var instead of `gh auth git-credential` (which would otherwise prompt
  # the macOS keychain — a call the codex sandbox blocks).
  after_create: |
    if [ -z "$SYMPHONY_ISSUE_REPO_URL" ]; then
      echo "Symphony did not provide SYMPHONY_ISSUE_REPO_URL; aborting workspace bootstrap" >&2
      exit 1
    fi
    git clone --depth 1 "$SYMPHONY_ISSUE_REPO_URL" .
    if [ -n "$GH_TOKEN" ]; then
      git config credential.helper '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
    fi
    if command -v mise >/dev/null 2>&1 && [ -f mise.toml ]; then
      mise trust && mise install
    fi
  # Runs between completed Codex turns before Symphony dispatches the next
  # turn. Failures are logged and ignored by Symphony, so this hook should
  # avoid leaving conflict state behind when a rebase cannot be applied.
  before_turn: |
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    git fetch origin main:refs/remotes/origin/main --quiet || exit 0
    git merge --ff-only origin/main 2>/dev/null || \
      git rebase origin/main || \
      { echo 'rebase conflict - staying on current base'; git rebase --abort >/dev/null 2>&1 || true; exit 0; }
agent:
  max_concurrent_agents: 2
  max_turns: 20
  # Name of a generic-password keychain entry holding a GitHub PAT. Symphony
  # reads it once at startup via `security find-generic-password -s <name> -w`
  # and injects the value as GH_TOKEN into both the codex child process and
  # workspace hooks. Omit to leave agents without a publish path.
  #
  # Trust model: the codex sandbox protects the *workspace*, not your *auth*.
  # Once an agent has GH_TOKEN it can reach any HTTPS endpoint that token
  # accepts, so issue narrowly-scoped fine-grained PATs and rotate them.
  gh_token_keychain: hubs:github.com/alex-edv
  # Optional: forward additional env vars from the orchestrator to the agent
  # (e.g. private CI tokens). GH_TOKEN is reserved.
  # env_passthrough:
  #   - HUBS_TOKEN_EDV_IO
codex:
  command: codex --config 'model="gpt-5.5"' app-server
  approval_policy: never
  thread_sandbox: workspace-write
  # networkAccess: true is required for agents to push commits and open PRs.
  # The default is false (workspace-only); flip it explicitly so the trust
  # model is documented in your config rather than implied.
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
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
