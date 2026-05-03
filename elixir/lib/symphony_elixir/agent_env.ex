defmodule SymphonyElixir.AgentEnv do
  @moduledoc """
  Builds the env passed to the agent's child process so it can publish to GitHub
  without escaping the codex sandbox.

  The orchestrator runs on the operator's machine and reads a single
  fine-grained PAT from the macOS keychain (entry name configured via
  `agent.gh_token_keychain`). Per agent run we resolve the token, inject it as
  `GH_TOKEN`, and forward any names listed in `agent.env_passthrough` from the
  orchestrator's own env.

  Trust model: the codex sandbox is a *workspace* boundary, not an *auth*
  boundary. Once the agent gets `GH_TOKEN`, the PAT scope is the only thing
  gating what it can publish. Issue narrowly-scoped PATs and rotate them
  regularly.

  The token is never logged. `inspect/1` on the env list would expose it, so
  callers must treat the env as a positional arg, not a value to render.
  """

  alias SymphonyElixir.Config

  @keychain_executable "/usr/bin/security"
  @keychain_lookup_timeout_ms 3_000

  @typedoc "Env entries suitable for `Port.open` and `System.cmd`."
  @type env :: [{String.t(), String.t()}]

  @doc """
  Resolves the agent env from the current configuration.

  Returns `{:ok, env}` even when `gh_token_keychain` is unset — agents that
  don't need a GitHub token still run. Returns `{:error, reason}` only when a
  configured keychain entry can't be read.
  """
  @spec resolve() :: {:ok, env()} | {:error, term()}
  def resolve do
    settings = Config.settings!()
    resolve(settings)
  end

  @spec resolve(map()) :: {:ok, env()} | {:error, term()}
  def resolve(settings) do
    with {:ok, github} <- resolve_gh_token(settings.agent.gh_token_keychain) do
      passthrough = resolve_passthrough(settings.agent.env_passthrough)
      {:ok, github ++ passthrough}
    end
  end

  @doc """
  Validates that the configured keychain entry can be read.

  Used by the orchestrator at startup so a missing PAT fails fast instead of
  surfacing as a publish failure mid-run. Returns `:ok` when no keychain is
  configured.
  """
  @spec validate!() :: :ok
  def validate! do
    settings = Config.settings!()

    case resolve_gh_token(settings.agent.gh_token_keychain) do
      {:ok, _env} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
          message:
            "agent.gh_token_keychain configured but unreadable: " <>
              format_keychain_error(reason)
    end
  end

  defp resolve_gh_token(nil), do: {:ok, []}
  defp resolve_gh_token(""), do: {:ok, []}

  defp resolve_gh_token(keychain_entry) when is_binary(keychain_entry) do
    case read_keychain(keychain_entry) do
      {:ok, token} -> {:ok, [{"GH_TOKEN", token}]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_passthrough(names) when is_list(names) do
    names
    |> Enum.map(&{&1, System.get_env(&1)})
    |> Enum.reject(fn {_name, value} -> is_nil(value) or value == "" end)
  end

  defp resolve_passthrough(_), do: []

  defp read_keychain(entry) do
    task =
      Task.async(fn ->
        System.cmd(@keychain_executable, ["find-generic-password", "-s", entry, "-w"], stderr_to_stdout: true)
      end)

    case Task.yield(task, @keychain_lookup_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        case String.trim(output) do
          "" -> {:error, {:keychain_entry_empty, entry}}
          token -> {:ok, token}
        end

      {:ok, {_output, status}} ->
        {:error, {:keychain_entry_not_found, entry, status}}

      nil ->
        {:error, {:keychain_lookup_timeout, entry, @keychain_lookup_timeout_ms}}
    end
  end

  defp format_keychain_error({:keychain_entry_not_found, entry, status}),
    do: "entry #{inspect(entry)} not found (security exit #{status})"

  defp format_keychain_error({:keychain_entry_empty, entry}),
    do: "entry #{inspect(entry)} returned an empty value"

  defp format_keychain_error({:keychain_lookup_timeout, entry, timeout_ms}),
    do:
      "lookup of #{inspect(entry)} timed out after #{timeout_ms}ms — " <>
        "the macOS keychain may be locked. Run `security unlock-keychain` and retry."
end
