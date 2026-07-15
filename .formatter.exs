[
  import_deps: [:nimble_options, :plug, :telemetry],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "priv/**/*.{ex,exs}",
    "scripts/*",
    "rel/**/*.exs"
  ],
  line_length: 98,
  trailing_comma: false
]
