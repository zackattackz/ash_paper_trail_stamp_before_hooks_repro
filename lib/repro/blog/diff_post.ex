defmodule Repro.Blog.DiffPost do
  # The same temporal resource, with `:full_diff`.
  use Ash.Resource,
    domain: Repro.Blog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "diff_posts"
    repo Repro.Repo
  end

  temporal do
    strategy :context
    attribute :valid_at
  end

  paper_trail do
    mode :temporal_inline
    version_resource? true
    change_tracking_mode :full_diff
    store_action_name? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end

  actions do
    # No atomic `update`: `:full_diff` can't be tracked atomically.
    defaults [:read, create: [:title]]

    update :retitle_locked do
      require_atomic? false
      argument :title, :string, allow_nil?: false
      change get_and_lock_for_update()
      change Repro.Blog.SetTitle
    end
  end
end
