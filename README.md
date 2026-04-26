# LLM Proxy

A Ruby-based LLM proxy with primary/fallback support, streaming, and per-model routing.

## Features

- **OpenAI-compatible API** — drop-in replacement for OpenAI endpoints
- **Per-model routing** — each model defines its own primary and fallback provider
- **Provider references** — define providers once, reference by name in models
- **Streaming with TPS stats** — SSE streaming with TTFT, token counts, and TPS logging
- **Automatic retry** — configurable attempts with exponential backoff
- **Graceful fallback** — switches to fallback provider after primary failure
- **Configurable timeouts** — open, read, and write timeouts per config
- **Embeddings support** — with fallback and retry
- **Request logging** — request IDs, elapsed time, per-stream token stats
- **Connection pooling** — persistent HTTP connections via `http` gem (httprb)
- **Graceful shutdown** — clean connection cleanup on SIGINT/SIGTERM
- **JSON logging** — optional structured log output for monitoring systems
- **Zero-overhead mode** — disable tracking for pure passthrough (no parsing overhead)
- **URI caching** — cached URI parsing per provider+path
- **Pre-warm connections** — optional background connection warming at boot
- **Optimised chunk parsing** — lazy string matching (no JSON.parse) for token detection

## Quick Start

### Local

```bash
bundle install
cp config.yaml.example config.yaml
vim config.yaml
bundle exec puma -C puma.rb
```

### Docker

```bash
cp config.yaml.example config.yaml
vim config.yaml
docker compose up -d
```

To rebuild after code changes:

```bash
docker compose up -d --build
```

Exposes `http://localhost:9234` (Docker) or `http://localhost:4567` (local).

### Puma Thread Tuning

For high-concurrency workloads, adjust thread pool in `puma.rb` or via environment:

```bash
PUMA_MIN_THREADS=4 PUMA_MAX_THREADS=32 bundle exec puma -C puma.rb
```

I/O-bound proxy workloads benefit from more threads (16-32) since most time is waiting on upstream providers.

## Configuration

Define providers with shared credentials, then reference them in models:

```yaml
providers:
  fireworks:
    base_url: "https://api.fireworks.ai/inference/v1"
    api_key: "YOUR_FIREWORKS_API_KEY"
    headers: {}

  alibaba:
    base_url: "https://coding-intl.dashscope.aliyuncs.com/v1"
    api_key: "YOUR_ALIBABA_API_KEY"

models:
  - name: "glm-5"
    providers:
      - provider: "fireworks"
        model: "accounts/fireworks/routers/glm-5-fast"
      - provider: "alibaba"
        model: "glm-5"
```

Each model has a list of providers. The proxy auto-selects the best one based on real-time TTFT and TPS metrics. The first provider is used initially; if it fails, others are tried in metric order.

### Timeouts

```yaml
timeouts:
  open: 30    # connection open (seconds)
  read: 300   # read timeout, per-chunk for streaming
  write: 60   # write timeout for request body
```

### Retries

```yaml
retries:
  max_attempts: 3
  backoff_base: 1      # seconds (1, 2, 4)
  primary_fail_wait: 3  # seconds before switching to fallback
```

### Logging

```yaml
logging:
  level: "info"        # debug, info, warn, error
  format: "json"       # json or text (default: text)
```

### Tracking (TPS Stats)

```yaml
tracking:
  enabled: true        # false = zero-overhead passthrough (no parsing)
```

When `enabled: false`, the proxy skips all chunk parsing and token counting — it becomes a pure pipe with negligible CPU overhead. TPS logging is suppressed.

### Performance

```yaml
performance:
  prewarm_connections: true   # background connection warming at boot (default: true)
```

Pre-warming connects to all configured providers in a background thread on startup, so the first request doesn't pay TCP/TLS handshake latency. Failures are logged but non-fatal.

## Usage

```bash
curl http://localhost:9234/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm-5",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completions (streaming) |
| `/v1/completions` | POST | Legacy completions (streaming) |
| `/v1/embeddings` | POST | Embeddings (with fallback) |
| `/v1/models` | GET | List configured models |
| `/v1/models/:name` | GET | Get model routing details |
| `/health` | GET | Health check |

## Streaming Stats

Every streaming request logs token statistics:

```
[glm-5/primary] Success | content=187 thinking=42 ttft=0.342s content_tps=54.3 thinking_tps=18.7
```

- **content** — output tokens (delta.content / delta.text)
- **thinking** — reasoning tokens (delta.reasoning_content / delta.thinking / delta.reasoning)
- **ttft** — time to first token
- **content_tps** — content tokens per second (measured from first content token)
- **thinking_tps** — thinking tokens per second (measured from first token)

## Retry Behaviour

1. Primary: `max_attempts` retries with exponential backoff
2. If all attempts fail, wait `primary_fail_wait` seconds
3. Fallback: `max_attempts` retries with exponential backoff
4. If all fail, return error
