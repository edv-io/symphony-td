defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec queue(Conn.t(), map()) :: Conn.t()
  def queue(conn, %{"issue_identifier" => issue_identifier}) do
    tracker = Config.settings!().tracker

    if tracker.kind != "td" do
      error_response(
        conn,
        422,
        "unsupported_tracker",
        "Queueing is only available when tracker.kind is td."
      )
    else
      label = queue_label(tracker.filter_label)

      with {:ok, [_issue | _]} <- Tracker.fetch_issue_states_by_ids([issue_identifier]),
           :ok <- Tracker.add_label(issue_identifier, label),
           {:ok, [updated_issue | _]} <- Tracker.fetch_issue_states_by_ids([issue_identifier]) do
        json(conn, Presenter.issue_detail_payload(updated_issue))
      else
        {:ok, []} ->
          error_response(conn, 404, "issue_not_found", "Issue not found")

        {:error, reason} ->
          error_response(conn, 500, "queue_failed", inspect(reason))
      end
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp queue_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> "symphony"
      trimmed -> trimmed
    end
  end

  defp queue_label(_label), do: "symphony"

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
