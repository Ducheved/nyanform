import Config

config :nyanform,
  protocol_revision: "2025-11-25"

config :logger, :console,
  level: :warning,
  format: "$time $metadata[$level] $message\n",
  metadata: [:session_id, :profile, :tool]

config :logger,
  compile_time_purge_matching: [
    [level_lower_than: :debug]
  ]

import_config "#{config_env()}.exs"
