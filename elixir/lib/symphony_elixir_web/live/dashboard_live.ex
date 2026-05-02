defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Config
  alias SymphonyElixir.Td.Adapter, as: TdAdapter
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000
  @kanban_states ~w(open in_progress in_review blocked)
  @closed_state "closed"
  @closed_limit 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:active_tab, :orchestrator)
      |> assign(:kanban, nil)
      |> assign(:symphony_only, false)
      |> assign(:show_closed, false)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    active_tab =
      case socket.assigns.live_action do
        :kanban -> :kanban
        _ -> :orchestrator
      end

    socket =
      socket
      |> assign(:active_tab, active_tab)
      |> maybe_refresh_kanban()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())
     |> maybe_refresh_kanban()}
  end

  @impl true
  def handle_event("refresh_kanban", _params, socket) do
    {:noreply, refresh_kanban(socket)}
  end

  @impl true
  def handle_event("toggle_symphony_only", _params, socket) do
    socket =
      socket
      |> assign(:symphony_only, !socket.assigns.symphony_only)
      |> refresh_kanban()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_closed", _params, socket) do
    socket =
      socket
      |> assign(:show_closed, !socket.assigns.show_closed)
      |> refresh_kanban()

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @active_tab == :kanban do %>
      <.kanban_view kanban={@kanban} symphony_only={@symphony_only} show_closed={@show_closed} />
    <% else %>
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    <% end %>
    """
  end

  defp kanban_view(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              td Queue
            </p>
            <h1 class="hero-title">
              Kanban Board
            </h1>
            <p class="hero-copy">
              Backlog state across configured td projects for the active Symphony workflow.
            </p>
          </div>

          <div class="kanban-actions">
            <button type="button" class="secondary" phx-click="refresh_kanban">
              Refresh
            </button>
          </div>
        </div>
      </header>

      <%= cond do %>
        <% is_nil(@kanban) -> %>
          <section class="section-card">
            <p class="empty-state">Loading kanban board.</p>
          </section>
        <% @kanban.available? == false -> %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Kanban unavailable</h2>
                <p class="section-copy"><%= @kanban.message %></p>
              </div>
            </div>
          </section>
        <% @kanban.error -> %>
          <section class="error-card">
            <h2 class="error-title">
              Kanban unavailable
            </h2>
            <p class="error-copy">
              <strong><%= @kanban.error.code %>:</strong> <%= @kanban.error.message %>
            </p>
          </section>
        <% true -> %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">td tasks</h2>
                <p class="section-copy numeric">
                  Updated <%= @kanban.generated_at %>
                </p>
              </div>

              <div class="kanban-toggle-group">
                <button
                  type="button"
                  class={["secondary", @symphony_only && "toggle-active"]}
                  aria-pressed={to_string(@symphony_only)}
                  phx-click="toggle_symphony_only"
                >
                  Symphony-labelled only
                </button>
                <button
                  type="button"
                  class={["secondary", @show_closed && "toggle-active"]}
                  aria-pressed={to_string(@show_closed)}
                  phx-click="toggle_closed"
                >
                  Show closed (last <%= @kanban.closed_limit %>)
                </button>
              </div>
            </div>

            <div class="kanban-board">
              <section
                :for={state <- @kanban.states}
                class="kanban-column"
                aria-labelledby={"kanban-column-#{state}"}
              >
                <% column = Map.fetch!(@kanban.columns, state) %>
                <header class="kanban-column-header">
                  <h3 id={"kanban-column-#{state}"} class="kanban-column-title">
                    <%= column.title %>
                  </h3>
                  <span class="kanban-count numeric"><%= column.count %></span>
                </header>

                <div class="kanban-card-list">
                  <%= if column.cards == [] do %>
                    <p class="empty-state kanban-empty">No <%= state %> tasks.</p>
                  <% else %>
                    <a
                      :for={card <- column.cards}
                      class="kanban-card"
                      href={card.detail_url}
                      aria-label={card.aria_label}
                      title={card.aria_label}
                    >
                      <div class="kanban-card-topline">
                        <span class="issue-id"><%= card.id %></span>
                        <span class={"priority-chip priority-#{String.downcase(card.priority)}"}>
                          <%= card.priority %>
                        </span>
                      </div>
                      <p class="kanban-card-title"><%= card.title %></p>

                      <div class="kanban-chip-row">
                        <span :if={card.project} class="project-chip"><%= card.project %></span>
                        <span :for={label <- card.labels} class="label-chip"><%= label %></span>
                      </div>
                    </a>
                  <% end %>
                </div>
              </section>
            </div>
          </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp maybe_refresh_kanban(%{assigns: %{active_tab: :kanban}} = socket), do: refresh_kanban(socket)
  defp maybe_refresh_kanban(socket), do: socket

  defp refresh_kanban(socket) do
    assign(
      socket,
      :kanban,
      load_kanban(socket.assigns.symphony_only, socket.assigns.show_closed)
    )
  end

  defp load_kanban(symphony_only?, show_closed?) do
    tracker = Config.settings!().tracker

    if tracker.kind != "td" do
      %{
        available?: false,
        message: "Kanban is only available when tracker.kind is td.",
        error: nil
      }
    else
      states = if show_closed?, do: @kanban_states ++ [@closed_state], else: @kanban_states

      case TdAdapter.fetch_issues_by_states(states) do
        {:ok, issues} ->
          issues
          |> Presenter.kanban_payload(
            filter_label: tracker.filter_label,
            symphony_only?: symphony_only?,
            show_closed?: show_closed?,
            closed_limit: @closed_limit,
            projects: tracker.projects || []
          )
          |> Map.merge(%{available?: true, error: nil})

        {:error, reason} ->
          %{
            available?: true,
            error: %{code: "td_fetch_failed", message: inspect(reason)},
            states: states,
            columns: %{}
          }
      end
    end
  rescue
    error ->
      %{
        available?: true,
        error: %{code: "kanban_load_failed", message: Exception.message(error)},
        states: [],
        columns: %{}
      }
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
