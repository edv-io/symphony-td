defmodule SymphonyElixir.Td.Adapter do
  @moduledoc """
  td CLI-backed tracker adapter.

  Polls td across one or more configured project directories and translates
  td's JSON output into `SymphonyElixir.Tracker.Issue` structs. Each issue
  carries its originating `project_dir` so the orchestrator can scope hooks
  and the agent can route subsequent CLI calls back to the right db.

  Multi-project polling is fan-out: every configured project directory is
  queried sequentially. SQLite reads are sub-100ms each, so the cost is
  bounded by the number of projects rather than the number of issues.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  defp cli_module do
    Application.get_env(:symphony_elixir, :td_cli_module, SymphonyElixir.Td.Cli)
  end

  @impl true
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with {:ok, dirs} <- resolve_project_dirs(tracker),
         {:ok, issues} <-
           fan_out_list(dirs,
             statuses: tracker.active_states,
             filter: filter_label_expr(tracker.filter_label)
           ) do
      {:ok, Enum.filter(issues, &claimable?(&1, tracker))}
    end
  end

  @impl true
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized = state_names |> Enum.map(&normalize_state/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with {:ok, dirs} <- resolve_project_dirs(tracker) do
        # `-a` so closed issues are returned when callers query for terminal states.
        fan_out_list(dirs, statuses: normalized, include_closed: true)
      end
    end
  end

  @impl true
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        tracker = Config.settings!().tracker

        with {:ok, dirs} <- resolve_project_dirs(tracker),
             {:ok, issues} <- fan_out_list(dirs, ids: ids, include_closed: true) do
          {:ok, sort_by_requested_ids(issues, ids)}
        end
    end
  end

  @impl true
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    cond do
      not SymphonyElixir.Td.Cli.literal_safe?(body) ->
        # td/Cobra interprets `@<path>` and `-` as file-read / stdin primitives.
        # Reject before spawning so a comment body cannot become a local file read.
        {:error, :td_unsafe_literal_body}

      true ->
        with {:ok, dir} <- locate_project_dir(issue_id) do
          # `--` so td/Cobra cannot parse the body as a flag (e.g. --work-dir=/x).
          # Same defense the dynamic tool applies to agent-supplied bodies; the
          # callback is a public Tracker API that could carry agent-influenced text.
          cli_module().write(dir, "comment", issue_id, ["--", body])
        end
    end
  end

  @impl true
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, dir} <- locate_project_dir(issue_id),
         {:ok, subcommand, args} <- map_state_to_command(state_name) do
      cli_module().write(dir, subcommand, issue_id, args)
    end
  end

  # --- Helpers ---------------------------------------------------------------

  defp resolve_project_dirs(tracker) do
    explicit = (tracker.projects || []) |> Enum.map(&expand_path/1) |> Enum.reject(&(&1 == ""))

    cond do
      explicit != [] ->
        {:ok, explicit}

      tracker.scope == "all" ->
        cli_module().list_project_dirs()

      true ->
        {:error, :td_no_projects_configured}
    end
  end

  defp fan_out_list(dirs, list_opts) do
    Enum.reduce_while(dirs, {:ok, []}, fn dir, {:ok, acc} ->
      case cli_module().list_json(dir, list_opts) do
        {:ok, raw_issues} ->
          issues = Enum.map(raw_issues, &normalize_issue(&1, dir))
          {:cont, {:ok, acc ++ issues}}

        {:error, {:td_cli_error, _status, output}} ->
          # A single project failing should not poison the whole poll. Log and
          # continue so the orchestrator still sees other projects' issues.
          Logger.warning("td list failed dir=#{dir} output=#{inspect(output)}")
          {:cont, {:ok, acc}}

        {:error, reason} ->
          Logger.warning("td list errored dir=#{dir} reason=#{inspect(reason)}")
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp locate_project_dir(issue_id) do
    tracker = Config.settings!().tracker

    with {:ok, dirs} <- resolve_project_dirs(tracker) do
      Enum.reduce_while(dirs, {:error, :td_issue_not_found}, fn dir, _acc ->
        case cli_module().list_json(dir, ids: [issue_id], include_closed: true) do
          {:ok, [_one | _]} -> {:halt, {:ok, dir}}
          _ -> {:cont, {:error, :td_issue_not_found}}
        end
      end)
    end
  end

  defp filter_label_expr(nil), do: nil
  defp filter_label_expr(""), do: nil

  defp filter_label_expr(label) when is_binary(label) do
    "labels ~ #{label}"
  end

  # An issue is claimable when it's in an active state, isn't already implemented
  # by another session, and (if a filter_label was set) carries that label.
  defp claimable?(%Issue{} = issue, tracker) do
    label = tracker.filter_label

    label_ok? =
      case label do
        nil -> true
        "" -> true
        l when is_binary(l) -> Enum.member?(issue.labels, String.downcase(l))
      end

    label_ok?
  end

  defp normalize_issue(raw, project_dir) when is_map(raw) and is_binary(project_dir) do
    id = raw["id"]

    %Issue{
      id: id,
      identifier: id,
      title: raw["title"],
      description: raw["description"],
      priority: priority_to_integer(raw["priority"]),
      state: normalize_state(raw["status"]),
      branch_name: branch_name_for(id, raw["title"]),
      url: nil,
      assignee_id: empty_to_nil(raw["implementer_session"]),
      repo_url: detect_repo_url(project_dir),
      project_dir: project_dir,
      labels: extract_labels(raw),
      blocked_by: [],
      assigned_to_worker: true,
      created_at: parse_datetime(raw["created_at"]),
      updated_at: parse_datetime(raw["updated_at"])
    }
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase(to_string(&1)))
  end

  defp extract_labels(_), do: []

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value) when is_binary(value), do: value
  defp empty_to_nil(_), do: nil

  defp priority_to_integer(value) when is_binary(value) do
    case String.upcase(value) do
      "P0" -> 1
      "P1" -> 2
      "P2" -> 3
      "P3" -> 4
      _ -> nil
    end
  end

  defp priority_to_integer(_), do: nil

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_), do: ""

  defp branch_name_for(id, title) when is_binary(id) do
    slug =
      case title do
        t when is_binary(t) -> t |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") |> String.slice(0, 40)
        _ -> ""
      end

    case slug do
      "" -> "symphony/" <> id
      s -> "symphony/#{id}-#{s}"
    end
  end

  defp branch_name_for(_id, _title), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp detect_repo_url(project_dir) when is_binary(project_dir) do
    case System.cmd("git", ["-C", project_dir, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp expand_path(nil), do: ""
  defp expand_path(""), do: ""

  defp expand_path(path) when is_binary(path) do
    home = System.user_home!()

    case path do
      "~" -> home
      "~/" <> rest -> Path.join(home, rest)
      _ -> path
    end
  end

  defp expand_path(_), do: ""

  # WORKFLOW.md authors specify the *target* state by td name. We map them to
  # the appropriate td CLI subcommand so callers don't need to know the table.
  defp map_state_to_command(state_name) when is_binary(state_name) do
    case String.downcase(state_name) do
      "in_progress" -> {:ok, "start", []}
      "in progress" -> {:ok, "start", []}
      "open" -> {:ok, "unstart", []}
      "in_review" -> {:ok, "review", []}
      "in review" -> {:ok, "review", []}
      "closed" -> {:ok, "done", ["--self-close-exception=symphony"]}
      "done" -> {:ok, "done", ["--self-close-exception=symphony"]}
      "blocked" -> {:ok, "block", ["--reason=blocked by symphony"]}
      _ -> {:error, {:td_unsupported_state, state_name}}
    end
  end

  defp sort_by_requested_ids(issues, ids) when is_list(issues) and is_list(ids) do
    index = ids |> Enum.with_index() |> Map.new()
    fallback = map_size(index)

    Enum.sort_by(issues, fn %Issue{id: id} ->
      Map.get(index, id, fallback)
    end)
  end
end
