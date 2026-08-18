FROM debian:bookworm-slim
# A workstation that already has common tools. Codex is best-effort.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl ca-certificates git ripgrep python3 jq openssl \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    url=https://github.com/openai/codex/releases/latest/download/codex-aarch64-unknown-linux-musl.tar.gz; \
    if curl -fsSL --retry 3 -o /tmp/codex.tgz "$url"; then \
      tar -xzf /tmp/codex.tgz -C /tmp; \
      bin=$(find /tmp -maxdepth 2 -type f \( -name 'codex' -o -name 'codex-*linux*' \) ! -name '*.tgz' | head -1); \
      if [ -n "$bin" ]; then \
        mv "$bin" /usr/local/bin/codex; \
        chmod 755 /usr/local/bin/codex; \
      fi; \
      rm -f /tmp/codex.tgz; \
    fi
WORKDIR /work
CMD ["/bin/sh"]
