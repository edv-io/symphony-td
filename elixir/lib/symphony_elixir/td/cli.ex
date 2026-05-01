defmodule SymphonyElixir.Td.Cli do
  @moduledoc """
  Thin wrapper around the `td` CLI for tracker reads and writes.

  Allowlists the subcommands the orchestrator and the Codex agent are allowed
  to run so a misbehaving prompt or workflow cannot soft-delete tasks, restore
  deleted work, or rewrite history out of band. Every CLI call is fully scoped
  with `-w <project_dir>` so a stray cwd never picks up the wrong td database.
  """

  require Logger

  @type subcommand :: String.t()
  @type project_dir :: String.t()
  @type issue_id :: String.t()

  @allowed_write_subcommands ~w(start unstart review approve reject done close comment handoff log block unblock)

  @doc """
  List issues in `project_dir` as decoded JSON.

  Options:

    * `:statuses` — list of td status names (e.g. `["open", "in_progress"]`); maps to repeated `-s` flags
    * `:filter`   — raw TDQ expression passed via `-f`
    * `:ids`      — list of td ids; maps to repeated `-i` flags
    * `:include_closed` — include closed/deferred (`-a`)
    * `:limit` — `-n N`
  """
  @spec list_json(project_dir(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_json(project_dir, opts \\ []) when is_binary(project_dir) do
    args = ["-w", project_dir, "list", "--json"] ++ build_list_flags(opts)

    case run(args) do
      {:ok, output} -> parse_json_array(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Show one issue by id as decoded JSON.
  """
  @spec show_json(project_dir(), issue_id()) :: {:ok, map()} | {:error, term()}
  def show_json(project_dir, issue_id) when is_binary(project_dir) and is_binary(issue_id) do
    case run(["-w", project_dir, "show", issue_id, "--json"]) do
      {:ok, output} -> parse_json_object(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Run an allowlisted write subcommand. Unknown subcommands are rejected before
  any process is spawned.
  """
  @spec write(project_dir(), subcommand(), issue_id(), [String.t()]) :: :ok | {:error, term()}
  def write(project_dir, subcommand, issue_id, extra_args \\ [])
      when is_binary(project_dir) and is_binary(subcommand) and is_binary(issue_id) and
             is_list(extra_args) do
    if subcommand in @allowed_write_subcommands do
      args = ["-w", project_dir, subcommand, issue_id] ++ extra_args

      case run(args) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:td_disallowed_subcommand, subcommand}}
    end
  end

  @doc """
  Enumerate td-tracked project directories using the `td-all` wrapper.

  Parses the section headers (`── <path> ──`) `td-all` emits at the start of
  each per-project block. `~` is expanded to the home directory. Falls back to
  an empty list if `td-all` is unavailable.
  """
  @spec list_project_dirs() :: {:ok, [String.t()]} | {:error, term()}
  def list_project_dirs do
    case run([], td_all_binary()) do
      {:ok, output} ->
        {:ok, parse_project_dirs(output)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List of allowlisted write subcommands. Exposed for the Codex `td_cli` dynamic
  tool so the schema and the validator stay in sync.
  """
  @spec allowed_write_subcommands() :: [String.t()]
  def allowed_write_subcommands, do: @allowed_write_subcommands

  defp run(args, binary \\ nil) do
    bin = binary || td_binary()

    try do
      case System.cmd(bin, args, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, output}

        {output, status} ->
          Logger.warning("td CLI exited non-zero binary=#{bin} status=#{status} args=#{inspect(args)} output=#{inspect(output)}")
          {:error, {:td_cli_error, status, output}}
      end
    rescue
      ErlangError -> {:error, {:td_cli_unavailable, bin}}
    end
  end

  defp build_list_flags(opts) do
    Enum.flat_map(opts, fn
      {:statuses, statuses} when is_list(statuses) ->
        Enum.flat_map(statuses, &["-s", to_string(&1)])

      {:filter, expr} when is_binary(expr) and expr != "" ->
        ["-f", expr]

      {:ids, ids} when is_list(ids) ->
        Enum.flat_map(ids, &["-i", to_string(&1)])

      {:include_closed, true} ->
        ["-a"]

      {:limit, n} when is_integer(n) and n > 0 ->
        ["-n", Integer.to_string(n)]

      _ ->
        []
    end)
  end

  defp parse_json_array(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, nil} -> {:ok, []}
      {:ok, _other} -> {:error, :td_unexpected_payload}
      {:error, reason} -> {:error, {:td_json_parse, reason}}
    end
  end

  defp parse_json_object(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, nil} -> {:error, :td_not_found}
      {:ok, _other} -> {:error, :td_unexpected_payload}
      {:error, reason} -> {:error, {:td_json_parse, reason}}
    end
  end

  defp parse_project_dirs(output) when is_binary(output) do
    home = System.user_home!()

    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^── (.+) ──$/, String.trim(line)) do
        [_, path] -> [expand_home(path, home)]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp expand_home("~", home), do: home
  defp expand_home("~/" <> rest, home), do: Path.join(home, rest)
  defp expand_home(path, _home), do: path

  defp td_binary, do: Application.get_env(:symphony_elixir, :td_binary, "td")
  defp td_all_binary, do: Application.get_env(:symphony_elixir, :td_all_binary, "td-all")
end
