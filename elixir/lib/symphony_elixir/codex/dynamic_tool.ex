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

  Symphony locates the issue's project via fan-out across the configured `tracker.projects`;
  the agent does not choose the project directory.

  Allowed subcommands: comment, start, unstart, review, approve, reject, done, close,
  handoff, log, block, unblock. Destructive operations (delete, restore, update) are not exposed.

  Subcommand argument shape:
    - `comment`, `log`: pass the body via `body` (string).
    - `block`: pass an optional reason via `body` (becomes `-m <body>`).
    - `handoff`: pass `handoff: { done: [...], remaining: [...], decision: [...], uncertain: [...] }`.
      Each list element becomes a `--<flag> <value>` pair.
    - All other subcommands take no payload — `body` and `handoff` are ignored.
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
      "body" => %{
        "type" => ["string", "null"],
        "description" => "Comment body for `comment`, log line for `log`, or block reason for `block`. Required for those subcommands; ignored for others."
      },
      "handoff" => %{
        "type" => ["object", "null"],
        "additionalProperties" => false,
        "description" => "Structured handoff fields used only when subcommand is `handoff`. Each key is a list of free-text strings.",
        "properties" => %{
          "done" => %{"type" => "array", "items" => %{"type" => "string"}},
          "remaining" => %{"type" => "array", "items" => %{"type" => "string"}},
          "decision" => %{"type" => "array", "items" => %{"type" => "string"}},
          "uncertain" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    }
  }

  @no_arg_subcommands ~w(start unstart review approve reject done close unblock)
  @body_subcommands ~w(comment log)
  @handoff_flags ~w(done remaining decision uncertain)

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

    with {:ok, subcommand, issue_id, body, handoff} <- normalize_td_arguments(arguments),
         {:ok, td_args} <- build_td_args(subcommand, body, handoff),
         {:ok, dir} <- resolve_td_project_dir(issue_id, td_lister),
         :ok <- td_runner.(dir, subcommand, issue_id, td_args) do
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
      body = optional_string(arguments, "body")
      handoff = optional_handoff_payload(arguments)

      cond do
        subcommand not in @impl_subcommands ->
          {:error, {:td_disallowed_subcommand, subcommand}}

        not valid_issue_id?(issue_id) ->
          {:error, {:td_invalid_issue_id, issue_id}}

        true ->
          {:ok, subcommand, issue_id, body, handoff}
      end
    end
  end

  defp normalize_td_arguments(_arguments), do: {:error, :td_invalid_arguments}

  # Build the exact CLI args list per allowlisted subcommand. Only Symphony's
  # own values can produce flags — agent inputs are restricted to free-text
  # bodies and the four handoff fields. No agent string is ever passed as a
  # standalone argv element when it could be interpreted as a flag:
  #
  #   - Free-text positional bodies (comment, log) are preceded by `--` so td's
  #     Cobra parser treats subsequent tokens as positional even when they
  #     start with `-` or contain `--work-dir=...`.
  #   - Flag values (block --reason, handoff --done/...) use the `--flag=value`
  #     form so td treats the value as a literal even if it starts with `-`.
  #   - Handoff and block values are rejected if they would invoke td's `@file`
  #     or `-` (stdin) literal-value mechanisms — those are file-read primitives
  #     that should never be controllable from an untrusted prompt.
  defp build_td_args("comment", body, _) when is_binary(body) and body != "" do
    if td_literal_safe?(body) do
      {:ok, ["--", body]}
    else
      {:error, :td_unsafe_literal_body}
    end
  end

  defp build_td_args("log", body, _) when is_binary(body) and body != "" do
    if td_literal_safe?(body) do
      {:ok, ["--", body]}
    else
      {:error, :td_unsafe_literal_body}
    end
  end

  defp build_td_args("block", body, _) when is_binary(body) and body != "" do
    if td_literal_safe?(body) do
      {:ok, ["--reason=" <> body]}
    else
      {:error, :td_unsafe_literal_body}
    end
  end

  defp build_td_args("block", _, _), do: {:ok, []}

  defp build_td_args("handoff", _body, %{} = handoff) do
    build_handoff_args(handoff)
  end

  defp build_td_args("handoff", _body, _), do: {:ok, []}

  # done / close: agent path mirrors the adapter and supplies the
  # self-close-exception so agents can actually terminate an issue they
  # implemented. Flag uses the `=` form so the literal cannot become argv noise.
  defp build_td_args(sub, _, _) when sub in ["done", "close"] do
    {:ok, ["--self-close-exception=symphony"]}
  end

  defp build_td_args(sub, _, _) when sub in @no_arg_subcommands, do: {:ok, []}

  defp build_td_args(sub, _, _) when sub in @body_subcommands do
    {:error, {:td_missing_body, sub}}
  end

  defp build_td_args(sub, _, _), do: {:error, {:td_disallowed_subcommand, sub}}

  defp build_handoff_args(handoff) when is_map(handoff) do
    Enum.reduce_while(@handoff_flags, {:ok, []}, fn flag, {:ok, acc} ->
      values = handoff[flag] || handoff[String.to_atom(flag)] || []

      values
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, vacc} ->
        if td_literal_safe?(value) do
          {:cont, {:ok, vacc ++ ["--#{flag}=" <> value]}}
        else
          {:halt, {:error, {:td_unsafe_handoff_value, flag}}}
        end
      end)
      |> case do
        {:ok, flag_args} -> {:cont, {:ok, acc ++ flag_args}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Delegates to the shared check in Td.Cli so both the agent path (this module)
  # and the trusted-caller path (Td.Adapter.create_comment/2) reject the same
  # set of values.
  defp td_literal_safe?(value), do: TdCli.literal_safe?(value)

  defp resolve_td_project_dir(issue_id, td_lister) do
    tracker = Config.settings!().tracker
    dirs = configured_td_dirs(tracker)

    if dirs == [] do
      {:error, :td_no_projects_configured}
    else
      Enum.reduce_while(dirs, {:error, :td_issue_not_found}, fn dir, _acc ->
        case td_lister.(dir, ids: [issue_id], include_closed: true) do
          {:ok, [_one | _]} -> {:halt, {:ok, dir}}
          _ -> {:cont, {:error, :td_issue_not_found}}
        end
      end)
    end
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

  # td issue ids look like td-<hex>. Reject anything that could be argv-injected
  # (whitespace, leading dashes, semicolons, etc).
  defp valid_issue_id?(id) when is_binary(id) do
    Regex.match?(~r/\A[A-Za-z0-9_\-]{1,64}\z/, id) and not String.starts_with?(id, "-")
  end

  defp valid_issue_id?(_), do: false

  defp optional_handoff_payload(%{"handoff" => map}) when is_map(map), do: map
  defp optional_handoff_payload(%{handoff: map}) when is_map(map), do: map
  defp optional_handoff_payload(_), do: %{}

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

  defp tool_error_payload(:td_no_projects_configured) do
    %{
      "error" => %{
        "message" => "No td projects are configured. Set `tracker.projects` or `tracker.scope: all` in WORKFLOW.md."
      }
    }
  end

  defp tool_error_payload({:td_invalid_issue_id, issue_id}) do
    %{
      "error" => %{
        "message" => "`td_cli.issue_id` must be a td identifier (alphanumeric/underscore/hyphen, not flag-like).",
        "issue_id" => issue_id
      }
    }
  end

  defp tool_error_payload({:td_missing_body, subcommand}) do
    %{
      "error" => %{
        "message" => "`td_cli` subcommand `#{subcommand}` requires a non-empty `body`.",
        "subcommand" => subcommand
      }
    }
  end

  defp tool_error_payload(:td_unsafe_literal_body) do
    %{
      "error" => %{
        "message" => "`td_cli.body` cannot be `-` or start with `@` — those tell td to read from stdin or a file."
      }
    }
  end

  defp tool_error_payload({:td_unsafe_handoff_value, flag}) do
    %{
      "error" => %{
        "message" => "`td_cli.handoff.#{flag}` values cannot be `-` or start with `@` — those tell td to read from stdin or a file.",
        "flag" => flag
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
