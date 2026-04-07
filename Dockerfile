FROM elixir:1.18-otp-27-slim AS builder

# Install build deps
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install deps
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Compile app
COPY lib lib
COPY priv priv
RUN mix compile

# Build release
RUN mix release

# ── Production image ─────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runner

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV=prod
ENV PORT=8080

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/knowledge_index ./

USER nobody

# Migrations run on app boot via Application.start
CMD ["/app/bin/knowledge_index", "start"]
