defmodule SymphonyElixir.Td.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Td.Adapter

  defmodule FakeCli do
    @moduledoc false

    def list_json(project_dir, opts) do
      send(self(), {:list_json_called, project_dir, opts})

      case Process.get({__MODULE__, project_dir}) do
        nil -> {:ok, []}
        {:error, _} = err -> err
        list when is_list(list) -> {:ok, apply_filters(list, opts)}
      end
    end

    defp apply_filters(list, opts) do
      list
      |> filter_by_ids(opts[:ids])
      |> filter_by_statuses(opts[:statuses])
    end

    defp filter_by_ids(list, nil), do: list
    defp filter_by_ids(list, []), do: list

    defp filter_by_ids(list, ids) when is_list(ids) do
      set = MapSet.new(ids)
      Enum.filter(list, fn issue -> MapSet.member?(set, issue["id"]) end)
    end

    defp filter_by_statuses(list, nil), do: list
    defp filter_by_statuses(list, []), do: list

    defp filter_by_statuses(list, statuses) when is_list(statuses) do
      set = MapSet.new(statuses)
      Enum.filter(list, fn issue -> MapSet.member?(set, issue["status"]) end)
    end

    def write(project_dir, subcommand, issue_id, args) do
      send(self(), {:write_called, project_dir, subcommand, issue_id, args})

      case Process.get({__MODULE__, :write_result}) do
        nil -> :ok
        result -> result
      end
    end

    def list_project_dirs do
      send(self(), :list_project_dirs_called)

      case Process.get({__MODULE__, :project_dirs}) do
        nil -> {:ok, []}
        list -> {:ok, list}
      end
    end
  end

  setup do
    prior_cli = Application.get_env(:symphony_elixir, :td_cli_module)
    Application.put_env(:symphony_elixir, :td_cli_module, FakeCli)
    apply_td_workflow!()

    on_exit(fn ->
      if is_nil(prior_cli) do
        Application.delete_env(:symphony_elixir, :td_cli_module)
      else
        Application.put_env(:symphony_elixir, :td_cli_module, prior_cli)
      end
    end)

    :ok
  end

  describe "fetch_candidate_issues/0" do
    test "fans out across configured projects and filters by symphony label" do
      Process.put({FakeCli, "/work/repo-a"}, [
        td_issue("td-aaaa", "open", labels: ["symphony", "rewire"]),
        td_issue("td-bbbb", "open", labels: ["other"])
      ])

      Process.put({FakeCli, "/work/repo-b"}, [
        td_issue("td-cccc", "in_progress", labels: ["symphony"])
      ])

      assert {:ok, issues} = Adapter.fetch_candidate_issues()
      ids = Enum.map(issues, & &1.id)
      assert "td-aaaa" in ids
      assert "td-cccc" in ids
      refute "td-bbbb" in ids
    end

    test "passes active states and label filter to the cli" do
      Process.put({FakeCli, "/work/repo-a"}, [])
      Process.put({FakeCli, "/work/repo-b"}, [])

      assert {:ok, _} = Adapter.fetch_candidate_issues()
      assert_received {:list_json_called, "/work/repo-a", opts_a}
      assert opts_a[:statuses] == ["open", "in_progress"]
      assert opts_a[:filter] == "labels ~ symphony"
      assert_received {:list_json_called, "/work/repo-b", _}
    end

    test "carries project_dir through to each Issue" do
      Process.put({FakeCli, "/work/repo-a"}, [
        td_issue("td-aaaa", "open", labels: ["symphony"])
      ])

      assert {:ok, [issue]} = Adapter.fetch_candidate_issues()
      assert issue.project_dir == "/work/repo-a"
    end

    test "errors when no projects are configured" do
      apply_td_workflow!(projects: [])

      assert {:error, :td_no_projects_configured} = Adapter.fetch_candidate_issues()
    end

    test "skips projects whose td list errors and returns issues from healthy ones" do
      Process.put({FakeCli, "/work/repo-a"}, {:error, {:td_cli_error, 1, "boom"}})
      Process.put({FakeCli, "/work/repo-b"}, [td_issue("td-cccc", "open", labels: ["symphony"])])

      assert {:ok, [issue]} = Adapter.fetch_candidate_issues()
      assert issue.id == "td-cccc"
    end
  end

  describe "fetch_issues_by_states/1" do
    test "returns empty list for empty input without calling cli" do
      assert {:ok, []} = Adapter.fetch_issues_by_states([])
      refute_received {:list_json_called, _, _}
    end

    test "queries with -a so closed issues are visible" do
      Process.put({FakeCli, "/work/repo-a"}, [td_issue("td-aaaa", "closed")])
      Process.put({FakeCli, "/work/repo-b"}, [])

      assert {:ok, issues} = Adapter.fetch_issues_by_states(["closed"])
      assert [%{id: "td-aaaa", state: "closed"}] = issues
      assert_received {:list_json_called, "/work/repo-a", opts}
      assert opts[:include_closed] == true
      assert opts[:statuses] == ["closed"]
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    test "returns issues sorted in the requested id order" do
      Process.put({FakeCli, "/work/repo-a"}, [
        td_issue("td-aaaa", "in_progress"),
        td_issue("td-bbbb", "closed")
      ])

      Process.put({FakeCli, "/work/repo-b"}, [td_issue("td-cccc", "open")])

      assert {:ok, issues} = Adapter.fetch_issue_states_by_ids(["td-cccc", "td-aaaa"])
      assert Enum.map(issues, & &1.id) == ["td-cccc", "td-aaaa"]
    end

    test "returns empty list for empty input" do
      assert {:ok, []} = Adapter.fetch_issue_states_by_ids([])
    end
  end

  describe "create_comment/2" do
    test "fan-out locates the project then runs td comment" do
      Process.put({FakeCli, "/work/repo-a"}, [])
      Process.put({FakeCli, "/work/repo-b"}, [td_issue("td-cccc", "open")])

      assert :ok = Adapter.create_comment("td-cccc", "ack")

      assert_received {:write_called, "/work/repo-b", "comment", "td-cccc", ["ack"]}
    end

    test "returns an error when the issue cannot be located in any project" do
      Process.put({FakeCli, "/work/repo-a"}, [])
      Process.put({FakeCli, "/work/repo-b"}, [])

      assert {:error, :td_issue_not_found} = Adapter.create_comment("td-zzzz", "hi")
    end
  end

  describe "update_issue_state/2" do
    test "maps in_progress → start" do
      Process.put({FakeCli, "/work/repo-a"}, [td_issue("td-aaaa", "open")])
      Process.put({FakeCli, "/work/repo-b"}, [])

      assert :ok = Adapter.update_issue_state("td-aaaa", "in_progress")
      assert_received {:write_called, "/work/repo-a", "start", "td-aaaa", []}
    end

    test "maps in_review → review" do
      Process.put({FakeCli, "/work/repo-a"}, [td_issue("td-aaaa", "in_progress")])
      Process.put({FakeCli, "/work/repo-b"}, [])

      assert :ok = Adapter.update_issue_state("td-aaaa", "in_review")
      assert_received {:write_called, "/work/repo-a", "review", "td-aaaa", []}
    end

    test "maps closed → done with self-close-exception" do
      Process.put({FakeCli, "/work/repo-a"}, [td_issue("td-aaaa", "in_progress")])
      Process.put({FakeCli, "/work/repo-b"}, [])

      assert :ok = Adapter.update_issue_state("td-aaaa", "closed")
      assert_received {:write_called, "/work/repo-a", "done", "td-aaaa", ["--self-close-exception=symphony"]}
    end

    test "rejects unsupported state names" do
      Process.put({FakeCli, "/work/repo-a"}, [td_issue("td-aaaa", "open")])
      Process.put({FakeCli, "/work/repo-b"}, [])

      assert {:error, {:td_unsupported_state, "Wonderland"}} =
               Adapter.update_issue_state("td-aaaa", "Wonderland")
    end
  end

  describe "issue normalization" do
    test "translates td priority strings to Linear-style integers" do
      Process.put({FakeCli, "/work/repo-a"}, [
        td_issue("td-p0", "open", priority: "P0"),
        td_issue("td-p1", "open", priority: "P1"),
        td_issue("td-p2", "open", priority: "P2"),
        td_issue("td-p3", "open", priority: "P3"),
        td_issue("td-p4", "open", priority: "P4")
      ])

      Process.put({FakeCli, "/work/repo-b"}, [])

      assert {:ok, issues} = Adapter.fetch_issues_by_states(["open"])
      by_id = Map.new(issues, &{&1.id, &1.priority})
      assert by_id["td-p0"] == 1
      assert by_id["td-p1"] == 2
      assert by_id["td-p2"] == 3
      assert by_id["td-p3"] == 4
      assert by_id["td-p4"] == nil
    end

    test "synthesizes a branch name from id and slugified title" do
      Process.put({FakeCli, "/work/repo-a"}, [
        td_issue("td-aaaa", "open", title: "Implement Td Adapter — Phase 1!")
      ])

      Process.put({FakeCli, "/work/repo-b"}, [])

      assert {:ok, [issue]} = Adapter.fetch_issues_by_states(["open"])
      assert issue.branch_name == "symphony/td-aaaa-implement-td-adapter-phase-1"
    end

    test "lowercases labels and treats empty implementer as nil" do
      Process.put({FakeCli, "/work/repo-a"}, [
        td_issue("td-aaaa", "open",
          labels: ["Symphony", "Rewire"],
          implementer_session: ""
        )
      ])

      Process.put({FakeCli, "/work/repo-b"}, [])

      assert {:ok, [issue]} = Adapter.fetch_issues_by_states(["open"])
      assert issue.labels == ["symphony", "rewire"]
      assert issue.assignee_id == nil
    end
  end

  # --- Helpers --------------------------------------------------------------

  defp apply_td_workflow!(opts \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "td",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_active_states: ["open", "in_progress"],
      tracker_terminal_states: ["closed"],
      tracker_projects: Keyword.get(opts, :projects, ["/work/repo-a", "/work/repo-b"]),
      tracker_filter_label: Keyword.get(opts, :filter_label, "symphony")
    )
  end

  defp td_issue(id, status, opts \\ []) do
    %{
      "id" => id,
      "title" => Keyword.get(opts, :title, "Sample Task"),
      "description" => Keyword.get(opts, :description, ""),
      "status" => status,
      "type" => "task",
      "priority" => Keyword.get(opts, :priority, "P2"),
      "labels" => Keyword.get(opts, :labels, ["symphony"]),
      "implementer_session" => Keyword.get(opts, :implementer_session, ""),
      "creator_session" => "ses_test",
      "created_at" => "2026-05-01T10:00:00.000+00:00",
      "updated_at" => "2026-05-01T10:00:00.000+00:00"
    }
  end
end
