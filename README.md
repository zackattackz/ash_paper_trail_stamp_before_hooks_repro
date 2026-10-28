# AshPaperTrail `:temporal_inline`: the stamp misses what changes a write after its changeset is built

Minimal reproduction for an AshPaperTrail bug.

In `:temporal_inline` mode every period row is a version, and the version
columns on it are its stamp: `version_action_type`, `version_action_name`,
the actor's id, `changes`, and any metadata. For a non-atomic write, that
stamp can describe a different write than the one made: the stamp is computed
while the changeset is built, and whatever changes the write after that isn't
seen. The post's own attributes are always written correctly. It's the version
columns on the same row that are wrong.

All cases are non-atomic writes. Atomic writes aren't affected.

1. **An attribute set by a `before_action` hook.** Run a non-atomic
   `increment_views` (`change increment(:views)`) on a fresh post. The row gets
   `views: 1`, but its version columns say the create wrote it, with an empty
   `changes`.
2. **A record re-read by a `before_action` hook.** Read post "A", someone else
   sets it to "B", then update the stale record to "C" through an action with
   `get_and_lock_for_update()`. The row becomes "C", but `changes` says the
   title was "A" before, not "B".
3. **A managed `belongs_to` relationship.** Move a post to another author
   through `manage_relationship`. The row gets the new author, but keeps the
   create's stamp; with another change in the same write, `changes` lacks
   `author_id`. AshJsonApi's relationship routes take this path with no user
   code.
4. **A `before_action` hook added to a built changeset.** The hook's change is
   written, but the row keeps the create's stamp.
5. **Context set on a built changeset.** `paper_trail_metadata` set after
   `for_update` is dropped: the metadata column is `nil`.

In the default `:version_resource` mode none of this happens: the version is
built after the action.

- ash 3.37.2, ash_postgres 2.15.2, ash_paper_trail 0.8.1, ash_json_api 1.8.0,
  PostgreSQL 18 (the latest releases). The same results on ash `main` (096ff3c) and
  ash_postgres `main` (02bf3a7), as of 2026-10-27. ash_paper_trail's `main` is 0.8.1.
- Elixir 1.20.4, Erlang/OTP 29 (`.tool-versions`)
- `Repro.Blog.Post`: temporal, `mode :temporal_inline`, `:previous_values`,
  with a `belongs_to :author`, a `reason` metadata field, and an AshJsonApi
  `patch_relationship :author` route served by `Repro.JsonApiRouter`.
- `Repro.Blog.DiffPost`: the same, with `:full_diff`.
- `Repro.Blog.Page`: the same as `Post`, not temporal, in the default
  `:version_resource` mode, for comparison.
- `Repro.Blog.Author`: the target of the `belongs_to`.
- Every update action is `require_atomic? false` except `Post`'s `update`,
  which is `require_atomic? true` and is used as a control. `retitle_locked`
  uses `change get_and_lock_for_update()`, which can't run atomically. The
  relationship route runs the primary update, `set_author`, which declares
  the `:author` argument and `manage_relationship` change the route requires.

## Run

It needs PostgreSQL 18. The default `DATABASE_URL` points at port **54321**,
not 5432, so it doesn't use a Postgres you already run. A throwaway server:

```sh
docker run --rm -p 54321:5432 -e POSTGRES_PASSWORD=postgres postgres:18
```

Then:

```sh
mix deps.get
mix test
```

To use another server, set `DATABASE_URL`, for example
`postgres://user:pass@localhost:5432/ash_paper_trail_stamp_repro`.

### What it does to the database

`mix test` runs `mix ash.setup` first, which creates and migrates. It never
drops anything. On the server `DATABASE_URL` names, it:

- creates the database `ash_paper_trail_stamp_repro` if it doesn't exist;
- installs `btree_gist` and Ash's `ash_*` SQL functions in that database
  only;
- creates `authors`, `posts`, `diff_posts`, `pages` and `pages_versions`
  tables.

Each test runs in a transaction that is rolled back, so no rows are left. No
other database is read or changed. To remove what it created:

```sh
mix ecto.drop   # or stop the docker container above (--rm discards it)
```

## What the tests do

`test/temporal_inline_stamp_test.exs` has one `describe` per case above, and
control tests. `test/json_api_relationship_route_test.exs` sends a real
`PATCH /posts/:id/relationships/author` through an AshJsonApi router. Of the
15 tests, the 11 that show the bug fail and the 4 controls pass. Each failing
assertion has a `# Fails:` comment above it with what is stored.

Each test creates a post titled "A" (with author `a` where an author is
involved), performs one more write, then reads the newest version of the post
back and checks the fields named in the last two columns:

| Case | The write | What the new version stores | What it should store |
|---|---|---|---|
| 1 | `increment_views`: its hook sets `views` from 0 to 1, nothing else changes | `version_action_type: :create`, `version_action_name: :create`, `changes: %{}` | `version_action_type: :update`, `version_action_name: :increment_views`, `changes: %{"views" => 0}` |
| 2 | `retitle_locked` to "C" on a stale read of "A", after someone else set "B" (`Post`, `:previous_values`) | `changes: %{"title" => "A"}` | `changes: %{"title" => "B"}` |
| 2 | the same on `DiffPost` (`:full_diff`) | `changes: %{"title" => %{"from" => "A", "to" => "C"}}` | `changes: %{"title" => %{"from" => "B", "to" => "C"}}` |
| 3 | `move` to author `b`, nothing else changes | `version_action_type: :create`, `version_action_name: :create`, `changes: %{}` | `version_action_type: :update`, `version_action_name: :move`, `changes: %{"author_id" => <a's id>}` |
| 3 | `move` to author `b` and set the title to "B" | `changes: %{"title" => "A"}` | `changes: %{"title" => "A", "author_id" => <a's id>}` |
| 3 | `manage_relationship(:author, ...)` on a new changeset, then `for_update(:update_any)` | `version_action_type: :create`, `version_action_name: :create`, `changes: %{}` | `version_action_type: :update`, `version_action_name: :update_any`, `changes: %{"author_id" => <a's id>}` |
| 3 | `move` in a bulk update (`strategy: :stream`) | `version_action_type: :create`, `version_action_name: :create`, `changes: %{}` | `version_action_type: :update`, `version_action_name: :move`, `changes: %{"author_id" => <a's id>}` |
| 3 | `PATCH /posts/:id/relationships/author` through an AshJsonApi router | `version_action_type: :create`, `version_action_name: :create`, `changes: %{}` | `version_action_type: :update`, `version_action_name: :set_author`, `changes: %{"author_id" => <a's id>}` |
| 3 | `create_with_author` on `DiffPost` | `changes["author_id"]: %{"to" => nil}` | `changes["author_id"]: %{"to" => <a's id>}` |
| 4 | `for_update(:update_any)`, then a `before_action` that sets the title to "late", nothing else changes | `version_action_type: :create`, `version_action_name: :create`, `changes: %{}` | `version_action_type: :update`, `version_action_name: :update_any`, `changes: %{"title" => "A"}` |
| 5 | `for_update(:retitle_locked)` to "B", then `set_context(%{paper_trail_metadata: %{reason: "late"}})` | `reason: nil` | `reason: "late"` |

In every row the row itself is right: `views` is 1, the title is "C" or
"late", `author_id` is `b`'s. The other four tests are controls, and pass:

| Control | The write | What the new version stores |
|---|---|---|
| atomic update | the stale read of "A" updated to "C" through the atomic `update` action | `changes: %{"title" => "B"}` |
| `:version_resource` mode | the same through `retitle_locked` on `Page` | `changes: %{"title" => "B"}` |
| `:version_resource` mode | `for_update` then `set_context(%{paper_trail_metadata: ...})` on `Page` | `reason: "late"` |
| non-atomic, input only | `retitle_locked` to "B" on a fresh record | `version_action_type: :update`, `version_action_name: :retitle_locked`, `changes: %{"title" => "A"}` |

The last control shows that a non-atomic write is stamped correctly when
nothing changes it after the changeset is built. The problem is the late
changes, not non-atomic writes as such.
