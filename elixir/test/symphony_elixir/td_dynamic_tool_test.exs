defmodule SymphonyElixir.Codex.TdDynamicToolTest do
  @moduledoc """
  Security-focused tests for the `td_cli` dynamic tool — covers the codex
  adversarial-review findings from 2026-05-01:

    1. Agent must not be able to choose a `project_dir` outside the configured projects.
    2. Agent-supplied free text must never reach the CLI as a flag (`--all`, `-w`, etc).
    3. Per-subcommand argument shape is enforced.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  defmodule SpyTd do
    @moduledoc false

    def runner(captured_pid) do
      fn dir, subcommand, issue_id, args ->
        send(captured_pid, {:td_runner_called, dir, subcommand, issue_id, args})
        :ok
      end
    end

    def lister(captured_pid, dir_with_issue) do
      fn dir, opts ->
        send(captured_pid, {:td_lister_called, dir, opts})

        if dir == dir_with_issue do
          {:ok, [%{"id" => List.first(opts[:ids] || [""])}]}
        else
          {:ok, []}
        end
      end
    end
  end

  setup do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "td",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_active_states: ["open", "in_progress"],
      tracker_terminal_states: ["closed"],
      tracker_projects: ["/work/repo-a", "/work/repo-b"],
      tracker_filter_label: "symphony"
    )

    :ok
  end

  describe "tool spec" do
    test "exposes only typed `body` and `handoff` fields — no raw args or project_dir" do
      [%{"inputSchema" => schema}] = DynamicTool.tool_specs()
      props = schema["properties"]

      assert Map.has_key?(props, "subcommand")
      assert Map.has_key?(props, "issue_id")
      assert Map.has_key?(props, "body")
      assert Map.has_key?(props, "handoff")

      refute Map.has_key?(props, "project_dir"),
             "project_dir must not be advertised to the agent — it would let the agent escape the configured project scope"

      refute Map.has_key?(props, "args"),
             "raw args must not be advertised to the agent — it would let the agent inject td flags like --all or -w"

      assert schema["additionalProperties"] == false
    end
  end

  describe "issue id validation" do
    test "rejects flag-shaped issue ids" do
      response = DynamicTool.execute("td_cli", %{"subcommand" => "review", "issue_id" => "-w"})
      assert response["success"] == false
      payload = Jason.decode!(response["output"])
      assert payload["error"]["message"] =~ "issue_id"
    end

    test "rejects issue ids with shell metacharacters" do
      response =
        DynamicTool.execute("td_cli", %{"subcommand" => "review", "issue_id" => "td-x; rm -rf /"})

      assert response["success"] == false
      payload = Jason.decode!(response["output"])
      assert payload["error"]["message"] =~ "issue_id"
    end

    test "accepts well-formed td ids" do
      response =
        DynamicTool.execute(
          "td_cli",
          %{"subcommand" => "review", "issue_id" => "td-2c2676"},
          td_runner: SpyTd.runner(self()),
          td_lister: SpyTd.lister(self(), "/work/repo-a")
        )

      assert response["success"] == true
      assert_received {:td_runner_called, "/work/repo-a", "review", "td-2c2676", []}
    end
  end

  describe "project scope enforcement" do
    test "ignores any agent-supplied project_dir field" do
      DynamicTool.execute(
        "td_cli",
        %{
          "subcommand" => "review",
          "issue_id" => "td-2c2676",
          "project_dir" => "/some/other/repo"
        },
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-b")
      )

      assert_received {:td_runner_called, "/work/repo-b", "review", "td-2c2676", []}
      refute_received {:td_runner_called, "/some/other/repo", _, _, _}
    end

    test "errors when issue is not in any configured project" do
      response =
        DynamicTool.execute(
          "td_cli",
          %{"subcommand" => "review", "issue_id" => "td-zzzzzz"},
          td_runner: SpyTd.runner(self()),
          td_lister: SpyTd.lister(self(), "/some/other/repo")
        )

      assert response["success"] == false
      payload = Jason.decode!(response["output"])
      assert payload["error"]["message"] =~ "not find this td issue"
    end
  end

  describe "argument shape per subcommand" do
    test "comment requires a body and passes it after a -- separator" do
      DynamicTool.execute(
        "td_cli",
        %{"subcommand" => "comment", "issue_id" => "td-2c2676", "body" => "Reproduced locally."},
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "comment", "td-2c2676", ["--", "Reproduced locally."]}
    end

    test "comment without body is rejected" do
      response =
        DynamicTool.execute(
          "td_cli",
          %{"subcommand" => "comment", "issue_id" => "td-2c2676"},
          td_runner: SpyTd.runner(self()),
          td_lister: SpyTd.lister(self(), "/work/repo-a")
        )

      assert response["success"] == false
      payload = Jason.decode!(response["output"])
      assert payload["error"]["message"] =~ "body"
    end

    test "block wraps body in --reason= flag (literal value, body cannot be a freestanding arg)" do
      DynamicTool.execute(
        "td_cli",
        %{"subcommand" => "block", "issue_id" => "td-2c2676", "body" => "Waiting on access"},
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "block", "td-2c2676", ["--reason=Waiting on access"]}
    end

    test "no-arg subcommands receive empty arg list even if body is supplied" do
      DynamicTool.execute(
        "td_cli",
        %{
          "subcommand" => "review",
          "issue_id" => "td-2c2676",
          "body" => "this should be ignored"
        },
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "review", "td-2c2676", []}
    end

    test "handoff only emits flag=value pairs from the four named keys" do
      DynamicTool.execute(
        "td_cli",
        %{
          "subcommand" => "handoff",
          "issue_id" => "td-2c2676",
          "handoff" => %{
            "done" => ["wrote adapter", "added tests"],
            "remaining" => ["wire the dynamic tool"],
            "decision" => ["used fan-out"],
            "uncertain" => ["td-all symlink behavior"],
            "evil_extra_field" => ["--rm-rf /", "-w /other"]
          }
        },
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "handoff", "td-2c2676", args}

      assert args == [
               "--done=wrote adapter",
               "--done=added tests",
               "--remaining=wire the dynamic tool",
               "--decision=used fan-out",
               "--uncertain=td-all symlink behavior"
             ]

      refute Enum.any?(args, &String.contains?(&1, "evil_extra_field"))
      refute Enum.any?(args, &String.contains?(&1, "--rm-rf"))
      refute Enum.any?(args, &String.contains?(&1, "-w /other"))
    end

    test "handoff rejects values that would invoke td's @file or - stdin literal" do
      response =
        DynamicTool.execute(
          "td_cli",
          %{
            "subcommand" => "handoff",
            "issue_id" => "td-2c2676",
            "handoff" => %{"done" => ["@/etc/passwd"]}
          },
          td_runner: SpyTd.runner(self()),
          td_lister: SpyTd.lister(self(), "/work/repo-a")
        )

      assert response["success"] == false
      payload = Jason.decode!(response["output"])
      assert payload["error"]["message"] =~ "stdin or a file"
      refute_received {:td_runner_called, _, _, _, _}
    end

    test "handoff rejects bare - (stdin)" do
      response =
        DynamicTool.execute(
          "td_cli",
          %{
            "subcommand" => "handoff",
            "issue_id" => "td-2c2676",
            "handoff" => %{"remaining" => ["-"]}
          },
          td_runner: SpyTd.runner(self()),
          td_lister: SpyTd.lister(self(), "/work/repo-a")
        )

      assert response["success"] == false
      payload = Jason.decode!(response["output"])
      assert payload["error"]["message"] =~ "stdin or a file"
    end

    test "comment rejects body that would be td's @file primitive" do
      response =
        DynamicTool.execute(
          "td_cli",
          %{"subcommand" => "comment", "issue_id" => "td-2c2676", "body" => "@/etc/passwd"},
          td_runner: SpyTd.runner(self()),
          td_lister: SpyTd.lister(self(), "/work/repo-a")
        )

      assert response["success"] == false
      payload = Jason.decode!(response["output"])
      assert payload["error"]["message"] =~ "stdin or a file"
    end

    test "done supplies --self-close-exception so agents can close their own work" do
      DynamicTool.execute(
        "td_cli",
        %{"subcommand" => "done", "issue_id" => "td-2c2676"},
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "done", "td-2c2676", ["--self-close-exception=symphony"]}
    end

    test "close mirrors done with --self-close-exception" do
      DynamicTool.execute(
        "td_cli",
        %{"subcommand" => "close", "issue_id" => "td-2c2676"},
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "close", "td-2c2676", ["--self-close-exception=symphony"]}
    end

    test "flag-shaped comment body is preserved literally after the -- separator" do
      DynamicTool.execute(
        "td_cli",
        %{"subcommand" => "comment", "issue_id" => "td-2c2676", "body" => "--work-dir=/tmp/x"},
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "comment", "td-2c2676", ["--", "--work-dir=/tmp/x"]}
    end

  end

  describe "td adapter state-mapping argv shapes" do
    # Smoke that the adapter (which is the *trusted* path) also uses literal-flag
    # forms (--reason=, --self-close-exception=) so an agent prompt can't smuggle
    # a value through update_issue_state via the comment text or anything else.
    alias SymphonyElixir.Td.Adapter

    defmodule AdapterFakeCli do
      @moduledoc false

      def list_json(project_dir, opts) do
        send(self(), {:adapter_list_json, project_dir, opts})

        case Process.get({__MODULE__, project_dir}) do
          nil -> {:ok, []}
          list when is_list(list) -> {:ok, filter_ids(list, opts[:ids])}
        end
      end

      def write(project_dir, subcommand, issue_id, args) do
        send(self(), {:adapter_write, project_dir, subcommand, issue_id, args})
        :ok
      end

      def list_project_dirs do
        {:ok, []}
      end

      defp filter_ids(list, nil), do: list
      defp filter_ids(list, []), do: list

      defp filter_ids(list, ids) when is_list(ids) do
        set = MapSet.new(ids)
        Enum.filter(list, &MapSet.member?(set, &1["id"]))
      end
    end

    setup do
      prior_cli = Application.get_env(:symphony_elixir, :td_cli_module)
      Application.put_env(:symphony_elixir, :td_cli_module, AdapterFakeCli)

      Process.put({AdapterFakeCli, "/work/repo-a"}, [
        %{"id" => "td-aaaa", "title" => "x", "status" => "open", "priority" => "P2", "labels" => ["symphony"]}
      ])

      on_exit(fn ->
        if is_nil(prior_cli) do
          Application.delete_env(:symphony_elixir, :td_cli_module)
        else
          Application.put_env(:symphony_elixir, :td_cli_module, prior_cli)
        end
      end)

      :ok
    end

    test "blocked maps to --reason=<...> not -m" do
      assert :ok = Adapter.update_issue_state("td-aaaa", "blocked")
      assert_received {:adapter_write, "/work/repo-a", "block", "td-aaaa", ["--reason=blocked by symphony"]}
    end

    test "closed maps to --self-close-exception=<...> (literal form)" do
      assert :ok = Adapter.update_issue_state("td-aaaa", "closed")
      assert_received {:adapter_write, "/work/repo-a", "done", "td-aaaa", ["--self-close-exception=symphony"]}
    end
  end
end
