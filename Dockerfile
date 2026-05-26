# ---- Build stage: install gems with native extension toolchain ----
FROM ruby:4.0-alpine AS builder
WORKDIR /app

RUN apk add --no-cache build-base

COPY Gemfile Gemfile.lock* ./
RUN bundle config set --local without 'test development' \
 && bundle install --jobs 4 --retry 3

# ---- Runtime stage: slim image without build toolchain ----
FROM ruby:4.0-alpine
WORKDIR /app

# Non-root user matching common host UID 1000. Bind-mounting `./data:/app/data`
# from the host requires the host directory be writable by UID 1000;
# adjust via docker-compose `user: "${UID}:${GID}"` if your host UID differs.
RUN addgroup -g 1000 -S app \
 && adduser -u 1000 -S -G app app \
 && mkdir -p /app/data /app/config /app/log

# Bring over the compiled gems from the builder stage.
COPY --from=builder /usr/local/bundle /usr/local/bundle

COPY --chown=app:app Gemfile Gemfile.lock ./
COPY --chown=app:app proxy.rb provider_selector.rb config.ru puma.rb ./
COPY --chown=app:app lib/ lib/
RUN chown -R app:app /app

USER app

EXPOSE 4567

# wget ships with Alpine's busybox; no extra package needed.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:4567/health || exit 1

CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
