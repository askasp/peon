import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :beamcode, Beamcode.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "beamcode_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :beamcode, BeamcodeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "8bbE0C2Zfy2pMNXbd+O/1M3UmTQZU/EcaH02Z9fC9M/MW1ElEelcCkm3WNwLTAfz",
  server: false

# In test we don't send emails
config :beamcode, Beamcode.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Tests stub OpenCode per test: read procedure files every time.
config :beamcode, :procedures_cache_ms, 0

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# No OpenCode connection or scheduler in tests.
config :beamcode, start_workers: false

# Point at a closed port so tests never reach a real OpenCode server.
config :beamcode, :opencode, url: "http://127.0.0.1:9", password: nil
config :beamcode, :composer_catalog_ttl, 0
config :beamcode, :chatos_root, "/tmp/chatos-test"

# The phone app's login waits after a wrong password; not in tests.
config :beamcode, :app_login_delay, 0

# Each user's Home folder is made on first join; tests make their own.
config :beamcode, :ensure_home, false
