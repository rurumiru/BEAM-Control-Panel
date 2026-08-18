# syntax=docker/dockerfile:1
#
# BEAM Control Panel — production image.
#
#   docker build -t beam-control-panel .
#   docker run --env-file .env -p 4000:4000 beam-control-panel
#
# Everything the panel needs to reach managed servers is built into OTP
# (`:ssh`, `:ssh_sftp`), so the runtime image stays small — no ssh client,
# no ansible, no extra tooling.

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250428-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# --------------------------------------------------------------------- build

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix assets.setup
RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release --overwrite --path /app/_release

# ------------------------------------------------------------------- runtime

FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

WORKDIR /app

RUN groupadd --system --gid 1000 beam \
  && useradd --system --uid 1000 --gid beam --create-home --home-dir /home/beam beam \
  && chown beam:beam /app

COPY --from=builder --chown=beam:beam /app/_release ./

USER beam

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/login" >/dev/null || exit 1

ENTRYPOINT ["/app/bin/beam_panel"]
CMD ["start"]
