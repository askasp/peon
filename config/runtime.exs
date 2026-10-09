import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/beamcode start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :beamcode, BeamcodeWeb.Endpoint, server: true
end

config :beamcode, BeamcodeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# The OpenCode server this app sits in front of. OPENCODE_PASSWORD is the
# server's basic-auth password (OPENCODE_SERVER_PASSWORD on the server side).
if config_env() != :test do
  config :beamcode, :opencode,
    url: System.get_env("OPENCODE_URL", "http://127.0.0.1:4096"),
    username: System.get_env("OPENCODE_USERNAME", "opencode"),
    password: System.get_env("OPENCODE_PASSWORD")

  # Folder on the OpenCode server that holds all projects. Defaults to
  # chatos/ inside the server's working folder.
  config :beamcode, :chatos_root, System.get_env("CHATOS_ROOT")

  # How the OpenCode server reaches this app's MCP endpoint.
  config :beamcode, :gateway_url, System.get_env("GATEWAY_URL")
  config :beamcode, :vault_key, System.get_env("VAULT_KEY")
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :beamcode, BeamcodeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/beamcode_web/router\.ex$",
        ~r"lib/beamcode_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :beamcode, Beamcode.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  bind_ip =
    case :inet.parse_address(String.to_charlist(System.get_env("BIND_IP", "127.0.0.1"))) do
      {:ok, ip} -> ip
      {:error, _} -> raise "BIND_IP is not an IP address: #{System.get_env("BIND_IP")}"
    end

  config :beamcode, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :beamcode, BeamcodeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Loopback by default: a reverse proxy (Caddy) terminates TLS in front.
      # BIND_IP=:: or 0.0.0.0 listens on every interface.
      ip: bind_ip
    ],
    secret_key_base: secret_key_base

  # Every hostname browsers use (public domain, tailnet name), comma-separated,
  # so LiveView accepts their websockets. Unset: only PHX_HOST.
  case System.get_env("CHECK_ORIGIN", "") |> String.split(",", trim: true) do
    [] ->
      :ok

    hosts ->
      config :beamcode, BeamcodeWeb.Endpoint,
        check_origin: Enum.map(hosts, &("//" <> String.trim(&1)))
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :beamcode, BeamcodeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :beamcode, BeamcodeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :beamcode, Beamcode.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
