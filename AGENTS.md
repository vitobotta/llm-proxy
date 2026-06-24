# AGENTS.md — LLM Proxy

Ruby (Sinatra + Puma) multi-provider LLM proxy. OpenAI-compatible API at `/v1/`.

## Start / Dev

```bash
cp config/config.yaml.example config/config.yaml   # then edit with real keys
bundle install
bundle exec puma -C puma.rb          # listens on :4567
docker compose up -d                 # listens on :9234
```

## Test

Minitest — no RSpec. Run a single file:

```bash
bundle exec ruby -I. test/test_provider_selector.rb
```

Or all:

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-4.0.1 && bundle exec ruby -I. test/test_provider_selector.rb test/test_streaming.rb test/test_http_support.rb test/test_retry.rb
```

No CI workflows. No linter, no formatter, no typechecker.

**ALWAYS start the containers and perform integration tests after making changes** — unit tests alone are not sufficient. Rebuild and restart Docker, then hit the proxy endpoints to verify it works:

```bash
docker compose up -d --build
sleep 3
# Verify health endpoint
curl -s http://localhost:9234/health | python3 -m json.tool
# Verify models endpoint
curl -s http://localhost:9234/v1/models | python3 -m json.tool
```

## Key files

| File | Role |
|---|---|
| `proxy.rb` | Sinatra app: routes, config loading, before/after hooks, auth |
| `provider_selector.rb` | Per-model provider scorer with TTFT/TPS ranking, hysteresis, circuit breaker, quota pause |
| `lib/streaming.rb` | SSE chunk parser, `TimerTracker` class, token counting, TPS computation |
| `lib/http_support.rb` | HTTP connection pooling (`PoolEntry` with age/idle tracking), retry logic, quota detection, graceful shutdown |
| `lib/request_handler.rb` | Sinatra helper: `with_auto_select`, `try_stream`, `try_single_request`, deadline enforcement |
| `lib/config_validator.rb` | Config validation (errors abort on boot, return errors on reload) |
| `lib/config_store.rb` | Thread-safe mutable config store — replaces frozen constants, supports hot-reload |
| `lib/config_watcher.rb` | Polls config content hash + SIGUSR1 handler, triggers `ConfigStore.reload!` |
| `lib/probe_manager.rb` | Background probe logic |
| `lib/metrics.rb` | Lightweight Prometheus-compatible counters/histograms |
| `config/config.yaml.example` | Template config — reference for all valid keys |
| `config.ru` | Rack entrypoint |
| `puma.rb` | Puma config (threads 1–16, single worker, I/O-bound tuned, WRITE_TIMEOUT override) |

## Architecture notes

- **Streaming is the default** — `stream: false` must be explicit in the request body. The `stream_requested` var is `true` unless body has `"stream": false`.
- **Provider auto-selection** happens per-request via `ProviderSelector#ordered_providers`. Active provider is first; others follow config order (when `auto_switch: false`) or are sorted by score (when `auto_switch: true`). Circuit-broken and quota-paused providers are skipped.
- **Circuit breaker** — 3 consecutive failures opens a provider's circuit for 60s. Success resets it.
- **Quota pause** — 429, 402, and 403 (with quota body patterns like `insufficient_quota`, `billing limit`, `credit`, etc.) responses immediately pause the provider and fall through to the next one. The pause duration is extracted from `Retry-After`, `x-ratelimit-reset-requests/tokens` headers, or the response body. If none are available, `quota_pause_default_seconds` (default 60s) is used. Paused providers are skipped by requests and probes until the pause expires. `QuotaExhaustedError` is raised in `handle_upstream_error` and caught in `try_with_retries` which returns immediately (no retry on same provider). `with_auto_select` registers the pause via `selector.quota_pause!`. `quota_pause!` takes the `max` of the current and new `paused_until` so repeated requests can't extend a pause beyond the server-stated reset time.
- **`ProviderSelector` mutates `config/config.yaml`** — when auto-switch fires, it writes `primary: true` back to the file. This is by design, not a side effect to "fix".
- **Pre-warm** runs at boot: `HTTPSupport.prewarm_connections!` opens and keeps HTTP connections alive.
- **Graceful shutdown** registered via `HTTPSupport.setup_graceful_shutdown!` — cleans connection pools on SIGINT/SIGTERM.
- **No JSON parse for chunk tracking** — `Streaming.parse_chunk` uses fast string matching (`include?`) on SSE data lines to detect thinking/content/usage. Only the `usage` block gets `JSON.parse`. When `tracking.enabled: false`, all chunk parsing is skipped entirely.
- **EOF recovery** — two no-harm retries on `EOFError` (stale connection) that don't count against `max_attempts`.
- **429/402/403 quota responses** — no longer retry on the same provider. `QuotaExhaustedError` is raised immediately and the request falls through to the next provider. The provider is quota-paused until its stated reset time. `RateLimitedError` and its sleep-and-retry logic have been removed.
- **Request deadline** — 600s overall limit across all fallback rounds.
- **Circular fallback rounds** (`max_rounds`, default 3) — `with_auto_select` wraps the provider walk in an outer round loop. Each round re-evaluates `ordered_providers` (so circuit-broken and quota-paused providers are excluded) and re-walks the full list, retrying each provider `max_attempts` times via `try_with_retries`. Between rounds there is an exponential backoff delay (`backoff_base * 2^(round-1)` with jitter) — the "delay between groups of retries" for transient outages. With a single provider the loop becomes repeated retry groups with inter-round delay. The circuit breaker (3 failures, 60s cooldown) naturally caps `max_rounds`: a provider that fails every round opens its circuit and is excluded from subsequent rounds.
- **Connection lifecycle** — `PoolEntry` tracks creation time and last-used time. Connections evicted after 300s age or 60s idle.
- **Prometheus metrics** at `/metrics` — request counts/durations, per-provider success/failure counters.
- **Config hot-reload** — `ConfigWatcher` polls config content hash every 2s (configurable via `config_poll_interval`). Also supports `kill -USR1 <pid>` for manual reload. Invalid config on reload is skipped (keeps last good config, logs errors). Config path is configurable via `CONFIG_FILE` env var (default: `config/config.yaml`).
- **`ConfigStore`** replaces frozen constants — all config reads go through thread-safe accessors (`ConfigStore.providers`, `ConfigStore.model(name)`, `ConfigStore.selector(name)`, etc.). Selector state (circuit breaker, metrics) is preserved across reloads when provider lists match.
- **Per-model probe/autoswitch overrides** — each model entry can set `probing_enabled`, `auto_switch`, and `probe_interval` to override the global `performance.*` values. When omitted, falls back to global defaults.
- **`ConfigWatcher.expecting_write!`** — `ProviderSelector` calls this before writing `config.yaml` so the watcher ignores its own write.
- **Docker mounts `config/` directory**, not the single file — avoids inode breakage when editors do atomic writes (write-to-temp → rename) on Linux.

## Gotchas

- **`config/config.yaml` is gitignored and contains real API keys** — never read it into context or echo it.
- **`Gemfile.lock` is gitignored** — this is a library-style repo. Run `bundle install` to generate it.
- **`YAML.unsafe_load_file` is intentional** — not a security bug. Config contains only trusted local data.
- **Auth strategy varies by provider** — most use `Authorization: Bearer`, but Anthropic uses `x-api-key`. See `HTTPSupport::AUTH_STRATEGIES`.
- **`PROTECTED_HEADERS`** (host, authorization, x-api-key, api-key) are stripped from incoming requests before forwarding upstream.
- **Docker binds port 9234**, not 4567.
- **`context_length` is optional** per model — only validated if present (must be positive integer).
- **Background probing** uses a fixed `PROBE_BODY` ("Write a brief paragraph about the weather", max_tokens: 100) and skips providers already being probed or that are quota-paused or circuit-broken.
- **Incoming auth** optional via `auth.token` in config — clients must send `Authorization: Bearer <token>`.
- **`accumulated` string** is nil'd after usage data found OR after exceeding 512KB — always nil-check before use.
- **`quota_pause_default_seconds`** (default 60s) — used when a quota error doesn't include a `Retry-After`, `x-ratelimit-reset-*`, or body reset time. Configurable via `quota_pause_default_seconds` in the top-level config.
- **Probe quota detection** — `probe_provider` parses error strings from `Streaming.stream_response` and registers quota pauses via `HTTPSupport.quota_exhausted?` and `HTTPSupport.extract_reset_time_from_error`. These are string-based alternatives to the response-object methods used in the main request path.
- **`probing_enabled: false` disables auto_switch** — per-model `auto_switch` is forced false when `probing_enabled` is false, matching the global behaviour.
- **Puma's `WRITE_TIMEOUT` is monkey-patched to 300s** — Puma's default 10s write timeout (`Puma::Const::WRITE_TIMEOUT`) kills long-lived streaming connections with "Socket timeout writing data". Overridden in `puma.rb` + `persistent_timeout 300`.

## Writing style for user-facing prose

Anything end users will read — GitHub release notes, CHANGELOG entries, README, error messages, the docs in `CONTRIBUTING.md` — uses a changelog voice, not a working-notes voice. Match the existing v1.2.3 release notes as the template.

- **Third person about the proxy, not first person about the work.** "The proxy now …" / "`X` is rejected at boot" — not "I added", "we changed", "you should now".
- **Lead with the user-visible behaviour change.** Short cause/effect after, only when it helps the reader act on the change. Don't open with the diagnosis.
- **Breaking changes lead with the operator action.** "Update Prometheus configs that reference the old name", "Ensure every provider has a non-empty `api_key`", "Set `user:` in compose if your host UID isn't 1000". Action first; explanation second.
- **No dev-process metadata.** Don't mention phases, commit counts, audit numbering, which tool surfaced a bug, or how work was batched. The reader doesn't care that something was "P0.4" or that "standardrb caught it".
- **No reader-direct framing.** Avoid "read these first", "for context", "as you'll see", "happy to …". These read like agent-to-maintainer chat, not a public artifact.
- **Section the notes** — `⚠️ Breaking changes`, `What's Fixed`, `What's New` (subgrouped if long: Observability / Configuration / Security), `Performance`, then `Code organisation` / `Tooling` / `Tests` for the contributor-facing tail. Skip empty sections.

Internal artifacts — commit messages, plan files, conversations — are exempt and may stay in working-notes voice.
