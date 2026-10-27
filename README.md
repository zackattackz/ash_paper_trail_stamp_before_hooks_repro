# AshPaperTrail `:temporal_inline`: the stamp misses what changes a write after its changeset is built

Minimal reproduction for an AshPaperTrail bug. On a temporal resource with
`mode :temporal_inline`, a non-atomic write is stamped (actor, action,
`changes`, metadata) while its changeset is built. Whatever changes the write
after that is missed:

1. **An attribute a `before_action` hook sets**, as Ash's `increment` does
   when the update isn't atomic.
2. **A record a `before_action` hook re-reads**, as `get_and_lock_for_update()`
   does. `:previous_values` and `:full_diff` take the previous values from the
   record the caller passed in, which may be stale.
3. **The attribute of a managed `belongs_to` relationship.** Ash sets it when
   the action runs.
4. **A `before_action` hook added to a built changeset**, as in the
   `Ash.Changeset.before_action/3` docs.
5. **Context set on a built changeset**, such as `paper_trail_metadata`.

When one of these is the write's only change, the write isn't stamped at all,
and the new version keeps the previous version's stamp. Otherwise the stamp
misses the change, or has stale or wrong values. In every case the write
itself is right. Only the version's stamp is wrong.

In the default `:version_resource` mode, the version is built in an
`after_action` hook, after all of this, so none of it happens there.

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
controls. `test/json_api_relationship_route_test.exs` sends a real
`PATCH /posts/:id/relationships/author` through an AshJsonApi router. Of the
15 tests, the 11 that show the bug fail and the 4 controls pass.

**1. An attribute a hook sets.** Create "A", then run `increment_views`, whose
only change is `views` from 0 to 1, set in a `before_action` hook:

| | Stored on the new version | Expected |
|---|---|---|
| `version_action_type` | `:create` | `:update` |
| `version_action_name` | `:create` | `:increment_views` |
| `changes` | `%{}` | `%{"views" => 0}` |

**2. A record a hook re-reads.** Create "A" and read it. Someone else then
updates it to "B". The earlier read is then updated to "C" through
`retitle_locked`, which re-reads and locks the record first. That update
replaces "B", so its version should store "B" as the title's previous value:

| Resource | Update to "C" | Stored | Expected |
|---|---|---|---|
| `Post` (`:temporal_inline`, `:previous_values`) | `retitle_locked` | `%{"title" => "A"}` | `%{"title" => "B"}` |
| `DiffPost` (`:temporal_inline`, `:full_diff`) | `retitle_locked` | `%{"title" => %{"from" => "A", "to" => "C"}}` | `"from" => "B"` |
| `Post` (`:temporal_inline`, `:previous_values`) | `update` (atomic), control | `%{"title" => "B"}` | same |
| `Page` (`:version_resource`, `:previous_values`) | `retitle_locked`, control | `%{"title" => "B"}` | same |

**3. A managed `belongs_to`.** Create with author "a", then move to author
"b" through `manage_relationship`:

| Write | Stored | Expected |
|---|---|---|
| `move`, the only change | the create's stamp, `changes: %{}` | `:update`, `:move`, `%{"author_id" => a}` |
| `move` with a title change | `changes: %{"title" => "A"}` | `%{"title" => "A", "author_id" => a}` |
| managed on a built changeset, then `for_update(:update_any)` (as AshJsonApi's relationship routes do) | the create's stamp | `:update`, `:update_any`, `%{"author_id" => a}` |
| `move` in a bulk update (`strategy: :stream`) | the create's stamp | `:update`, `:move`, `%{"author_id" => a}` |
| `PATCH /posts/:id/relationships/author` through AshJsonApi (no user hook; the route manages the relationship on the changeset it builds, then runs `set_author` with no params) | the create's stamp | `:update`, `:set_author`, `%{"author_id" => a}` |
| `create_with_author` on `DiffPost` | `"author_id" => %{"to" => nil}` | `%{"to" => a}` |

**4. A hook added to a built changeset.** `for_update(:update_any)`, then
`before_action` that sets the title to "late", as the write's only change.
The row has the new title but the create's stamp. Expected `:update`,
`:update_any`, `changes: %{"title" => "A"}`.

**5. Context set on a built changeset.** `for_update(:retitle_locked)`, then
`set_context(%{paper_trail_metadata: %{reason: "late"}})`. `Post` stores
`reason: nil`; `Page` (control) stores `"late"`.

**Control: a non-atomic write whose change comes from the action input.**
`retitle_locked` on a fresh record is stamped correctly. The problem is what
changes the write after the changeset is built, not non-atomic writes as such.
