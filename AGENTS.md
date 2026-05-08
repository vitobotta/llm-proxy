# AGENTS.md — LLM Proxy

Ruby (Sinatra + Puma) multi-provider LLM proxy. OpenAI-compatible API at `/v1/`.

## Start / Dev

```bash
cp config.yaml.example config.yaml   # then edit with real keys
bundle install
bundle exec puma -C puma.rb          # listens on :4567
docker compose up -d                 # listens on :9234
```

## Test

Minitest — no RSpec. Run a single file:

```bash
bundle exec ruby test/test_provider_selector.rb
```

Or all:

```bash
bundle exec ruby -I. test/test_provider_selector.rb test/test_streaming.rb test/test_http_support.rb test/test_retry.rb
```

No CI workflows. No linter, no formatter, no typechecker.

## Key files

| File | Role |
|---|---|
| `proxy.rb` | Sinatra app: routes, retry loop, streaming, metrics logging |
| `provider_selector.rb` | Per-model provider scorer with TTFT/TPS ranking, hysteresis, background probing |
| `lib/streaming.rb` | SSE chunk parser (string-match, not `JSON.parse`), token counting |
| `lib/http_support.rb` | HTTP connection pooling, retry logic, graceful shutdown |
| `config.yaml.example` | Template config — reference for all valid keys |
| `config.ru` | Rack entrypoint |
| `puma.rb` | Puma config (threads 1–16, single worker, I/O-bound tuned) |

## Architecture notes

- **Streaming is the default** — `stream: false` must be explicit in the request body. The `stream_requested` var is `true` unless body has `"stream": false`.
- **Provider auto-selection** happens per-request via `ProviderSelector#ordered_providers`. Active provider is first; others sorted by score.
- **`ProviderSelector` mutates `config.yaml`** — when auto-switch fires, it writes `primary: true` back to the file. This is by design, not a side effect to "fix".
- **Pre-warm** runs at boot in `proxy.rb` bottom: `HTTPSupport.prewarm_connections!` opens background HTTP connections to every provider.
- **Graceful shutdown** registered via `HTTPSupport.setup_graceful_shutdown!` — cleans connection pools on SIGINT/SIGTERM.
- **No JSON parse for chunk tracking** — `Streaming.parse_chunk` uses fast string matching (`include?`) on SSE data lines to detect thinking/content/usage. Only the `usage` block gets `JSON.parse`. When `tracking.enabled: false`, all chunk parsing is skipped entirely.
- **EOF recovery** — two no-harm retries on `EOFError` (stale connection) that don't count against `max_attempts`.

## Gotchas

- **`config.yaml` is gitignored and contains real API keys** — never read it into context or echo it.
- **`Gemfile.lock` is gitignored** — this is a library-style repo. Run `bundle install` to generate it.
- **`YAML.unsafe_load_file` is intentional** — not a security bug. Config contains only trusted local data.
- **Auth strategy varies by provider** — most use `Authorization: Bearer`, but Anthropic uses `x-api-key`. See `HTTPSupport::AUTH_STRATEGIES`.
- **`PROTECTED_HEADERS`** (host, authorization, x-api-key, api-key) are stripped from incoming requests before forwarding upstream.
- **Docker binds port 9234**, not 4567.
- **`MACOS` constant** enables `osascript` desktop notifications on provider fallback. Harmless no-op on Linux.
- **`context_length` is optional** per model — only validated if present (must be positive integer).
- **Background probing** uses a fixed `PROBE_BODY` ("Write a brief paragraph about the weather", max_tokens: 100) and skips providers already being probed.
