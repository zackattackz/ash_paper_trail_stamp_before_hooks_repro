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

  relationships do
    belongs_to :author, Repro.Blog.Author do
      public? true
      temporal_keys {:valid_at, nil}
    end
  end

  actions do
    # No atomic `update`: `:full_diff` can't be tracked atomically.
    defaults [:read, create: [:title]]

    # A managed `belongs_to` on create: Ash sets `author_id` right before the write.
    create :create_with_author do
      accept [:title]
      argument :author_id, :uuid, allow_nil?: false
      change manage_relationship(:author_id, :author, type: :append_and_remove)
    end

    update :retitle_locked do
      require_atomic? false
      accept [:title]
      change get_and_lock_for_update()
    end
  end
end
