defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Tracker}
  alias SymphonyElixir.Tracker.Issue

  @kanban_states ~w(open ready in_progress in_review blocked)
  @closed_state "closed"
  @default_closed_limit 20

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{
          generated_at: generated_at,
          error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
        }

      :unavailable ->
        %{
          generated_at: generated_at,
          error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}
        }
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if not is_nil(running) or not is_nil(retry) do
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        else
          tracker_issue_payload(issue_identifier)
        end

      _ ->
        tracker_issue_payload(issue_identifier)
    end
  end

  defp tracker_issue_payload(issue_identifier) do
    case Tracker.fetch_issue_states_by_ids([issue_identifier]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue_detail_payload(issue)}
      _ -> {:error, :issue_not_found}
    end
  end

  @spec issue_detail_payload(Issue.t()) :: map()
  def issue_detail_payload(%Issue{} = issue) do
    %{
      issue_identifier: issue.identifier,
      issue_id: issue.id,
      title: issue.title,
      description: issue.description,
      state: issue.state,
      priority: issue.priority,
      labels: issue.labels |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.sort(),
      branch_name: issue.branch_name,
      url: issue.url,
      repo_url: Map.get(issue, :repo_url),
      project_dir: Map.get(issue, :project_dir),
      created_at: format_datetime(issue.created_at),
      updated_at: format_datetime(issue.updated_at),
      source: "tracker"
    }
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(_), do: nil

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec kanban_payload([Issue.t()], keyword()) :: map()
  def kanban_payload(issues, opts \\ []) when is_list(issues) and is_list(opts) do
    filter_label = opts |> Keyword.get(:filter_label) |> normalize_label()
    symphony_only? = Keyword.get(opts, :symphony_only?, false)
    show_closed? = Keyword.get(opts, :show_closed?, false)
    closed_limit = Keyword.get(opts, :closed_limit, @default_closed_limit)
    show_project? = project_count(Keyword.get(opts, :projects, [])) > 1
    states = if show_closed?, do: @kanban_states ++ [@closed_state], else: @kanban_states

    cards =
      issues
      |> Enum.filter(fn issue ->
        match?(%Issue{}, issue) and kanban_label_match?(issue, filter_label, symphony_only?)
      end)
      |> Enum.map(&kanban_card(&1, show_project?, filter_label))

    columns =
      Map.new(states, fn state ->
        state_cards =
          cards
          |> Enum.filter(&(&1.state == state))
          |> sort_kanban_cards(state)
          |> limit_closed_cards(state, closed_limit)

        {state,
         %{
           state: state,
           title: kanban_state_title(state),
           cards: state_cards,
           count: length(state_cards)
         }}
      end)

    %{
      columns: columns,
      states: states,
      filter_label: filter_label,
      symphony_only?: symphony_only?,
      show_closed?: show_closed?,
      closed_limit: closed_limit,
      show_project?: show_project?,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp kanban_card(%Issue{} = issue, show_project?, filter_label) do
    id = issue.identifier || issue.id || "unknown"
    labels = issue.labels |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.sort()
    title = issue.title || "(untitled)"
    visible_labels = Enum.take(labels, 3)

    %{
      id: id,
      title: title,
      display_title: truncate_title(title),
      state: kanban_card_state(issue, filter_label),
      priority: kanban_priority_label(issue.priority),
      priority_rank: kanban_priority_rank(issue.priority),
      labels: visible_labels,
      label_overflow_count: max(length(labels) - length(visible_labels), 0),
      project: kanban_project_label(issue.project_dir, show_project?),
      project_dir: issue.project_dir,
      updated_at: iso8601(issue.updated_at),
      created_at: iso8601(issue.created_at),
      detail_url: "/api/v1/#{id}",
      aria_label: "#{id}: #{issue.title || "(untitled)"}"
    }
  end

  defp kanban_card_state(%Issue{} = issue, filter_label) when is_binary(filter_label) do
    state = normalize_kanban_state(issue.state)

    if state == "open" and has_label?(issue.labels, filter_label) do
      "ready"
    else
      state
    end
  end

  defp kanban_card_state(%Issue{} = issue, _filter_label), do: normalize_kanban_state(issue.state)

  defp kanban_label_match?(_issue, _filter_label, false), do: true
  defp kanban_label_match?(_issue, nil, true), do: true

  defp kanban_label_match?(%Issue{labels: labels}, filter_label, true) do
    has_label?(labels, filter_label)
  end

  defp has_label?(labels, filter_label) when is_list(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.any?(&(&1 == filter_label))
  end

  defp has_label?(_labels, _filter_label), do: false

  defp sort_kanban_cards(cards, @closed_state) do
    Enum.sort_by(
      cards,
      &{datetime_sort_key(&1.updated_at), datetime_sort_key(&1.created_at), &1.id},
      :desc
    )
  end

  defp sort_kanban_cards(cards, _state) do
    Enum.sort_by(cards, &{&1.priority_rank, datetime_sort_key(&1.created_at), &1.id})
  end

  defp limit_closed_cards(cards, @closed_state, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(cards, limit)

  defp limit_closed_cards(cards, _state, _limit), do: cards

  defp kanban_project_label(_project_dir, false), do: nil
  defp kanban_project_label(nil, true), do: nil
  defp kanban_project_label("", true), do: nil
  defp kanban_project_label(project_dir, true), do: Path.basename(project_dir)

  defp kanban_priority_label(priority) when is_integer(priority) and priority in 1..5 do
    "P#{priority - 1}"
  end

  defp kanban_priority_label(_priority), do: "P4"

  defp kanban_priority_rank(priority) when is_integer(priority) and priority in 1..5, do: priority
  defp kanban_priority_rank(_priority), do: 5

  defp kanban_state_title(state) do
    state
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp normalize_kanban_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_kanban_state(_state), do: ""

  defp normalize_label(nil), do: nil

  defp normalize_label(label) when is_binary(label) do
    case label |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_label(label), do: label |> to_string() |> normalize_label()

  defp truncate_title(title) when is_binary(title) do
    if String.length(title) > 60, do: String.slice(title, 0, 57) <> "...", else: title
  end

  defp project_count(projects) when is_list(projects),
    do: projects |> Enum.reject(&is_nil/1) |> length()

  defp project_count(_projects), do: 0

  defp datetime_sort_key(nil), do: ""
  defp datetime_sort_key(value), do: value

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
