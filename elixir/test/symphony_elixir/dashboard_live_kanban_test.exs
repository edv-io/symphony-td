defmodule SymphonyElixir.DashboardLiveKanbanTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  defmodule FakeTdCli do
    def list_json(project_dir, opts) do
      recipient = Application.get_env(:symphony_elixir, :fake_td_recipient)
      if is_pid(recipient), do: send(recipient, {:list_json_called, project_dir, opts})

      issues =
        :symphony_elixir
        |> Application.get_env(:fake_td_issues, %{})
        |> Map.get(project_dir, [])

      {:ok, issues}
    end

    def write(project_dir, subcommand, issue_id, args) do
      recipient = Application.get_env(:symphony_elixir, :fake_td_recipient)
      if is_pid(recipient), do: send(recipient, {:write_called, project_dir, subcommand, issue_id, args})

      if subcommand == "update" do
        labels =
          args
          |> Enum.find_value(fn
            "--labels=" <> labels -> labels
            _ -> nil
          end)
          |> to_string()
          |> String.split(",", trim: true)

        update_fake_issue(project_dir, issue_id, labels)
      end

      :ok
    end

    def list_project_dirs do
      dirs =
        :symphony_elixir
        |> Application.get_env(:fake_td_issues, %{})
        |> Map.keys()

      {:ok, dirs}
    end

    defp update_fake_issue(project_dir, issue_id, labels) do
      issues = Application.get_env(:symphony_elixir, :fake_td_issues, %{})

      updated_project_issues =
        issues
        |> Map.get(project_dir, [])
        |> Enum.map(fn
          %{"id" => ^issue_id} = issue -> Map.put(issue, "labels", labels)
          issue -> issue
        end)

      Application.put_env(:symphony_elixir, :fake_td_issues, Map.put(issues, project_dir, updated_project_issues))
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    td_cli_module = Application.get_env(:symphony_elixir, :td_cli_module)
    fake_td_issues = Application.get_env(:symphony_elixir, :fake_td_issues)
    fake_td_recipient = Application.get_env(:symphony_elixir, :fake_td_recipient)

    Application.put_env(:symphony_elixir, :td_cli_module, FakeTdCli)
    Application.put_env(:symphony_elixir, :fake_td_recipient, self())

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      restore_app_env(:td_cli_module, td_cli_module)
      restore_app_env(:fake_td_issues, fake_td_issues)
      restore_app_env(:fake_td_recipient, fake_td_recipient)
    end)

    :ok
  end

  test "kanban tab renders td cards in the right visual columns" do
    repo_a = "/work/repo-a"
    repo_b = "/work/repo-b"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "td",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_projects: [repo_a, repo_b],
      tracker_filter_label: "symphony"
    )

    put_fake_td_issues(%{
      repo_a => [
        td_issue("td-open", "open", title: "Open task", labels: ["ui"]),
        td_issue("td-ready", "Open", title: "Ready task", labels: ["symphony", "ui"]),
        td_issue("td-review", "in_review", title: "Review task", labels: ["symphony"])
      ],
      repo_b => [
        td_issue("td-progress", "in_progress", title: "Progress task", labels: ["ops"]),
        td_issue("td-blocked", "blocked", title: "Blocked task", labels: ["symphony"])
      ]
    })

    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/kanban")

    assert html =~ "Kanban Board"
    assert html =~ "dashboard-tab-active"
    assert column_text(html, "open") =~ "td-open"
    assert column_text(html, "open") =~ "Open task"
    refute column_text(html, "open") =~ "td-ready"
    assert column_text(html, "ready") =~ "td-ready"
    assert column_text(html, "ready") =~ "Ready task"
    assert column_text(html, "in_progress") =~ "td-progress"
    assert column_text(html, "in_review") =~ "td-review"
    assert column_text(html, "blocked") =~ "td-blocked"
    assert html =~ "repo-a"
    assert html =~ "repo-b"
    refute html =~ "Closed"

    assert_received {:list_json_called, ^repo_a, opts}
    assert opts[:statuses] == ["open", "in_progress", "in_review", "blocked"]
  end

  test "symphony-only toggle hides cards without the configured filter label" do
    repo = "/work/repo-a"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "td",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_projects: [repo],
      tracker_filter_label: "symphony"
    )

    put_fake_td_issues(%{
      repo => [
        td_issue("td-labelled", "open", title: "Labelled task", labels: ["symphony"]),
        td_issue("td-unlabelled", "open", title: "Unlabelled task", labels: ["ops"])
      ]
    })

    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/kanban")
    assert html =~ "td-labelled"
    assert html =~ "td-unlabelled"

    html = render_click(view, "toggle_symphony_only")
    assert html =~ "td-labelled"
    refute html =~ "td-unlabelled"
  end

  test "kanban columns render empty states" do
    repo = "/work/repo-a"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "td",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_projects: [repo]
    )

    put_fake_td_issues(%{repo => []})
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/kanban")

    assert column_text(html, "open") =~ "No Open tasks."
    assert column_text(html, "ready") =~ "No Ready tasks."
    assert column_text(html, "in_progress") =~ "No In Progress tasks."
    assert column_text(html, "in_review") =~ "No In Review tasks."
    assert column_text(html, "blocked") =~ "No Blocked tasks."
  end

  test "selecting a card renders the right-side preview pane" do
    repo = "/work/repo-a"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "td",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_projects: [repo],
      tracker_filter_label: "symphony"
    )

    put_fake_td_issues(%{
      repo => [
        td_issue("td-open", "open",
          title: "Open task",
          description: "# Context\n\n- Check preview",
          labels: ["ui", "ops"]
        )
      ]
    })

    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/kanban")

    html =
      view
      |> element("#kanban-card-td-open")
      |> render_click()

    assert html =~ "td-open"
    assert html =~ "Open task"
    assert html =~ "Context"
    assert html =~ "Check preview"
    assert html =~ "Raw JSON"
    assert html =~ "kanban-card-selected"
  end

  test "queue drop event adds the configured filter label and moves the card to Ready" do
    repo = "/work/repo-a"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "td",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_projects: [repo],
      tracker_filter_label: "symphony"
    )

    put_fake_td_issues(%{
      repo => [
        td_issue("td-open", "open", title: "Open task", labels: ["ui"])
      ]
    })

    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/kanban")
    assert column_text(html, "open") =~ "td-open"
    refute column_text(html, "ready") =~ "td-open"

    html = render_hook(view, "queue_issue", %{"id" => "td-open"})

    assert_received {:write_called, ^repo, "update", "td-open", ["--labels=symphony,ui"]}
    refute column_text(html, "open") =~ "td-open"
    assert column_text(html, "ready") =~ "td-open"
  end

  test "queue API adds the configured filter label and returns the updated issue payload" do
    repo = "/work/repo-a"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "td",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_projects: [repo],
      tracker_filter_label: "symphony"
    )

    put_fake_td_issues(%{
      repo => [
        td_issue("td-open", "open", title: "Open task", labels: ["ui"])
      ]
    })

    start_test_endpoint()

    conn = post(build_conn(), "/api/v1/issues/td-open/queue", %{})
    payload = json_response(conn, 200)

    assert_received {:write_called, ^repo, "update", "td-open", ["--labels=symphony,ui"]}
    assert payload["issue_identifier"] == "td-open"
    assert payload["labels"] == ["symphony", "ui"]
  end

  test "queue API returns a clear 4xx error for non-td trackers" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    start_test_endpoint()

    assert json_response(post(build_conn(), "/api/v1/issues/MT-1/queue", %{}), 422) == %{
             "error" => %{
               "code" => "unsupported_tracker",
               "message" => "Queueing is only available when tracker.kind is td."
             }
           }
  end

  test "kanban tab falls back gracefully for non-td trackers" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/kanban")

    assert html =~ "Kanban unavailable"
    assert html =~ "Kanban is only available when tracker.kind is td."
    refute_received {:list_json_called, _, _}
  end

  defp start_test_endpoint do
    orchestrator_name = Module.concat(__MODULE__, :"Orchestrator#{System.unique_integer([:positive])}")

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}
    )

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), debug_errors: true)
      |> Keyword.merge(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp put_fake_td_issues(issues) do
    Application.put_env(:symphony_elixir, :fake_td_issues, issues)
  end

  defp td_issue(id, state, opts) do
    %{
      "id" => id,
      "title" => Keyword.get(opts, :title, id),
      "description" => Keyword.get(opts, :description, ""),
      "status" => state,
      "priority" => Keyword.get(opts, :priority, "P2"),
      "labels" => Keyword.get(opts, :labels, []),
      "created_at" => Keyword.get(opts, :created_at, "2026-01-01T00:00:00Z"),
      "updated_at" => Keyword.get(opts, :updated_at, "2026-01-02T00:00:00Z")
    }
  end

  defp column_text(html, state) do
    html
    |> Floki.parse_document!()
    |> Floki.find("section[aria-labelledby='kanban-column-#{state}']")
    |> Floki.text()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
