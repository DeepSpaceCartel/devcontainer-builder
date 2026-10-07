<title>Private repositories over SSH with a deploy key</title>

# Private repositories over SSH with a deploy key

devcontainer-builder clones over SSH with a read-only **deploy key**, and the
remote's host key is **pinned**, so a spoofed server can't receive the key.
Use it when builds shouldn't depend on individual developers' accounts, or
for git hosts without a Coder external auth integration.

This was verified end to end on a private repository: a read-only deploy key
with the pinned GitHub host key built it, and a wrong pinned key made the
clone fail with `REMOTE HOST IDENTIFICATION HAS CHANGED`.

## 1. Create the key

```bash
ssh-keygen -t ed25519 -N '' -C devcontainer-builder -f devcontainer-builder-deploy
```

Add `devcontainer-builder-deploy.pub` to the repository as a **read-only** deploy
key (GitHub: *Settings → Deploy keys*; GitLab: *Settings → Repository →
Deploy keys*). A deploy key covers one repository. For many repositories,
use a machine user's key instead.

## 2. Pin the host key

Get the host's key from a source you trust, not from the network path you're
protecting. GitHub publishes its keys:

```bash
curl -s https://api.github.com/meta | jq -r '.ssh_keys[] | select(startswith("ssh-ed25519"))'
```

For your own git server, take the key from the server itself
(`/etc/ssh/ssh_host_ed25519_key.pub`).

## 3. Give the key to devcontainer-builder

In your Helm values:

```yaml
sshHostKeyPolicy: pinned
gitCredentials:
  entries:
    - host: github.com
      kind: ssh
      privateKey: |
        -----BEGIN OPENSSH PRIVATE KEY-----
        ...
        -----END OPENSSH PRIVATE KEY-----
      pinnedHostKey: "github.com ssh-ed25519 AAAA..."
```

Prefer `gitCredentials.existingSecret`, a Secret you create with a
`git-credentials.json` key holding the same list, so the private key isn't in
your values file. `sshHostKeyPolicy: pinned` makes every SSH credential require
a pinned key. With the default `tofu`, the first key seen is trusted.

## 4. Use SSH URLs

Workspaces are created with the repository's SSH URL, e.g.
`git@github.com:<org>/<repo>.git`. The build uses the deploy key.

The **clone inside the workspace** is the user's own: the template uses
Coder's `coder gitssh`, so each user adds their Coder SSH public key (`coder
publickey`) to their GitHub account once. The deploy key never reaches
workspaces.

## Rotating the key

Add the new key as a second deploy key and update the credentials. The chart
restarts the pod by itself when inline `entries` change; with
`existingSecret`, restart it yourself (`kubectl -n devcontainer-builder
rollout restart deploy/devcontainer-builder`). Then remove the old key.
