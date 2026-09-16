FROM node:20-bookworm-slim AS runtime-base

# git + docker-ce-cli + docker-buildx-plugin (no dockerd - buildx talks to a
# remote BuildKit daemon over TCP) + the devcontainers CLI itself.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git gnupg openssh-client \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && npm install -g @devcontainers/cli \
    && apt-get purge -y gnupg \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 2000 builder \
    # Pre-created (not left for Kubernetes to synthesize) so it's owned by
    # builder: a Secret volume mounted via subPath at .docker/config.json
    # (see charts/devcontainer-builder) only replaces that one file - the
    # directory itself is whatever the image already has. Root-owned would
    # block `docker buildx create`'s own `.docker/buildx/` state dir with
    # "permission denied".
    && mkdir -p /home/builder/.docker && chown builder:builder /home/builder/.docker

ENV PORT=8080
EXPOSE 8080

FROM node:20-bookworm-slim AS source-build
WORKDIR /app
COPY package.json tsconfig.json ./
RUN npm install
COPY src ./src
RUN npm run build

# Release target: installs the exact npm version this image is meant to
# ship, from the registry - not this checkout's source - so the published
# package and the image running it are provably the same artifact. Requires
# PACKAGE_VERSION to already be live on npm (see .github/workflows/release.yaml,
# where the `image` job depends on `npm` publishing first).
FROM runtime-base AS release
ARG PACKAGE_VERSION
RUN test -n "$PACKAGE_VERSION" \
    && npm install -g @deepspacecartel/devcontainer-builder@${PACKAGE_VERSION}
USER builder
WORKDIR /home/builder/app

ENTRYPOINT ["devcontainer-builder"]

# Local/dev target: builds straight from this checkout's source, no network
# dependency beyond npm's own lockfile install. This is what a bare
# `docker build service/` (no --target) produces - kept last in the file so
# that stays true without anyone having to remember a flag. Use this for
# local iteration and testing against a local cluster before anything's
# released.
FROM runtime-base AS dev
USER builder
WORKDIR /home/builder/app

COPY --from=source-build --chown=builder:builder /app/dist ./dist
COPY --from=source-build --chown=builder:builder /app/node_modules ./node_modules
COPY --from=source-build --chown=builder:builder /app/package.json ./package.json

ENTRYPOINT ["node", "dist/index.js"]
