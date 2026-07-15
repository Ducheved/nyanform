FROM elixir:1.20-otp-29 AS build

WORKDIR /app

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config ./config
COPY lib ./lib
COPY priv ./priv

RUN mix compile
RUN mix escript.build

FROM elixir:1.20-otp-29-slim AS runtime

WORKDIR /app

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/sh nyanform
USER nyanform

COPY --from=build --chown=nyanform:nyanform /app/nyanform ./nyanform

ENV MCP_PROTOCOL_REVISION=2025-11-25

ENTRYPOINT ["/app/nyanform"]
CMD ["--help"]
