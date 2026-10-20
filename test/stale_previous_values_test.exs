defmodule Repro.StalePreviousValuesTest do
  @moduledoc """
  Each test creates "A" and reads it. Someone else then updates it to "B".
  The earlier read is then updated to "C", as a form or LiveView holding it
  would, through an action that re-reads and locks the record first
  (`get_and_lock_for_update()`). That update replaces "B", so its version
  should store "B" as the title's previous value.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias Repro.Blog.{DiffPost, Page, Post}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repro.Repo)
  end

  # Returns the earlier read.
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

  describe ":temporal_inline" do
    test ":previous_values: a locked non-atomic update stores the title it replaced" do
      read = read_then_someone_updates(Post)
      update_to_c(read, :retitle_locked)

      assert history(Post.Version, read.id) ==
               [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
    end

    test ":full_diff: a locked non-atomic update diffs from the title it replaced" do
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
  end

  describe ":version_resource (not temporal)" do
    test "works: a locked non-atomic update stores the title it replaced" do
      read = read_then_someone_updates(Page)
      update_to_c(read, :retitle_locked)

      assert page_history(read.id) == [%{}, %{"title" => "A"}, %{"title" => "B"}]
    end
  end
end
