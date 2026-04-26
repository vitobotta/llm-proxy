# LLM Proxy

Ruby-based multi-provider LLM proxy with automatic provider selection, streaming, and fallback.

## Features

- **OpenAI-compatible API** — drop-in replacement for `chat/completions`, `completions`, `embeddings`, and model list endpoints
- **Auto provider selection** — scores providers by TTFT and TPS, switches to best after every N requests
- **Per-model multi-provider routing** — each model lists multiple backend providers; proxy picks fastest, falls back on failure
- **Streaming with TPS stats** — SSE output with per-request TTFT, content/thinking token counts, and throughput
- **Automatic retry** — configurable max attempts with exponential backoff, EOF stale-connection recovery (no-harm retries), timeout retries
- **Graceful fallback** — on primary failure, tries other providers in score order
- **Zero-overhead passthrough** — disable tracking to skip all chunk parsing and JSON inspection
- **Persistent selection** — chosen provider is written back to `config.yaml` as `primary: true`
- **Connection pooling** — `Net::HTTP` connections cached per thread per `scheme://host:port`
- **Pre-warm at boot** — background connections to all providers so first request skips handshake
- **Graceful shutdown** — SIGINT/SIGTERM handler cleans up pooled connections
- **JSON or text logging**

## Architecture

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

- `proxy.rb` — Sinatra app handling routing, retry logic, streaming, chunk parsing, metrics tracking.
- `provider_selector.rb` — per-model scorer. Maintains rolling samples (TTFT + TPS), prunes older than 10 min. After `probe_interval` requests, sends test prompt to non-active providers, scores all, switches if a better provider exceeds current by hysteresis (`10%`). Writes `primary: true` back to `config.yaml`.
- `ChunkResult` struct — fast string-match parsing of SSE chunks. No `JSON.parse` except for `usage` blocks. When tracking is off, parsing is skipped entirely.

## Quick Start

### Local

```bash
bundle install
cp config.yaml.example config.yaml
vim config.yaml
bundle exec puma -C puma.rb
```

Exposes `http://localhost:4567`.

### Docker Compose

```bash
cp config.yaml.example config.yaml
vim config.yaml
docker compose up -d
```

Exposes `http://localhost:9234`.

Config is mounted from host (`./config.yaml:/app/config.yaml`) so edits apply without rebuild. To rebuild after code changes:

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

Each model lists one or more providers. Optional `primary: true` on a provider sets the initial active choice. The proxy updates this field when it switches.

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
  backoff_base: 1      # seconds (1, 2, 4, ...)
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
  probe_interval: 3           # run background probe every N requests
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `4567` | Sinatra listen port |
| `BIND` | `0.0.0.0` | Sinatra bind address |
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
      - ./config.yaml:/app/config.yaml
    restart: unless-stopped
    environment:
      - RUBY_ENV=production
```

Editable fields:
- `ports` — change left side to remap host port.
- `volumes` — mount your `config.yaml` from host.
- `environment` — add any env vars from the table above (e.g. `PUMA_MAX_THREADS=32`).
