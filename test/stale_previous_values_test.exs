defmodule Repro.StalePreviousValuesTest do
  @moduledoc """
  Each test creates "A" and reads it. Someone else then updates it to "B".
  The earlier read is then updated to "C", as a form or LiveView holding it
  would. That update replaces "B", so with `change_tracking_mode
  :previous_values` its version's `changes` should be `%{"title" => "B"}`.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias Repro.Blog.{Page, Post}

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

  # Each version's title and stored previous values, oldest first.
  defp post_history(id) do
    Post.Version
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!()
    |> Enum.map(&{&1.title, &1.changes})
  end

  # Each version's stored previous values, oldest first.
  defp page_history(id) do
    Page.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!()
    |> Enum.map(& &1.changes)
  end

  describe ":temporal_inline" do
    test "a non-atomic update with get_and_lock_for_update stores the title it replaced" do
      read = read_then_someone_updates(Post)
      update_to_c(read, :retitle_locked)

      assert post_history(read.id) ==
               [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
    end

    test "a non-atomic update stores the title it replaced" do
      read = read_then_someone_updates(Post)
      update_to_c(read, :retitle)

      assert post_history(read.id) ==
               [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
    end

    test "works: an atomic update stores the title it replaced" do
      read = read_then_someone_updates(Post)
      update_to_c(read, :update)

      assert post_history(read.id) ==
               [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
    end
  end

  describe ":version_resource (not temporal)" do
    test "works: a non-atomic update with get_and_lock_for_update stores the title it replaced" do
      read = read_then_someone_updates(Page)
      update_to_c(read, :retitle_locked)

      assert page_history(read.id) == [%{}, %{"title" => "A"}, %{"title" => "B"}]
    end
  end
end
