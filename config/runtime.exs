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
#     PHX_SERVER=true bin/ersventaja start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ersventaja, ErsventajaWeb.Endpoint, server: true
end

config :ersventaja, :crypto,
  key: System.get_env("CRYPTO_KEY", "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890")

# WhatsApp Business (Meta) - used by webhook and bot
# WHATSAPP_BASE_URL = URL pública do app (ex: https://rsventaja.com) para links de download
config :ersventaja, :whatsapp,
  app_id: System.get_env("META_APP_ID"),
  app_secret: System.get_env("META_APP_SECRET"),
  verify_token: System.get_env("WHATSAPP_VERIFY_TOKEN", "rsventaja_webhook_verify"),
  phone_number_id: System.get_env("WHATSAPP_PHONE_NUMBER_ID"),
  access_token: System.get_env("WHATSAPP_ACCESS_TOKEN"),
  base_url: System.get_env("WHATSAPP_BASE_URL")

# Segfy — api.automation + Upfy Gate (listagem) via Firebase verifyPassword + api.sso.segfy.com/login
# (valor fora do `config` para evitar ambiguidade de parse com o `if config_env()` abaixo)
skip_gestao_html_list =
  case System.get_env("SEGFY_SKIP_GESTAO_HTML_LIST", "1") do
    v when v in ["0", "false", "no", ""] -> false
    _ -> true
  end

segfy_enabled =
  case System.get_env("SEGFY_ENABLED", "false") do
    v when v in ["1", "true", "yes"] -> true
    _ -> false
  end

multicalculo_socket_enabled =
  case System.get_env("SEGFY_MULTICALCULO_SOCKET", "1") do
    v when v in ["0", "false", "no", ""] -> false
    _ -> true
  end

config :ersventaja, :segfy,
  enabled: segfy_enabled,
  automation_base_url:
    System.get_env("SEGFY_AUTOMATION_BASE_URL", "https://api.automation.segfy.com"),
  gestao_base_url: System.get_env("SEGFY_GESTAO_BASE_URL", "https://gestao.segfy.com"),
  automation_token: System.get_env("SEGFY_AUTOMATION_TOKEN"),
  # JWT curto para api.automation: POST /auths/token + Basic (par no .env ou extraído deste JS)
  automation_client_id: System.get_env("SEGFY_AUTOMATION_CLIENT_ID"),
  automation_client_secret: System.get_env("SEGFY_AUTOMATION_CLIENT_SECRET"),
  auto_bundle_js_url:
    System.get_env("SEGFY_AUTO_BUNDLE_JS_URL", "https://bundles.segfy.com/auto-bundle.js"),
  upfy_gate_base_url: System.get_env("SEGFY_UPFY_GATE_BASE_URL", "https://upfygate.segfy.com"),
  # Referer/Origin ao chamar gestão como iframe a partir do app (multicalculo)
  gate_request_origin: System.get_env("SEGFY_GATE_ORIGIN", "https://app.segfy.com"),
  firebase_web_api_key: System.get_env("SEGFY_FIREBASE_WEB_API_KEY"),
  login_email: System.get_env("SEGFY_LOGIN_EMAIL"),
  login_password: System.get_env("SEGFY_LOGIN_PASSWORD"),
  # Upfy Gate: POST .../automation/api/profile/.../list-by-intranet (token opaco para api.automation)
  intranet_id: System.get_env("SEGFY_INTRANET_ID"),
  automation_profile_name: System.get_env("SEGFY_AUTOMATION_PROFILE_NAME"),
  # Cabeçalhos enviados na api.automation (browser usa app ou gestão conforme o fluxo)
  automation_request_origin: System.get_env("SEGFY_AUTOMATION_ORIGIN", "https://app.segfy.com"),
  # Lista HTML no Gestão costuma 302 sem sessão browser; padrão = pular e usar só Upfy Gate budget/list
  skip_gestao_html_list: skip_gestao_html_list,
  # Prêmios por seguradora (HFy) chegam via Socket.IO, não no body do POST /calculate
  multicalculo_socket_enabled: multicalculo_socket_enabled,
  socket_io_websocket_url:
    System.get_env(
      "SEGFY_SOCKET_IO_URL",
      "wss://socket-io.segfy.com/socket.io/?EIO=4&transport=websocket"
    ),
  socket_io_origin: System.get_env("SEGFY_SOCKET_IO_ORIGIN")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6"), do: [:inet6], else: []

  config :ersventaja, Ersventaja.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
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
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ersventaja, ErsventajaWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/plug_cowboy/Plug.Cowboy.html
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port,
      # Increase timeout for long-running sync operations (10 minutes)
      protocol_options: [idle_timeout: 600_000, request_timeout: 600_000]
    ],
    secret_key_base: secret_key_base

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :ersventaja, Ersventaja.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
