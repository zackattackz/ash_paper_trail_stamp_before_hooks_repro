# AshPaperTrail `:temporal_inline`: non-atomic writes are stamped before their `before_action` hooks run

Minimal reproduction for an AshPaperTrail bug. On a temporal resource with
`mode :temporal_inline`, a non-atomic write is stamped while the changeset is
built, before its `before_action` hooks run. The stamp misses what those
hooks do:

- **An attribute a hook sets**, as Ash's `increment` does when the update
  isn't atomic, isn't recorded. When it's the write's only change, the write
  isn't stamped at all, and the new version keeps the previous version's
  stamp: here, it says it was written by the create.
- **A record a hook re-reads**, as `get_and_lock_for_update()` does, is
  ignored. `:previous_values` and `:full_diff` take the previous values from
  the record the caller passed in, which may be stale.

In the default `:version_resource` mode, the version is built after the
hooks, and the lock is honored.

- ash 3.36.1, ash_postgres 2.15.1, ash_paper_trail 0.8.1, PostgreSQL 18
- The same results on ash `main` (e4fb803). ash_paper_trail's `main` is 0.8.1.
- Elixir 1.20.4, Erlang/OTP 29 (`.tool-versions`)
- `Repro.Blog.Post`: temporal, `mode :temporal_inline`, `:previous_values`,
  with a non-atomic `increment_views` action (`change increment(:views)`).
- `Repro.Blog.DiffPost`: the same, with `:full_diff`.
- `Repro.Blog.Page`: the same as `Post`, not temporal, in the default
  `:version_resource` mode, for comparison.
- Each has a `retitle_locked` action with `change get_and_lock_for_update()`.
  It's non-atomic because `Repro.Blog.SetTitle` has no `atomic/3` callback.
- `config :ash, default_actions_require_atomic?: true`, as Ash's installer
  sets it, so `Post`'s default `update` runs atomically.

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
- creates `posts`, `diff_posts`, `pages` and `pages_versions` tables.

Each test runs in a transaction that is rolled back, so no rows are left. No
other database is read or changed. To remove what it created:

```sh
mix ecto.drop   # or stop the docker container above (--rm discards it)
```

## What the test does

`test/stamp_before_hooks_test.exs` has two parts. Three of its five tests
fail.

**An attribute a hook sets.** Create "A", then run `increment_views`, whose
only change is `views` from 0 to 1, set in a `before_action` hook:

| | Stored on the new version | Expected |
|---|---|---|
| `version_action_type` | `:create` | `:update` |
| `version_action_name` | `:create` | `:increment_views` |
| `changes` | `%{}` | `%{"views" => 0}` |

**A record a hook re-reads.** Create "A" and read it. Someone else then
updates it to "B". The earlier read is then updated to "C" through
`retitle_locked`, which re-reads and locks the record first. That update
replaces "B", so its version should store "B" as the title's previous value:

| Resource | Update to "C" | Stored | Expected |
|---|---|---|---|
| `Post` (`:temporal_inline`, `:previous_values`) | `retitle_locked` | `%{"title" => "A"}` | `%{"title" => "B"}` |
| `DiffPost` (`:temporal_inline`, `:full_diff`) | `retitle_locked` | `%{"title" => %{"from" => "A", "to" => "C"}}` | `"from" => "B"` |
| `Post` (`:temporal_inline`, `:previous_values`) | `update` (atomic) | `%{"title" => "B"}` | same |
| `Page` (`:version_resource`, `:previous_values`) | `retitle_locked` | `%{"title" => "B"}` | same |

In each case the write itself is right. Only the version's stamp is wrong.
