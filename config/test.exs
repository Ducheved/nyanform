import Config

config :logger, :console, level: :error

config :nyanform,
  request_timeout_ms: 5_000
