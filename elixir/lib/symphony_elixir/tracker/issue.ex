defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Tracker-agnostic, normalized issue representation used by the orchestrator.

  All tracker adapters (Linear, td, Memory) build values of this struct so the
  orchestrator never has to know which backend produced an issue.

  Backend-specific routing data (`repo_url`, `project_dir`) is optional and is
  populated by adapters that need per-issue workspace bootstrap (such as the
  td adapter, where each issue lives in a different repo).
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :repo_url,
    :project_dir,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          repo_url: String.t() | nil,
          project_dir: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
