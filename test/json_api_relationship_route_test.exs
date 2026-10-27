defmodule Repro.JsonApiRelationshipRouteTest do
  @moduledoc """
  AshJsonApi's relationship routes manage the relationship on a changeset they
  build, then run the primary update with no params. No user hook is involved.
  """
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  require Ash.Query

  alias Repro.Blog.{Author, Post}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repro.Repo)
    %{a: Ash.create!(Author, %{name: "a"}), b: Ash.create!(Author, %{name: "b"})}
  end

  test "PATCH /posts/:id/relationships/author is stamped as this write's change", %{a: a, b: b} do
    post = Ash.create!(Post, %{title: "A", author_id: a.id})

    conn =
      :patch
      |> conn("/posts/#{post.id}/relationships/author", Jason.encode!(%{data: [%{type: "author", id: b.id}]}))
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> Repro.JsonApiRouter.call(Repro.JsonApiRouter.init([]))

    assert conn.status == 200, "#{conn.status}: #{conn.resp_body}"

    assert [_created, moved] =
             Post.Version
             |> Ash.Query.filter(id == ^post.id)
             |> Ash.Query.sort(valid_at: :asc)
             |> Ash.read!()

    assert moved.author_id == b.id

    # Fails: the create's stamp, changes: %{}
    assert Map.take(moved, [:version_action_type, :version_action_name, :changes]) == %{
             version_action_type: :update,
             version_action_name: :set_author,
             changes: %{"author_id" => a.id}
           }
  end
end
