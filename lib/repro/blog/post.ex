defmodule Repro.Blog.Post do
  # A temporal resource in `:temporal_inline` mode, with `:previous_values`.
  use Ash.Resource,
    domain: Repro.Blog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "posts"
    repo Repro.Repo
  end

  temporal do
    strategy :context
    attribute :valid_at
  end

  paper_trail do
    mode :temporal_inline
    version_resource? true
    change_tracking_mode :previous_values
    store_action_name? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :views, :integer, allow_nil?: false, default: 0, public?: true
  end

  actions do
    defaults [:read, create: [:title], update: [:title]]

    # Not atomic, so `increment` sets `views` in a `before_action` hook.
    update :increment_views do
      require_atomic? false
      accept []
      change increment(:views)
    end

    update :retitle_locked do
      require_atomic? false
      argument :title, :string, allow_nil?: false
      change get_and_lock_for_update()
      change Repro.Blog.SetTitle
    end
  end
end
