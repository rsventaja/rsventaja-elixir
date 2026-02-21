# Ersventaja

## Development

### Option A: Postgres in Docker, app and mix locally

1. Start Postgres: `docker compose up db -d`
2. Load env and run mix (same terminal): `set -a && source .env && set +a`
3. Create DB and migrate: `mix ecto.setup`
4. Start server: `mix phx.server`

Visit [`localhost:4000`](http://localhost:4000).

### Option B: Full stack in Docker

1. Copy `.env.example` to `.env` and set values.
2. Run: `docker compose up --build`
3. App is at `http://localhost` (port 80). Postgres is on `localhost:5432` for local mix if needed.

### Local mix commands (ecto, etc.)

With Postgres running (e.g. `docker compose up db -d`), load env then run mix:

```bash
set -a && source .env && set +a
mix ecto.migrate
mix ecto.rollback
mix ecto.reset
# etc.
```

`.env` must define `DB_HOST=localhost`, `DB_USER`, `DB_PASS`, `DB_NAME` so dev config can connect (see `.env.example`).

---

To start your Phoenix server without Docker:

  * Install dependencies with `mix deps.get`
  * Create and migrate your database with `mix ecto.setup`
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
