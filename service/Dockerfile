# syntax=docker/dockerfile:1

# Node 24 (Active LTS). Pinned by digest for reproducible builds - the tag
# is kept alongside for readability; bump both together (the digest is the
# multi-arch index from `docker buildx imagetools inspect node:<tag>`).
ARG NODE_IMAGE=node:24-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20

FROM ${NODE_IMAGE} AS runtime-base

# The service's behavior is checked against this exact devcontainers CLI
# version (see the "checked against the 0.89.0 bundle" comments in
# src/build.ts, src/devcontainer-metadata.ts, src/devcontainer-variables.ts).
# Bump deliberately, re-checking those, never implicitly.
ARG DEVCONTAINERS_CLI_VERSION=0.89.0

LABEL org.opencontainers.image.title="devcontainer-builder" \
      org.opencontainers.image.description="Builds a container image from a git repository's devcontainer.json using a remote BuildKit builder, and pushes it to a registry." \
      org.opencontainers.image.source="https://github.com/DeepSpaceCartel/devcontainer-builder" \
      org.opencontainers.image.url="https://github.com/DeepSpaceCartel/devcontainer-builder" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="DeepSpaceCartel"

# git + docker-ce-cli + docker-buildx-plugin (no dockerd - buildx talks to a
# remote BuildKit daemon over TCP) + the devcontainers CLI itself. tini is
# PID 1 (see ENTRYPOINT below) so orphaned ssh/git/buildx children get
# reaped and signals reach node.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git gnupg openssh-client tini \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && npm install -g "@devcontainers/cli@${DEVCONTAINERS_CLI_VERSION}" \
    && npm cache clean --force \
    && apt-get purge -y gnupg \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# uid/gid 2000, fixed: the release/dev stages' `USER 2000:2000` is numeric
# (not the name) so Kubernetes' runAsNonRoot can verify it, and
# charts/devcontainer-builder's securityContext/podSecurityContext defaults
# match it - change all of them together.
RUN groupadd --gid 2000 builder \
    && useradd --create-home --uid 2000 --gid 2000 builder \
    # Pre-created (not left for Kubernetes to synthesize) so it's owned by
    # builder: a Secret volume mounted via subPath at .docker/config.json
    # (see charts/devcontainer-builder) only replaces that one file - the
    # directory itself is whatever the image already has. Root-owned would
    # block `docker buildx create`'s own `.docker/buildx/` state dir with
    # "permission denied".
    && mkdir -p /home/builder/.docker && chown 2000:2000 /home/builder/.docker

ENV PORT=8080
EXPOSE 8080

FROM ${NODE_IMAGE} AS source-build
WORKDIR /app
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci
COPY src ./src
RUN npm run build

# Release target: installs the exact npm version this image is meant to
# ship, from the registry - not this checkout's source - so the published
# package and the image running it are provably the same artifact. Requires
# PACKAGE_VERSION to already be live on npm (see .github/workflows/release.yaml,
# where the `image` job depends on `npm` publishing first). Retried, because
# "live" isn't instant: right after `npm publish`, a version's metadata can
# resolve while its tarball still 404s for a few minutes (v0.2.0's first
# image build failed exactly that way) - and each platform's build may hit a
# different registry edge.
FROM runtime-base AS release
ARG PACKAGE_VERSION
ARG NPM_INSTALL_ATTEMPTS=20
ARG NPM_INSTALL_RETRY_SECONDS=15
LABEL org.opencontainers.image.version="${PACKAGE_VERSION}"
RUN test -n "$PACKAGE_VERSION" \
    && for attempt in $(seq 1 "$NPM_INSTALL_ATTEMPTS"); do \
         npm install -g "@deepspacecartel/devcontainer-builder@${PACKAGE_VERSION}" && npm cache clean --force && exit 0; \
         echo "npm install of ${PACKAGE_VERSION} failed (attempt ${attempt}/${NPM_INSTALL_ATTEMPTS}), retrying in ${NPM_INSTALL_RETRY_SECONDS}s..." >&2; \
         npm cache clean --force >/dev/null 2>&1 || true; \
         sleep "$NPM_INSTALL_RETRY_SECONDS"; \
       done; \
       echo "npm install of ${PACKAGE_VERSION} still failing after ${NPM_INSTALL_ATTEMPTS} attempts" >&2; exit 1
USER 2000:2000
WORKDIR /home/builder/app

ENTRYPOINT ["tini", "--", "devcontainer-builder"]

# Local/dev target: builds straight from this checkout's source, no network
# dependency beyond npm's own lockfile install. This is what a bare
# `docker build service/` (no --target) produces - kept last in the file so
# that stays true without anyone having to remember a flag. Use this for
# local iteration and testing against a local cluster before anything's
# released.
FROM runtime-base AS dev
ARG VERSION=dev
LABEL org.opencontainers.image.version="${VERSION}"
USER 2000:2000
WORKDIR /home/builder/app

COPY --from=source-build --chown=2000:2000 /app/dist ./dist
COPY --from=source-build --chown=2000:2000 /app/node_modules ./node_modules
COPY --from=source-build --chown=2000:2000 /app/package.json ./package.json

ENTRYPOINT ["tini", "--", "node", "dist/index.js"]
