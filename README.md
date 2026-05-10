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
2. **Select** — `ProviderSelector` picks the best provider: the active primary, or the highest-scoring alternative if the primary's circuit breaker is open
3. **Stream** — the request is forwarded to the chosen provider; the response streams back to the client in real time (SSE)
4. **Measure** — TTFT, token counts, and tokens-per-second are recorded per-request
5. **Auto-switch** — a background probe periodically compares providers on real TTFT/TPS data; if a non-primary provider consistently outperforms the active one, the proxy switches and persists the change to your config
6. **Fallback** — if the chosen provider fails, the proxy tries the next-best provider in score order, with retry and backoff

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

### Resilience

- **Exponential backoff** retry — configurable max attempts with `2^n` second delays
- **Stale-connection recovery** — `EOFError` from idle connections gets 2 free retries that don't count against your attempt limit
- **429 Retry-After** — rate-limited responses trigger a non-blocking retry after the provider's specified delay (capped at 60s)
- **Request deadline** — 600s overall limit across all provider fallback attempts, so a cascade of slow providers can't hang your request forever

### Performance

- **Connection pooling** — `Net::HTTP` connections cached per thread per `scheme://host:port`; evicted after 300s age or 60s idle
- **Boot-time pre-warm** — background connections opened to all providers at startup, so the first real request skips the TCP/TLS handshake
- **Zero-overhead passthrough** — set `tracking.enabled: false` to skip all chunk parsing; raw bytes pass straight through with negligible CPU cost

### Observability

- **Per-request streaming stats** — TTFT, content/thinking token counts, and tokens-per-second logged for every streaming response
- **Prometheus `/metrics`** — request counts/durations and per-provider success/failure counters in Prometheus-compatible format
- **macOS desktop notifications** — get alerted when the proxy falls back to an alternative provider

### Operations

- **Config hot-reload** — edit `config.yaml` and the proxy picks up changes within seconds (polls every 2s); or send `kill -USR1 <pid>` for an instant reload
- **Docker with live config** — mount `config/` from the host; edits apply without rebuild or restart
- **Health check** — `GET /health` returns model list and timestamp for load balancers and monitors
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
  max_attempts: 3
  backoff_base: 2      # seconds (2, 4, 8, ...)
```

Retry behaviour:
1. Attempt primary provider up to `max_attempts` with backoff.
2. On exhaustion, fall through to next provider (ordered by score) and retry there.
3. EOF on stale connection gets 2 fast retries that do **not** count against attempts; then counts as a normal failure.
4. Timeouts count as failures and trigger retry/backoff.

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
  sample_window: 300          # seconds to keep probe/metrics samples for scoring (default: 300 = 5 min)
  config_poll_interval: 2     # seconds between config.yaml change checks (set 0 to disable hot-reload)
```

### Authentication (optional)

Require an auth token on incoming requests:

```yaml
auth:
  token: "your-secret-token"   # Clients must send Authorization: Bearer <token>
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `4567` | Sinatra listen port |
| `PUMA_BIND` | `tcp://0.0.0.0` | Puma bind address |
| `PUMA_MIN_THREADS` | `1` | Puma thread pool minimum |
| `PUMA_MAX_THREADS` | `16` | Puma thread pool maximum |
| `RACK_ENV` | `production` | Rack environment |

For high-concurrency I/O-bound workloads, raise `PUMA_MAX_THREADS` to `16–32` since most time is waiting on upstream providers.

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/v1/chat/completions` | POST | Chat completions (streaming or single) |
| `/v1/completions` | POST | Legacy completions (streaming or single) |
| `/v1/embeddings` | POST | Embeddings (non-streaming) |
| `/v1/models` | GET | List configured models |
| `/v1/models/:name` | GET | Model details with provider routing |
| `/health` | GET | Health check with models list and timestamp |
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
[glm-5/wafer] Success | content=187 thinking=42 ttft=0.342s content_tps=54.3 thinking_tps=18.7
```

- **content** — output tokens (`delta.content` / `delta.text`)
- **thinking** — reasoning tokens (`delta.reasoning_content` / `delta.thinking` / `delta.reasoning`)
- **ttft** — time to first token
- **content_tps** — content tokens per second (measured from first content token)
- **thinking_tps** — thinking tokens per second (measured from first token of any kind)

## Docker Compose Reference

```yaml
services:
  llm-proxy:
    build: .
    ports:
      - "9234:4567"
    volumes:
      - ./config/:/app/config/
    restart: unless-stopped
    environment:
      - RUBY_ENV=production
```

Editable fields:
- `ports` — change left side to remap host port.
- `volumes` — mount your `config/` directory from host.
- `environment` — add any env vars from the table above (e.g. `PUMA_MAX_THREADS=32`).

---

For developer internals, key files, architecture notes, and testing — see [CONTRIBUTING.md](CONTRIBUTING.md).
