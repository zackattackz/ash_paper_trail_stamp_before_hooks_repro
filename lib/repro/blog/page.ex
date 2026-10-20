defmodule Repro.Blog.Page do
  # The same resource, not temporal, in the default `:version_resource` mode,
  # for comparison.
  use Ash.Resource,
    domain: Repro.Blog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "pages"
    repo Repro.Repo
  end

  paper_trail do
    change_tracking_mode :previous_values
    store_action_name? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end

  actions do
    # No atomic `update`: `:previous_values` can't be tracked atomically
    # outside `:temporal_inline`.
    defaults [:read, create: [:title]]

    update :retitle_locked do
      require_atomic? false
      argument :title, :string, allow_nil?: false
      change get_and_lock_for_update()
      change Repro.Blog.SetTitle
    end
  end
end
