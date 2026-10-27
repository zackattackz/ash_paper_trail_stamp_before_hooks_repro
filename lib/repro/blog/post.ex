defmodule Repro.Blog.Post do
  # A temporal resource in `:temporal_inline` mode, with `:previous_values`.
  use Ash.Resource,
    domain: Repro.Blog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource]

  json_api do
    type "post"

    routes do
      base "/posts"
      patch_relationship :author
    end
  end

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
    metadata :reason, :string
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :views, :integer, allow_nil?: false, default: 0, public?: true
  end

  relationships do
    belongs_to :author, Repro.Blog.Author do
      public? true
      temporal_keys {:valid_at, nil}
    end
  end

  actions do
    defaults [:read, create: [:title, :author_id]]

    # Atomic, as `defaults [update: [:title]]` would make it under
    # `default_actions_require_atomic? true`. Named here because the relationship route
    # below needs `set_author` to be the primary update.
    update :update do
      require_atomic? true
      accept [:title]
    end

    # A managed `belongs_to`: Ash sets `author_id` when the action runs.
    update :move do
      require_atomic? false
      accept [:title]
      argument :author_id, :uuid, allow_nil?: false
      change manage_relationship(:author_id, :author, type: :append_and_remove)
    end

    # Accepts nothing, so a write through it changes only what hooks or managed
    # relationships on the built changeset change, as with AshJsonApi's relationship routes.
    update :update_any do
      require_atomic? false
      accept []
    end

    # AshJsonApi's `patch_relationship :author` route runs the primary update. It requires
    # the action to declare the relationship as an argument with a `manage_relationship`
    # change, but it manages the relationship on the changeset it builds and runs the
    # action with no params, so the change's argument is absent and only the pre-managed
    # relationship takes effect.
    update :set_author do
      primary? true
      require_atomic? false
      accept []
      argument :author, :map
      change manage_relationship(:author, type: :append_and_remove)
    end

    # Not atomic, so `increment` sets `views` in a `before_action` hook.
    update :increment_views do
      require_atomic? false
      accept []
      change increment(:views)
    end

    update :retitle_locked do
      require_atomic? false
      accept [:title]
      change get_and_lock_for_update()
    end
  end
end
