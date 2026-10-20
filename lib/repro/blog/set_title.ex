defmodule Repro.Blog.SetTitle do
  # Sets the title from the `:title` argument. It has no `atomic/3` callback,
  # so an action using it runs non-atomically.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.change_attribute(changeset, :title, Ash.Changeset.get_argument(changeset, :title))

  @impl true
  def temporal_safe?(_opts), do: true
end
