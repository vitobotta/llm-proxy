# Puma configuration for LLM Proxy
# Optimized for I/O-bound proxy workload (waiting on upstream LLM providers)

# Override Puma's default 10s write timeout — LLM streaming responses can take
# minutes, and clients may briefly pause reading. The default causes
# "Socket timeout writing data" errors on long-lived streaming connections.
Puma::Const::WRITE_TIMEOUT = 300 unless Puma::Const::WRITE_TIMEOUT >= 300

# Keep-alive timeout — LLM streaming connections stay open much longer than
# typical web requests. Default is 20s which kills slow streaming responses.
persistent_timeout 300

# Thread pool settings
# Min threads: keep some warm for quick response
# Max threads: handle concurrent streaming requests
# I/O-bound workloads benefit from more threads since most time is waiting
threads ENV.fetch('PUMA_MIN_THREADS', 1), ENV.fetch('PUMA_MAX_THREADS', 16)

# Single worker process (stateless proxy, threading is sufficient)
workers 0

# Port and bind
port ENV.fetch('PORT', 4567)
bind ENV.fetch('PUMA_BIND', 'tcp://0.0.0.0')

# Environment
environment ENV.fetch('RACK_ENV', 'production')

# Allow bundler to preload for faster boot
preload_app!

# Logs go to stdout/stderr for Docker (docker logs)
