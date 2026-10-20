# AshPaperTrail `:temporal_inline`: a locked non-atomic update stores the previous values of the stale record it was given

Minimal reproduction for an AshPaperTrail bug. On a temporal resource with
`mode :temporal_inline`, a non-atomic update through an action with
`change get_and_lock_for_update()`, given a record read before someone
else's update, stores the stale record's values as the version's previous
values (`:previous_values`, `:full_diff`), not the values of the record the
lock re-read. In the default `:version_resource` mode, the lock does fix
this.

- ash 3.36.1, ash_postgres 2.15.1, ash_paper_trail 0.8.1, PostgreSQL 18
- The same results on ash `main` (e4fb803). ash_paper_trail's `main` is 0.8.1.
- Elixir 1.20.4, Erlang/OTP 29 (`.tool-versions`)
- `Repro.Blog.Post`: temporal, `mode :temporal_inline`, `:previous_values`.
- `Repro.Blog.DiffPost`: the same, with `:full_diff`.
- `Repro.Blog.Page`: the same as `Post`, not temporal, in the default
  `:version_resource` mode, for comparison.
- Each has a `retitle_locked` action with `change get_and_lock_for_update()`.
  It is non-atomic because `Repro.Blog.SetTitle` has no `atomic/3` callback.
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
`postgres://user:pass@localhost:5432/ash_paper_trail_stale_repro`.

### What it does to the database

`mix test` runs `mix ash.setup` first, which creates and migrates. It never
drops anything. On the server `DATABASE_URL` names, it:

- creates the database `ash_paper_trail_stale_repro` if it doesn't exist;
- installs `btree_gist` and Ash's `ash_*` SQL functions in that database
  only;
- creates `posts`, `diff_posts`, `pages` and `pages_versions` tables.

Each test runs in a transaction that is rolled back, so no rows are left. No
other database is read or changed. To remove what it created:

```sh
mix ecto.drop   # or stop the docker container above (--rm discards it)
```

## What the test does

Each test in `test/stale_previous_values_test.exs` creates "A" and reads it.
Someone else then updates it to "B". The earlier read is then updated to
"C", as a form or LiveView holding it would. That update replaces "B", so its
version should store "B" as the title's previous value.

| Resource | Update to "C" | Stored | Expected |
|---|---|---|---|
| `Post` (`:temporal_inline`, `:previous_values`) | `retitle_locked` | `%{"title" => "A"}` | `%{"title" => "B"}` |
| `DiffPost` (`:temporal_inline`, `:full_diff`) | `retitle_locked` | `%{"title" => %{"from" => "A", "to" => "C"}}` | `"from" => "B"` |
| `Post` (`:temporal_inline`, `:previous_values`) | `update` (atomic) | `%{"title" => "B"}` | same |
| `Page` (`:version_resource`, `:previous_values`) | `retitle_locked` | `%{"title" => "B"}` | same |

The first two tests fail:

```
Assertion with == failed
code:  assert history(Post.Version, read.id) ==
         [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
left:  [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "A"}}]
right: [{"A", %{}}, {"B", %{"title" => "A"}}, {"C", %{"title" => "B"}}]
```

The write itself is right: "C" is current, and "B" is kept in the history.
Only "C"'s stored previous values are wrong.
