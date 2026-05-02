defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var hooks = {
              KanbanDraggableCard: {
                mounted: function () {
                  this.el.addEventListener("dragstart", function (event) {
                    event.dataTransfer.effectAllowed = "move";
                    event.dataTransfer.setData("text/plain", event.currentTarget.dataset.issueId || "");
                    event.currentTarget.classList.add("kanban-card-dragging");
                  });

                  this.el.addEventListener("dragend", function (event) {
                    event.currentTarget.classList.remove("kanban-card-dragging");
                  });
                }
              },
              KanbanDropTarget: {
                mounted: function () {
                  var el = this.el;
                  var self = this;

                  el.addEventListener("dragover", function (event) {
                    event.preventDefault();
                    event.dataTransfer.dropEffect = "move";
                    el.classList.add("kanban-column-drop-hover");
                  });

                  el.addEventListener("dragleave", function (event) {
                    if (!el.contains(event.relatedTarget)) {
                      el.classList.remove("kanban-column-drop-hover");
                    }
                  });

                  el.addEventListener("drop", function (event) {
                    event.preventDefault();
                    el.classList.remove("kanban-column-drop-hover");

                    var id = event.dataTransfer.getData("text/plain");
                    if (id) self.pushEvent("queue_issue", {id: id});
                  });
                }
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              hooks: hooks,
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    assigns = assign_new(assigns, :active_tab, fn -> :orchestrator end)

    ~H"""
    <main class="app-shell">
      <nav class="dashboard-tabs" aria-label="Dashboard views">
        <a class={["dashboard-tab", @active_tab == :orchestrator && "dashboard-tab-active"]} href="/">
          Orchestrator
        </a>
        <a class={["dashboard-tab", @active_tab == :kanban && "dashboard-tab-active"]} href="/kanban">
          Kanban
        </a>
      </nav>
      {@inner_content}
    </main>
    """
  end
end
