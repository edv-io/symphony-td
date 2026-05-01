defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.

  Tools surfaced to the agent are gated by the configured tracker kind:

    * `linear_graphql` — only when `tracker.kind == "linear"` (or unset)
    * `td_cli`        — only when `tracker.kind == "td"`

  Unknown tools return a structured error to the agent rather than raising.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Td.Cli, as: TdCli

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @td_cli_tool "td_cli"
  @td_cli_description """
  Run an allowlisted `td` CLI command against the project that owns the current issue.

  Allowed subcommands: comment (add a comment), start, unstart, review, approve, reject,
  done (close), handoff (record progress), log (append note), block, unblock.

  Destructive operations (delete, restore, update) are not exposed.
  """

  @impl_subcommands TdCli.allowed_write_subcommands()

  @td_cli_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["subcommand", "issue_id"],
    "properties" => %{
      "subcommand" => %{
        "type" => "string",
        "enum" => @impl_subcommands,
        "description" => "td CLI subcommand to invoke."
      },
      "issue_id" => %{
        "type" => "string",
        "description" => "td issue id (e.g. td-2c2676) to operate on."
      },
      "project_dir" => %{
        "type" => ["string", "null"],
        "description" => "Optional project directory. Defaults to fan-out lookup against the configured projects."
      },
      "args" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "Optional extra positional arguments. The first arg is the comment body for `comment`, the message for `block`, etc."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @td_cli_tool ->
        execute_td_cli(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case configured_tracker_kind() do
      "td" ->
        [td_cli_tool_spec()]

      _ ->
        [linear_graphql_tool_spec()]
    end
  end

  defp linear_graphql_tool_spec do
    %{
      "name" => @linear_graphql_tool,
      "description" => @linear_graphql_description,
      "inputSchema" => @linear_graphql_input_schema
    }
  end

  defp td_cli_tool_spec do
    %{
      "name" => @td_cli_tool,
      "description" => @td_cli_description,
      "inputSchema" => @td_cli_input_schema
    }
  end

  defp configured_tracker_kind do
    case Config.settings() do
      {:ok, settings} -> settings.tracker.kind
      _ -> nil
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(linear_error_reason(reason)))
    end
  end

  # Normalize bare error reasons coming from the linear path so the
  # generic fallback formatter still produces a Linear-flavored message.
  defp linear_error_reason(:linear_invalid_arguments), do: :linear_invalid_arguments
  defp linear_error_reason(:missing_query), do: :missing_query
  defp linear_error_reason(:invalid_variables), do: :invalid_variables
  defp linear_error_reason(:missing_linear_api_token), do: :missing_linear_api_token
  defp linear_error_reason({:linear_api_status, _} = reason), do: reason
  defp linear_error_reason({:linear_api_request, _} = reason), do: reason
  defp linear_error_reason(other), do: {:linear_error, other}

  defp execute_td_cli(arguments, opts) do
    td_runner = Keyword.get(opts, :td_runner, &TdCli.write/4)
    td_lister = Keyword.get(opts, :td_lister, &TdCli.list_json/2)

    with {:ok, subcommand, issue_id, project_dir, args} <- normalize_td_arguments(arguments),
         {:ok, dir} <- resolve_td_project_dir(project_dir, issue_id, td_lister),
         :ok <- td_runner.(dir, subcommand, issue_id, args) do
      success_payload =
        Jason.encode!(
          %{
            "tool" => @td_cli_tool,
            "subcommand" => subcommand,
            "issue_id" => issue_id,
            "project_dir" => dir
          },
          pretty: true
        )

      dynamic_tool_response(true, success_payload)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_td_arguments(arguments) when is_map(arguments) do
    with {:ok, subcommand} <- normalize_required_string(arguments, "subcommand"),
         {:ok, issue_id} <- normalize_required_string(arguments, "issue_id") do
      project_dir = optional_string(arguments, "project_dir")
      args = optional_string_array(arguments, "args")

      cond do
        subcommand not in @impl_subcommands ->
          {:error, {:td_disallowed_subcommand, subcommand}}

        true ->
          {:ok, subcommand, issue_id, project_dir, args}
      end
    end
  end

  defp normalize_td_arguments(_arguments), do: {:error, :td_invalid_arguments}

  defp resolve_td_project_dir(nil, issue_id, td_lister) do
    tracker = Config.settings!().tracker
    dirs = configured_td_dirs(tracker)

    Enum.reduce_while(dirs, {:error, :td_issue_not_found}, fn dir, _acc ->
      case td_lister.(dir, ids: [issue_id], include_closed: true) do
        {:ok, [_one | _]} -> {:halt, {:ok, dir}}
        _ -> {:cont, {:error, :td_issue_not_found}}
      end
    end)
  end

  defp resolve_td_project_dir(dir, _issue_id, _td_lister) when is_binary(dir) and dir != "" do
    {:ok, expand_home(dir)}
  end

  defp configured_td_dirs(%{projects: projects, scope: "all"} = _tracker)
       when is_list(projects) and projects != [] do
    Enum.map(projects, &expand_home/1)
  end

  defp configured_td_dirs(%{projects: projects})
       when is_list(projects) and projects != [] do
    Enum.map(projects, &expand_home/1)
  end

  defp configured_td_dirs(%{scope: "all"}) do
    case TdCli.list_project_dirs() do
      {:ok, dirs} -> dirs
      _ -> []
    end
  end

  defp configured_td_dirs(_), do: []

  defp expand_home(nil), do: nil

  defp expand_home("~"), do: System.user_home!()

  defp expand_home("~/" <> rest) do
    Path.join(System.user_home!(), rest)
  end

  defp expand_home(path) when is_binary(path), do: path

  defp normalize_required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_field, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp optional_string_array(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :linear_invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{"error" => %{"message" => "`linear_graphql` requires a non-empty `query` string."}}
  end

  defp tool_error_payload(:linear_invalid_arguments) do
    %{
      "error" => %{
        "message" =>
          "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:td_invalid_arguments) do
    %{"error" => %{"message" => "`td_cli` arguments must be a JSON object with `subcommand` and `issue_id`."}}
  end

  defp tool_error_payload(:invalid_variables) do
    %{"error" => %{"message" => "`linear_graphql.variables` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" =>
          "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:missing_field, field}) do
    %{"error" => %{"message" => "`td_cli` requires `#{field}`.", "field" => field}}
  end

  defp tool_error_payload({:td_disallowed_subcommand, subcommand}) do
    %{
      "error" => %{
        "message" => "`td_cli` subcommand `#{subcommand}` is not in the allowlist.",
        "allowedSubcommands" => @impl_subcommands
      }
    }
  end

  defp tool_error_payload(:td_issue_not_found) do
    %{
      "error" => %{
        "message" => "Could not find this td issue in any configured project. Verify the id and `tracker.projects` config."
      }
    }
  end

  defp tool_error_payload({:td_cli_error, status, output}) do
    %{
      "error" => %{
        "message" => "td CLI exited with status #{status}.",
        "status" => status,
        "output" => to_string(output)
      }
    }
  end

  defp tool_error_payload({:td_cli_unavailable, binary}) do
    %{"error" => %{"message" => "td CLI binary `#{binary}` not found on PATH."}}
  end

  defp tool_error_payload({:linear_error, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
