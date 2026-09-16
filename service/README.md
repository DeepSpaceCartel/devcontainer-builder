# @deepspacecartel/devcontainer-builder

Builds a container image from a git repository's `.devcontainer.json` using a
remote [BuildKit](https://github.com/moby/buildkit) builder, and pushes it to
a registry - so a [Coder](https://github.com/coder/coder) Workspace Template
running on Kubernetes can boot a workspace straight from a repo URL.

Full docs: <https://deepspacecartel.github.io/devcontainer-builder/>

## Quickstart

```bash
npx @deepspacecartel/devcontainer-builder --buildkit-endpoint tcp://buildkit.example:1234
```

Needs `docker` (with the `buildx` plugin), `@devcontainers/cli`, and `git` on
`PATH` locally - this CLI doesn't bundle or replace any of them. It's the
same server the [Helm chart](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/charts/devcontainer-builder)
deploys and the [Docker image](https://github.com/DeepSpaceCartel/devcontainer-builder/pkgs/container/devcontainer-builder)
runs - every flag/env var/settings-file field is identical either way. See
[Configuration](https://deepspacecartel.github.io/devcontainer-builder/reference/CONFIGURATION/)
for the full list, and the [API reference](https://deepspacecartel.github.io/devcontainer-builder/api-reference.html)
for the HTTP surface once it's running.

## License

MIT - see [LICENSE](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/LICENSE).
