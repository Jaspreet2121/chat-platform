# Production image for the chat-platform umbrella release.
# Build context is apps/backend (the umbrella root); apps/web is outside this context and is
# NOT included. Secrets are NEVER baked in — config/runtime.exs reads them from the env at boot
# and fails fast if they are missing/insecure (see SharedInfra.ProdConfig).

# ---- Build stage --------------------------------------------------------------------------
# Match CI's toolchain: Elixir 1.18.4 / OTP 27 (official image is debian-bookworm based).
FROM elixir:1.18.4-otp-27 AS build

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
# Builds _build/prod/rel/chat_platform (the release defined in mix.exs releases:).
RUN mix release chat_platform

# ---- Runtime stage ------------------------------------------------------------------------
# Slim base with ONLY the C runtime libs the release needs (ERTS is bundled by mix release, so
# no Elixir/Erlang/mix here). Must match the build base's OS (debian bookworm).
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates locales \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod \
    PORT=4000

WORKDIR /app

# Run as a non-root user.
RUN useradd --create-home --uid 1000 app
COPY --from=build --chown=app:app /app/_build/prod/rel/chat_platform ./
USER app

EXPOSE 4000

# Boots the release; runtime.exs is evaluated here and enforces the prod secret guard.
CMD ["bin/chat_platform", "start"]
