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
    test "comment requires a body and passes it as the sole positional arg" do
      DynamicTool.execute(
        "td_cli",
        %{"subcommand" => "comment", "issue_id" => "td-2c2676", "body" => "Reproduced locally."},
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "comment", "td-2c2676", ["Reproduced locally."]}
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

    test "block wraps body in -m flag — body cannot be a freestanding arg" do
      DynamicTool.execute(
        "td_cli",
        %{"subcommand" => "block", "issue_id" => "td-2c2676", "body" => "Waiting on access"},
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "block", "td-2c2676", ["-m", "Waiting on access"]}
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

    test "handoff only emits flag pairs from the four named keys" do
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
               "--done",
               "wrote adapter",
               "--done",
               "added tests",
               "--remaining",
               "wire the dynamic tool",
               "--decision",
               "used fan-out",
               "--uncertain",
               "td-all symlink behavior"
             ]

      refute Enum.any?(args, &(&1 in ["--rm-rf /", "-w /other", "evil_extra_field"]))
    end

    test "agent-supplied flag-shaped body for log/comment is passed verbatim — td treats it as positional" do
      # The point is *not* that we reject "--all" as a body — it's that the body is never
      # an argv flag because it's always preceded by the subcommand keyword. td's CLI
      # interprets it as the comment text. We assert the wire shape.
      DynamicTool.execute(
        "td_cli",
        %{"subcommand" => "comment", "issue_id" => "td-2c2676", "body" => "--rm-rf /"},
        td_runner: SpyTd.runner(self()),
        td_lister: SpyTd.lister(self(), "/work/repo-a")
      )

      assert_received {:td_runner_called, "/work/repo-a", "comment", "td-2c2676", ["--rm-rf /"]}
    end
  end
end
