FROM node:20-bookworm-slim AS build
WORKDIR /app
COPY package.json tsconfig.json ./
RUN npm install
COPY src ./src
RUN npm run build

FROM node:20-bookworm-slim

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
USER builder
WORKDIR /home/builder/app

COPY --from=build --chown=builder:builder /app/dist ./dist
COPY --from=build --chown=builder:builder /app/node_modules ./node_modules
COPY --from=build --chown=builder:builder /app/package.json ./package.json

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["node", "dist/index.js"]
