FROM debian:bookworm-slim
# Human bootstrap only: you need curl to fetch a seed. Everything else the seed grows.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
CMD ["/bin/sh"]
