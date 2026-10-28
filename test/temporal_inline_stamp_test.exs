defmodule Repro.TemporalInlineStampTest do
  @moduledoc """
  In `:temporal_inline` mode, a non-atomic write's version columns can describe a
  different write than the one made: the stamp is computed before hooks run.

  Each `describe` is one case from the issue. Tests named `control:` pass today.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias Repro.Blog.{Author, DiffPost, Page, Post}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repro.Repo)
    %{a: Ash.create!(Author, %{name: "a"}), b: Ash.create!(Author, %{name: "b"})}
  end

  # Every version of a temporal record, oldest first.
  defp versions(version_resource, id) do
    version_resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!()
  end

  # Each version's title and `changes`, oldest first.
  defp history(version_resource, id),
    do: version_resource |> versions(id) |> Enum.map(&{&1.title, &1.changes})

  # How a version says it was written.
  defp stamp(version),
    do: Map.take(version, [:version_action_type, :version_action_name, :changes])

  defp page_versions(id) do
    Page.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!()
  end

  describe "1. an attribute a before_action hook sets" do
    # `increment_views` isn't atomic, so `increment` sets `views` in a
    # `before_action` hook. It's the write's only change.
    test "is stamped as this write's change" do
      post = Ash.create!(Post, %{title: "A"})
      post |> Ash.Changeset.for_update(:increment_views, %{}) |> Ash.update!()

      assert [_created, incremented] = versions(Post.Version, post.id)
      assert incremented.views == 1

      # Fails: the create's stamp, changes: %{}
      assert stamp(incremented) == %{
               version_action_type: :update,
               version_action_name: :increment_views,
               changes: %{"views" => 0}
             }
    end
  end

  describe "2. a record a before_action hook re-reads" do
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

      # Fails: "C" stores "A", the stale read's title, as the previous value
      assert history(Post.Version, read.id) ==
               [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
    end

    test ":full_diff diffs from the title it replaced" do
      read = read_then_someone_updates(DiffPost)
      update_to_c(read, :retitle_locked)

      # Fails: from: "A"
      assert Enum.map(versions(DiffPost.Version, read.id), &{&1.title, &1.changes["title"]}) == [
               {"A", %{"to" => "A"}},
               {"B", %{"from" => "A", "to" => "B"}},
               {"C", %{"from" => "B", "to" => "C"}}
             ]
    end

    test "control: an atomic update stores the title it replaced" do
      read = read_then_someone_updates(Post)
      update_to_c(read, :update)

      assert history(Post.Version, read.id) ==
               [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
    end

    test "control: in :version_resource mode (not temporal), the lock is honored" do
      read = read_then_someone_updates(Page)
      update_to_c(read, :retitle_locked)

      assert Enum.map(page_versions(read.id), & &1.changes) ==
               [%{}, %{"title" => "A"}, %{"title" => "B"}]
    end
  end

  describe "3. a managed belongs_to relationship" do
    # `move` changes only the author, through `manage_relationship`. Ash sets
    # `author_id` when the action runs.
    test "as the only change, is stamped as this write's change", %{a: a, b: b} do
      post = Ash.create!(Post, %{title: "A", author_id: a.id})
      post |> Ash.Changeset.for_update(:move, %{author_id: b.id}) |> Ash.update!()

      assert [_created, moved] = versions(Post.Version, post.id)
      assert moved.author_id == b.id

      # Fails: the create's stamp, changes: %{}
      assert stamp(moved) == %{
               version_action_type: :update,
               version_action_name: :move,
               changes: %{"author_id" => a.id}
             }
    end

    # With another change the write is stamped, but `changes` should still
    # include `author_id`.
    test "with another change, is in changes", %{a: a, b: b} do
      post = Ash.create!(Post, %{title: "A", author_id: a.id})

      post
      |> Ash.Changeset.for_update(:move, %{author_id: b.id, title: "B"})
      |> Ash.update!()

      assert [_created, moved] = versions(Post.Version, post.id)
      assert %{title: "B", author_id: author_id} = moved
      assert author_id == b.id
      # Fails: changes: %{"title" => "A"}, without author_id
      assert moved.changes == %{"title" => "A", "author_id" => a.id}
    end

    # As AshJsonApi's relationship routes do: the relationship is managed on a
    # changeset built for an action that accepts nothing.
    test "managed on a built changeset, is stamped as this write's change", %{a: a, b: b} do
      post = Ash.create!(Post, %{title: "A", author_id: a.id})

      post
      |> Ash.Changeset.new()
      |> Ash.Changeset.manage_relationship(:author, %{id: b.id}, type: :append_and_remove)
      |> Ash.Changeset.for_update(:update_any, %{})
      |> Ash.update!()

      assert [_created, moved] = versions(Post.Version, post.id)
      assert moved.author_id == b.id

      # Fails: the create's stamp, changes: %{}
      assert stamp(moved) == %{
               version_action_type: :update,
               version_action_name: :update_any,
               changes: %{"author_id" => a.id}
             }
    end

    test "in a bulk update, is stamped as this write's change", %{a: a, b: b} do
      post = Ash.create!(Post, %{title: "A", author_id: a.id})

      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_update([post], :move, %{author_id: b.id},
                 strategy: :stream,
                 return_errors?: true
               )

      assert [_created, moved] = versions(Post.Version, post.id)
      assert moved.author_id == b.id

      # Fails: the create's stamp, changes: %{}
      assert stamp(moved) == %{
               version_action_type: :update,
               version_action_name: :move,
               changes: %{"author_id" => a.id}
             }
    end

    # On create, Ash sets `author_id` only right before the write.
    test "on create, is in changes", %{a: a} do
      post =
        Ash.create!(DiffPost, %{title: "A", author_id: a.id}, action: :create_with_author)

      assert [created] = versions(DiffPost.Version, post.id)
      assert created.author_id == a.id
      # Fails: "author_id" => %{"to" => nil}
      assert created.changes == %{"title" => %{"to" => "A"}, "author_id" => %{"to" => a.id}}
    end
  end

  describe "4. a before_action hook added to a built changeset" do
    # As in the `Ash.Changeset.before_action/3` docs. It's the write's only change.
    test "is stamped as this write's change" do
      post = Ash.create!(Post, %{title: "A"})

      post
      |> Ash.Changeset.for_update(:update_any, %{})
      |> Ash.Changeset.before_action(&Ash.Changeset.force_change_attribute(&1, :title, "late"))
      |> Ash.update!()

      assert [_created, updated] = versions(Post.Version, post.id)
      assert updated.title == "late"

      # Fails: the create's stamp, changes: %{}
      assert stamp(updated) == %{
               version_action_type: :update,
               version_action_name: :update_any,
               changes: %{"title" => "A"}
             }
    end
  end

  describe "5. context set on a built changeset" do
    # `paper_trail_metadata` set after `for_update` is read when the version is
    # built. In `:temporal_inline` mode that already happened.
    test "paper_trail_metadata is stored" do
      post = Ash.create!(Post, %{title: "A"})

      post
      |> Ash.Changeset.for_update(:retitle_locked, %{title: "B"})
      |> Ash.Changeset.set_context(%{paper_trail_metadata: %{reason: "late"}})
      |> Ash.update!()

      # Fails: reason: nil
      assert [_created, %{title: "B", reason: "late"}] = versions(Post.Version, post.id)
    end

    test "control: in :version_resource mode, paper_trail_metadata is stored" do
      page = Ash.create!(Page, %{title: "A"})

      page
      |> Ash.Changeset.for_update(:retitle_locked, %{title: "B"})
      |> Ash.Changeset.set_context(%{paper_trail_metadata: %{reason: "late"}})
      |> Ash.update!()

      assert [_created, %{reason: "late"}] = page_versions(page.id)
    end
  end

  describe "control: a non-atomic write whose change comes from the action input" do
    # Nothing changes the write after the changeset is built, so the stamp is right.
    test "is stamped correctly" do
      post = Ash.create!(Post, %{title: "A"})
      post |> Ash.Changeset.for_update(:retitle_locked, %{title: "B"}) |> Ash.update!()

      assert [_created, retitled] = versions(Post.Version, post.id)

      assert stamp(retitled) == %{
               version_action_type: :update,
               version_action_name: :retitle_locked,
               changes: %{"title" => "A"}
             }
    end
  end
end
