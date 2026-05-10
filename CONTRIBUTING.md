# Contributing to LLM Proxy

Developer reference for understanding, modifying, and testing the proxy internals.

## Development Setup

### Local

```bash
cp config.yaml.example config.yaml   # then edit with real keys
bundle install
bundle exec puma -C puma.rb          # listens on :4567
```

### Docker

```bash
docker compose up -d                 # listens on :9234
```

Config is mounted from host (`./config.yaml:/app/config.yaml`) so edits apply without rebuild. To rebuild after code changes:

```bash
docker compose up -d --build
```

## Key Files

| File | Role |
|---|---|
| `proxy.rb` | Sinatra app: routes, config loading, before/after hooks, auth |
| `provider_selector.rb` | Per-model provider scorer with TTFT/TPS ranking, hysteresis, circuit breaker |
| `lib/streaming.rb` | SSE chunk parser, `TimerTracker` class, token counting, TPS computation |
| `lib/http_support.rb` | HTTP connection pooling (`PoolEntry` with age/idle tracking), retry logic, graceful shutdown |
| `lib/request_handler.rb` | Sinatra helper: `with_auto_select`, `try_stream`, `try_single_request`, deadline enforcement |
| `lib/config_validator.rb` | Config validation (errors abort on boot, return errors on reload) |
| `lib/config_store.rb` | Thread-safe mutable config store — replaces frozen constants, supports hot-reload |
| `lib/config_watcher.rb` | Polls config.yaml mtime + SIGUSR1 handler, triggers `ConfigStore.reload!` |
| `lib/probe_manager.rb` | Background probe logic |
| `lib/metrics.rb` | Lightweight Prometheus-compatible counters/histograms |
| `config.yaml.example` | Template config — reference for all valid keys |
| `config.ru` | Rack entrypoint |
| `puma.rb` | Puma config (threads 1–16, single worker, I/O-bound tuned) |

## Architecture Internals

### Core components

- `proxy.rb` — Sinatra app handling routing, retry logic, streaming, chunk parsing, metrics tracking.
- `provider_selector.rb` — per-model scorer. Maintains rolling samples (TTFT + TPS), prunes older than `sample_window` (default 5 min). When `probing_enabled` is true: after every `probe_interval` requests, sends a test prompt to non-active providers, scores all, switches if a better provider exceeds current by hysteresis (`10%`). Writes `primary: true` back to `config.yaml`.
- `ChunkResult` struct — fast string-match parsing of SSE chunks. No `JSON.parse` except for `usage` blocks. When tracking is off, parsing is skipped entirely.

### Request lifecycle

- **Streaming is the default** — `stream: false` must be explicit in the request body. The `stream_requested` var is `true` unless body has `"stream": false`.
- **Provider auto-selection** happens per-request via `ProviderSelector#ordered_providers`. Active provider is first; others sorted by score. Circuit-broken providers are skipped.
- **Circuit breaker** — 3 consecutive failures opens a provider's circuit for 60s. Success resets it.
- **`ProviderSelector` mutates `config.yaml`** — when auto-switch fires, it writes `primary: true` back to the file. This is by design, not a side effect to "fix".
- **Pre-warm** runs at boot: `HTTPSupport.prewarm_connections!` opens and keeps HTTP connections alive.
- **Graceful shutdown** registered via `HTTPSupport.setup_graceful_shutdown!` — cleans connection pools on SIGINT/SIGTERM.

### Chunk parsing

- **No JSON parse for chunk tracking** — `Streaming.parse_chunk` uses fast string matching (`include?`) on SSE data lines to detect thinking/content/usage. Only the `usage` block gets `JSON.parse`. When `tracking.enabled: false`, all chunk parsing is skipped entirely.

### Retry and fallback

- **EOF recovery** — two no-harm retries on `EOFError` (stale connection) that don't count against `max_attempts`.
- **429 Retry-After** — non-blocking: `RateLimitedError` carries the delay, retry loop sleeps with cap at 60s.
- **Request deadline** — 600s overall limit across all provider fallback attempts.

### Connection lifecycle

- `PoolEntry` tracks creation time and last-used time. Connections evicted after 300s age or 60s idle.

### Observability

- **Prometheus metrics** at `/metrics` — request counts/durations, per-provider success/failure counters.


### Config hot-reload

- `ConfigWatcher` polls `config.yaml` mtime every 2s (configurable via `config_poll_interval`). Also supports `kill -USR1 <pid>` for manual reload. Invalid config on reload is skipped (keeps last good config, logs errors).
- `ConfigStore` replaces frozen constants — all config reads go through thread-safe accessors (`ConfigStore.providers`, `ConfigStore.model(name)`, `ConfigStore.selector(name)`, etc.). Selector state (circuit breaker, metrics) is preserved across reloads when provider lists match.
- `ConfigWatcher.expecting_write!` — `ProviderSelector` calls this before writing `config.yaml` so the watcher ignores its own write.

## Gotchas

- **`config.yaml` is gitignored and contains real API keys** — never read it into context or echo it.
- **`Gemfile.lock` is gitignored** — this is a library-style repo. Run `bundle install` to generate it.
- **`YAML.unsafe_load_file` is intentional** — not a security bug. Config contains only trusted local data.
- **Auth strategy varies by provider** — most use `Authorization: Bearer`, but Anthropic uses `x-api-key`. See `HTTPSupport::AUTH_STRATEGIES`.
- **`PROTECTED_HEADERS`** (host, authorization, x-api-key, api-key) are stripped from incoming requests before forwarding upstream.
- **Docker binds port 9234**, not 4567.
- **`context_length` is optional** per model — only validated if present (must be positive integer).
- **Background probing** uses a fixed `PROBE_BODY` ("Write a brief paragraph about the weather", max_tokens: 100) and skips providers already being probed.
- **Incoming auth** optional via `auth.token` in config — clients must send `Authorization: Bearer <token>`.
- **`accumulated` string** is nil'd after usage data found OR after exceeding 512KB — always nil-check before use.

## Testing

Minitest — no RSpec. Run a single file:

```bash
bundle exec ruby test/test_provider_selector.rb
```

Or all:

```bash
bundle exec ruby -I. test/test_provider_selector.rb test/test_streaming.rb test/test_http_support.rb test/test_retry.rb
```

No CI workflows. No linter, no formatter, no typechecker.

**Always start the containers and perform integration tests after making changes** — unit tests alone are not sufficient. Rebuild and restart Docker, then hit the proxy endpoints to verify it works:

```bash
docker compose up -d --build
sleep 3
# Verify health endpoint
curl -s http://localhost:9234/health | python3 -m json.tool
# Verify models endpoint
curl -s http://localhost:9234/v1/models | python3 -m json.tool
```
