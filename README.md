# LLM Proxy

Multi-provider LLM proxy that picks the fastest provider, retries on failure, and streams tokens in real time.

Drop-in OpenAI-compatible API. Configure once, let the proxy handle provider selection, circuit breaking, and fallback.

## Why LLM Proxy?

Open-source models have changed the game — powerful LLMs are now available from dozens of providers at a fraction of the cost of closed-model APIs. But there's a catch: most of these providers are smaller companies. None of them offer the uptime or consistent inference speeds of the big incumbents. One goes down for maintenance, another starts rate-limiting at peak hours, a third is fast today but crawling tomorrow.

The cost isn't the problem — these providers are cheap. The problem is **orchestration**: how do you use several of them together so that downtime on one doesn't take down your app? How do you know which one is fastest *right now*?

LLM Proxy automates this. You list multiple providers for each model, and the proxy routes your requests to whichever one is performing best at that moment. If a provider goes down, it falls back to the next one — transparently, so your app keeps working. In most cases you won't notice individual provider outages unless *all* your configured providers for a model happen to be down at the same time.

## How It Works

Every incoming request follows this path:

1. **Route** — the proxy matches the requested model name to your config
2. **Select** — `ProviderSelector` picks the best provider: the active primary, or the highest-scoring alternative if the primary's circuit breaker is open or quota-paused
3. **Stream** — the request is forwarded to the chosen provider; the response streams back to the client in real time (SSE)
4. **Measure** — TTFT, token counts, and tokens-per-second are recorded per-request
5. **Auto-switch** — a background probe periodically compares providers on real TTFT/TPS data; if a non-primary provider consistently outperforms the active one, the proxy switches and persists the change to your config
6. **Fallback** — if the chosen provider fails, the proxy retries it up to `max_attempts` times, then falls through to the next provider. After all providers in a round fail, the proxy starts a new round (up to `max_rounds`) with a backoff delay between rounds, re-walking the provider list. Circuit-broken and quota-paused providers are excluded from subsequent rounds.

```
┌──────────────┐
│   Client     │
└──────┬───────┘
       │
┌──────▼───────┐      ┌────────────────────┐
│  LLMProxy    │─────▶│ ProviderSelector   │
│  (Sinatra)   │      │  per model         │
└──────┬───────┘      │  • scores providers│
       │              │  • probes every N  │
       │              │  • persists winner │
       │              └────────────────────┘
       │
   ┌───┴───┬───┬────────┐
   │       │   │        │
   ▼       ▼   ▼        ▼
 Prov A  Prov B  Prov C  Prov D
```

## Key Capabilities

### Smart Routing

- Scores providers by real **TTFT** (time to first token) and **TPS** (tokens per second) — not guesswork
- **Auto-switches** to the fastest provider after background probes compare performance
- **Circuit breaker** opens after 3 consecutive failures on a provider (60s cooldown), so bad providers are skipped until they recover
- **Quota pause** — 429, 402, and 403 (with quota body patterns) responses pause the provider until the reset time given by `Retry-After`, `x-ratelimit-reset-*` headers, or the body. While paused, the provider is skipped and requests fall through to the next provider

### Resilience

- **Exponential backoff** retry — configurable max attempts with `2^n` second delays, plus circular fallback rounds (`max_rounds`) that re-walk the provider list with inter-round backoff until success or circuit breakers open
- **Stale-connection recovery** — `EOFError` from idle connections gets 2 free retries that don't count against your attempt limit
- **Quota-aware fallback** — 429/402/403 quota responses immediately fall through to the next provider instead of retrying the same one; the paused provider is skipped until its reset time expires
- **Request deadline** — 600s overall limit across all fallback rounds, so a cascade of slow providers can't hang your request forever

### Performance

- **HTTP connection pool** — connections are pooled per (host, port) with 300s max-age and 60s max-idle eviction, eliminating TLS handshake overhead on subsequent requests
- **Boot-time pre-warm** — background connections opened to all providers at startup and added to the pool, so the first real request skips the TCP/TLS handshake
- **Lock-free config reads** — config snapshot is swapped atomically; request-path accessors take no mutex
- **Zero-overhead passthrough** — set `tracking.enabled: false` to skip all chunk parsing; raw bytes pass straight through with negligible CPU cost
- **Bounded probe cost** — `performance.probe_max_per_minute` caps probe launches across all models with a sliding 60-second window

### Observability

- **Per-request streaming stats** — TTFT, content/thinking token counts, and tokens-per-second logged for every streaming response
- **Prometheus `/metrics`** — request counts/durations, per-provider success/failure counters with a `reason` label, and a per-provider `upstream_ttft_seconds` histogram
- **Structured JSON logs** — set `logging.format: json` to emit one JSON record per log line with `request_id` threaded through helper calls
- **Per-provider detail endpoint** — `GET /v1/health/detail` returns per-model provider stats including active provider, TTFT/TPS metrics, quota pause state, and circuit breaker status

### Operations

- **Config hot-reload** — edit `config.yaml` and the proxy picks up changes within seconds (polls every 2s); or send `kill -USR1 <pid>` for an instant reload
- **Docker with live config** — mount `config/` from the host; edits apply without rebuild or restart
- **Health check** — `GET /health` returns `{\"status\": \"ok\"}` for load balancers and monitors; `GET /v1/health/detail` returns full provider stats
- **Optional incoming auth** — set `auth.token` in config to require `Authorization: Bearer <token>` on all requests

## Use Cases

**Multi-provider redundancy** — The same open-source model is available via 3 providers. One goes down for maintenance? The proxy falls back to the next. Your app never notices.

**Speed optimisation** — Provider A is fast right now but slows at peak hours. The proxy measures real performance and auto-switches to Provider B when it's faster.

**Zero-downtime migration** — Adding a new provider? Add it to config — the proxy hot-reloads. Removing one? Delete it. No restart needed.

**Single endpoint for all models** — Front all your LLM calls through one URL. Swap providers, add models, change routing — all without touching client code.

## Quick Start

### Local

```bash
bundle install
cp config/config.yaml.example config/config.yaml    # then edit with real keys
bundle exec puma -C puma.rb
```

Exposes `http://localhost:4567`.

### Docker Compose

```bash
cp config/config.yaml.example config/config.yaml     # then edit with real keys
docker compose up -d
```

Exposes `http://localhost:9234`.

Config is mounted from host (`./config/:/app/config/`) so edits apply without rebuild. To rebuild after code changes:

```bash
docker compose up -d --build
```

## Configuration

### Providers

Define once, reference by name in models.

```yaml
providers:
  fireworks:
    base_url: "https://api.fireworks.ai/inference/v1"
    api_key: "YOUR_FIREWORKS_API_KEY"

  anthropic:
    base_url: "https://api.anthropic.com/v1"
    api_key: "YOUR_ANTHROPIC_API_KEY"
    headers:
      anthropic-version: "2023-06-01"
```

Provider auth strategies:
- Default: `Authorization: Bearer <api_key>`
- `anthropic`: `x-api-key` header

### Models

Each model lists one or more providers. Optional `primary: true` on a provider sets the initial active choice. The proxy updates this field when it auto-switches.

```yaml
models:
  - name: "glm-5"
    providers:
      - provider: "fireworks"
        model: "accounts/fireworks/routers/glm-5-fast"
      - provider: "alibaba"
        model: "glm-5"
        primary: true
```

Provider entry can also override/extend headers:

```yaml
      - provider: "openrouter"
        model: "qwen/qwq-32b"
        headers:
          HTTP-Referer: "https://example.com"
```

Per-model overrides — each model entry can set `probing_enabled`, `auto_switch`, and `probe_interval` to override the global `performance.*` values. When omitted, falls back to global defaults.

### Timeouts

```yaml
timeouts:
  open: 30    # connection open (seconds)
  read: 300   # per-chunk read timeout for streaming
  write: 60   # request body send timeout
```

### Retries

```yaml
retries:
  max_attempts: 3        # retries on the same provider before falling through (per round)
  max_rounds: 3         # circular fallback rounds: A→B→A→B until success or circuits open
  backoff_base: 2       # seconds (2, 4, 8, ... — used for both per-attempt and inter-round backoff)
```

Retry behaviour:
1. Within each round, attempt each provider up to `max_attempts` with exponential backoff.
2. Fall through to the next provider (config order when auto_switch is off, by score when on) and retry there.
3. After every provider in a round fails, start the next round — re-walking the provider list — with an inter-round backoff delay. This gives transient outages time to recover: `A×3 → B×3` ⟶ delay ⟶ `A×3 → B×3` ⟶ delay ⟶ `A×3 → B×3`.
4. Repeat up to `max_rounds` times. With a single provider, this becomes repeated retry groups with a delay between them.
5. The circuit breaker (3 consecutive failures, 60s cooldown) and quota pauses are re-evaluated each round. A provider that opens its circuit or hits quota is excluded from subsequent rounds, so the loop naturally narrows to providers that are still healthy.
6. EOF on stale connection gets 2 fast retries that do **not** count against attempts; then counts as a normal failure.
7. Timeouts count as failures and trigger retry/backoff.
8. 429, 402, and 403 (with quota body patterns) immediately pause the provider and fall through to the next one — no retry on the same provider. The provider is skipped until its stated reset time expires.
9. 600s overall request deadline across all rounds.

### Logging

```yaml
logging:
  level: "info"        # debug, info, warn, error
  format: "json"       # json or text (default: text)
```

### Tracking (TPS Stats)

```yaml
tracking:
  enabled: true        # false = zero-overhead passthrough
```

When `enabled: false` the proxy skips all chunk parsing — no string matching, no JSON inspection. Raw bytes pass straight through. TPS logging suppressed. Use this for pure transparent proxy with negligible CPU overhead.

### Performance

```yaml
performance:
  prewarm_connections: true   # background connection warming at boot
  probing_enabled: true       # enable/disable background probing and auto-selection (default: true)
  auto_switch: false          # auto-switch active provider when better one found (requires probing_enabled)
  probe_interval: 3           # run background probe every N requests
  probe_max_per_minute: 60    # cap probe launches across all models (sliding 60s window; omit/0 = unlimited)
  sample_window: 300          # seconds to keep probe/metrics samples for scoring (default: 300 = 5 min)
  config_poll_interval: 2     # seconds between config.yaml change checks (set 0 to disable hot-reload)
```

`ConfigValidator` rejects out-of-range values for `retries.max_attempts`, `retries.backoff_base`, `performance.probe_interval`, `performance.probe_max_per_minute`, `performance.sample_window`, `limits.max_request_body`, and `timeouts.{open,read,write}` at boot/reload, so a fat-fingered config can't silently DoS the proxy.

### Authentication (optional)

Require an auth token on incoming `/v1/*` requests:

```yaml
auth:
  token: "your-secret-token"           # Clients must send Authorization: Bearer <token>
  metrics_token: "scrape-only-token"   # Optional separate token gating only /metrics
```

`/health` is always public so load balancers can probe it. `/v1/health/detail` requires authentication and returns detailed per-provider stats. `/metrics` is public by default; set `auth.metrics_token` to require a separate bearer token for Prometheus scraping. Token comparison is constant-time.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `4567` | Sinatra listen port |
| `PUMA_BIND` | `tcp://0.0.0.0` | Puma bind address |
| `PUMA_MIN_THREADS` | `1` | Puma thread pool minimum |
| `PUMA_MAX_THREADS` | `16` | Puma thread pool maximum |
| `RACK_ENV` | `production` | Rack environment |
| `CONFIG_FILE` | `config/config.yaml` | Absolute path to the config file |
| `STATE_DIR` | `data/` | Directory for persisted provider state |

For high-concurrency I/O-bound workloads, raise `PUMA_MAX_THREADS` to `16–32` since most time is waiting on upstream providers.

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/v1/chat/completions` | POST | Chat completions (streaming or single) |
| `/v1/completions` | POST | Legacy completions (streaming or single) |
| `/v1/embeddings` | POST | Embeddings (non-streaming) |
| `/v1/models` | GET | List configured models |
| `/v1/models/:name` | GET | Model details with provider routing |
| `/health` | GET | Health check — returns `{\"status\":\"ok\"}` |
| `/v1/health/detail` | GET | Detailed provider stats (requires auth) |
| `/metrics` | GET | Prometheus-compatible metrics |

## Usage

```bash
curl http://localhost:9234/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-proxy-key" \
  -d '{
    "model": "glm-5",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

The proxy passes `Authorization`, `OpenAI-Organization`, and `OpenAI-Beta` headers through to the upstream provider (except on `anthropic`, where `x-api-key` is used instead).

## Streaming Stats

Every streaming request logs token statistics:

```
[glm-5/wafer] Success | content=187 thinking=42 ttft=0.342s content_tps=54.3 thinking_tps=18.7 total_tps=48.9
```

- **content** — output tokens (`delta.content` / `delta.text`)
- **thinking** — reasoning tokens (`delta.reasoning_content` / `delta.thinking` / `delta.reasoning`)
- **ttft** — time to first token
- **content_tps** — content tokens per second (measured from first content token to last content token)
- **thinking_tps** — thinking tokens per second (measured from first thinking token to last thinking token)
- **total_tps** — completion tokens per second. Uses server-side timing when reported by the provider (in priority order: `usage.tokens_per_second`, Groq's `usage.completion_time`, Fireworks' `perf_metrics.generation-duration`, or the vLLM `: energy` comment's `duration_seconds`); falls back to the arrival-window estimate (first token to last of any kind) when no server timing is available

## Docker Compose Reference

```yaml
services:
  llm-proxy:
    build: .
    ports:
      - "9234:4567"
    volumes:
      # Mount as directory, not single file — avoids inode breakage on atomic writes
      - ./config:/app/config
      # Persist provider state across container restarts
      - ./data:/app/data
    restart: unless-stopped
    environment:
      - RACK_ENV=production
      - CONFIG_FILE=/app/config/config.yaml
```

Editable fields:
- `ports` — change left side to remap host port.
- `volumes` — mount your `config/` and `data/` directories from host. The `data/` mount preserves provider scoring state (TTFT/TPS samples, active-provider selection) across container restarts.
- `environment` — add any env vars from the table above (e.g. `PUMA_MAX_THREADS=32`).

The image runs as a non-root user (UID 1000). Bind-mounted host directories must be writable by UID 1000, or set `user: "${UID}:${GID}"` in a `docker-compose.override.yml` to match the host UID.

A `HEALTHCHECK` is built into the image that polls `/health` every 30 seconds (`docker compose ps` will show `(healthy)` when ready).

---

For developer internals, key files, architecture notes, and testing — see [CONTRIBUTING.md](CONTRIBUTING.md).
