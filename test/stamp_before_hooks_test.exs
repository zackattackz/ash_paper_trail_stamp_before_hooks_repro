defmodule Repro.StampBeforeHooksTest do
  @moduledoc """
  In `:temporal_inline` mode, a non-atomic write is stamped before its
  `before_action` hooks run, so the stamp misses what they do.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias Repro.Blog.{DiffPost, Page, Post}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repro.Repo)
  end

  # Each version's title and `changes`, oldest first.
  defp history(resource, id) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!()
    |> Enum.map(&{&1.title, &1.changes})
  end

  # Each version's `changes`, oldest first.
  defp page_history(id) do
    Page.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!()
    |> Enum.map(& &1.changes)
  end

  describe "an attribute a hook sets" do
    # `increment_views` isn't atomic, so `increment` sets `views` in a
    # `before_action` hook. It's the write's only change.
    test "is stamped as this write's change" do
      post = Ash.create!(Post, %{title: "A"})
      post |> Ash.Changeset.for_update(:increment_views, %{}) |> Ash.update!()

      assert [_created, incremented] =
               Post.Version
               |> Ash.Query.filter(id == ^post.id)
               |> Ash.Query.sort(valid_at: :asc)
               |> Ash.read!()

      assert Map.take(incremented, [:views, :version_action_type, :version_action_name, :changes]) ==
               %{
                 views: 1,
                 version_action_type: :update,
                 version_action_name: :increment_views,
                 changes: %{"views" => 0}
               }
    end
  end

  describe "a record a hook re-reads" do
    # Create "A" and read it. Someone else then updates it to "B". The earlier
    # read is then updated to "C" through an action that re-reads and locks it
    # first (`get_and_lock_for_update()`). That update replaces "B", so its
    # version should store "B" as the title's previous value.
    defp read_then_someone_updates(resource) do
      record = Ash.create!(resource, %{title: "A"})
      read = Ash.get!(resource, record.id)

      resource
      |> Ash.get!(record.id)
      |> Ash.Changeset.for_update(:retitle_locked, %{title: "B"})
      |> Ash.update!()

      read
    end

    defp update_to_c(record, action),
      do: record |> Ash.Changeset.for_update(action, %{title: "C"}) |> Ash.update!()

    test ":previous_values stores the title it replaced" do
      read = read_then_someone_updates(Post)
      update_to_c(read, :retitle_locked)

      assert history(Post.Version, read.id) ==
               [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
    end

    test ":full_diff diffs from the title it replaced" do
      read = read_then_someone_updates(DiffPost)
      update_to_c(read, :retitle_locked)

      assert history(DiffPost.Version, read.id) == [
               {"A", %{"title" => %{"to" => "A"}}},
               {"B", %{"title" => %{"from" => "A", "to" => "B"}}},
               {"C", %{"title" => %{"from" => "B", "to" => "C"}}}
             ]
    end

    test "works: an atomic update stores the title it replaced" do
      read = read_then_someone_updates(Post)
      update_to_c(read, :update)

      assert history(Post.Version, read.id) ==
               [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
    end

    test "works: in :version_resource mode (not temporal), the lock is honored" do
      read = read_then_someone_updates(Page)
      update_to_c(read, :retitle_locked)

      assert page_history(read.id) == [%{}, %{"title" => "A"}, %{"title" => "B"}]
    end
  end
end
