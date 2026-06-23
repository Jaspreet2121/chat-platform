# Parameterized production image — builds ONE release per image (microservices split).
#
# RELEASE selects which release to bundle (defined in apps/backend/mix.exs releases:):
#   auth_service | user_service | conversation_service | message_service | media_service
#   | gateway (api_gateway + realtime_gateway) | chat_platform (all-in-one, the DEFAULT)
#
# Each per-service image bundles ONLY that app + shared_infra (+ hex deps + ERTS) — NOT the other
# services. With no build-arg it reproduces the original single-container all-in-one image (3b
# baseline). Build context is apps/backend (the umbrella root); apps/web is outside it and NOT
# included. Secrets are NEVER baked — config/runtime.exs reads them from the env at boot and fails
# fast if they are missing/insecure (see SharedInfra.ProdConfig).
#
#   docker build --build-arg RELEASE=auth_service --build-arg SERVICE_PORT=4101 -t chat/auth_service apps/backend
#   docker build --build-arg RELEASE=gateway      --build-arg SERVICE_PORT=4000 -t chat/gateway      apps/backend
#   docker build                                                                -t chat/all          apps/backend  # chat_platform
#
# Ports: auth 4101, conversation 4102, user 4103, message 4104, media 4105, gateway 4000.

ARG RELEASE=chat_platform

# ---- Build stage --------------------------------------------------------------------------
# Match CI's toolchain: Elixir 1.18.4 / OTP 27 (official image is debian-bookworm based).
FROM elixir:1.18.4-otp-27 AS build

# ARG must be re-declared after FROM to be visible in this stage.
ARG RELEASE

# Build deps INCLUDING cmake + build-essential for brod's crc32cer NIF (same reason CI needs it).
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential cmake git \
  && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Umbrella + per-app mix files and config are needed to resolve/compile deps and build the release.
COPY mix.exs mix.lock ./
COPY config config
COPY apps apps

RUN mix deps.get --only prod
RUN mix deps.compile
RUN mix compile
# Builds _build/prod/rel/$RELEASE; mix release bundles ONLY that release's applications.
RUN mix release "$RELEASE"
# Normalize to a fixed path so the runtime stage's COPY/CMD don't depend on the release name dir.
RUN cp -r "_build/prod/rel/$RELEASE" /release

# ---- Runtime stage ------------------------------------------------------------------------
# Slim base with ONLY the C runtime libs the release needs (ERTS is bundled by mix release, so
# no Elixir/Erlang/mix here). Must match the build base's OS (debian bookworm).
FROM debian:bookworm-slim AS runtime

# Re-declare ARGs for this stage; RELEASE_BIN carries the release name into the runtime CMD
# (ARGs are not available at container runtime — only ENV is).
ARG RELEASE
ARG SERVICE_PORT=4000

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates locales \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod \
    PORT=4000 \
    RELEASE_BIN=${RELEASE}

WORKDIR /app

# Run as a non-root user.
RUN useradd --create-home --uid 1000 app
COPY --from=build --chown=app:app /release ./
USER app

# Documents the service's listen port (auth 4101 … media 4105, gateway 4000). Metadata only.
EXPOSE ${SERVICE_PORT}

# Boots the release; runtime.exs is evaluated here and enforces the prod secret guard.
# exec → the release replaces the shell as PID 1, so signals (SIGTERM) reach the VM.
CMD ["/bin/sh", "-c", "exec /app/bin/$RELEASE_BIN start"]
