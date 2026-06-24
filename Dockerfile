# Lockwell runtime image — assembled from the official prebuilt binary.
#
# No source is compiled here. The first stage only DOWNLOADS the released,
# checksum-verified static binary for the build host's architecture and the
# final stage wraps it in a slim Debian base. `docker compose up -d --build`
# (or `docker build`) produces a local image; nothing is pulled from a private
# registry.

FROM debian:bookworm-slim AS fetch
ARG LOCKWELL_VERSION=0.2.1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/dl
# `dpkg --print-architecture` returns amd64 / arm64, which matches the release
# asset names, so the same Dockerfile builds correctly on x86-64 and ARM hosts.
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    base="https://github.com/KelpHect/lockwell-deploy/releases/download/v${LOCKWELL_VERSION}"; \
    asset="lockwell-${LOCKWELL_VERSION}-linux-${arch}.tar.gz"; \
    curl -fsSLO "${base}/${asset}"; \
    curl -fsSLO "${base}/SHA256SUMS"; \
    grep " [*]${asset}\$" SHA256SUMS | sha256sum -c -; \
    tar -xzf "${asset}"; \
    mv "lockwell-${LOCKWELL_VERSION}-linux-${arch}/lockwelld" /lockwelld; \
    mv "lockwell-${LOCKWELL_VERSION}-linux-${arch}/lockwell" /lockwell

# Runtime stage
FROM debian:bookworm-slim

# curl is shipped so the HEALTHCHECK below has something to call out to.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r lockwell && useradd -r -g lockwell -u 1000 lockwell

COPY --from=fetch /lockwelld /lockwell /usr/local/bin/

# Bake the production config as the default (override it by mounting your own at
# /etc/lockwell/lockwell.toml) and install the first-boot bootstrap entrypoint.
COPY examples/lockwell.production.toml /etc/lockwell/lockwell.toml
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/lockwelld /usr/local/bin/lockwell \
    && mkdir -p /var/lib/lockwell/blobs /var/lib/lockwell/tmp /var/lib/lockwell/shared \
    && chown -R lockwell:lockwell /var/lib/lockwell /etc/lockwell

USER lockwell

EXPOSE 9000 9001

ENV LOCKWELL_CONFIG=/etc/lockwell/lockwell.toml

# Health probe targets the S3 listen-addr's /health endpoint. start-period gives
# the embedded metadata engine time to open + the listeners to bind on a fresh
# boot (no external database, no migrations).
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
    CMD curl -fsS http://127.0.0.1:9000/health || exit 1

# The entrypoint bootstraps the root tenant/key (when LOCKWELL_ROOT_* env is set)
# then exec's the daemon. Override the command for one-off CLI use, e.g.:
#   docker run --rm -v lockwell-data:/var/lib/lockwell <image> lockwell key-create ...
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["lockwelld"]
