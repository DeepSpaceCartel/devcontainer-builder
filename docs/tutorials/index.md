<title>Repositories and registries</title>

# Repositories and registries

Real setups, end to end: where the code comes from, who can read it, and
where the images go. Each one was run against a real cluster before it was
written down.

| Your situation | Git access for the build | Git access in the workspace | Registry | Tutorial |
|---|---|---|---|---|
| Open source, public repositories | none | none | GHCR (private or public packages) | [Public repositories and GHCR](public-ghcr.md) |
| Private GitHub repositories, each developer uses their own account | each user's linked GitHub account (Coder external auth) | the same account | GHCR, private | [Private repositories with each user's account](private-github-external-auth.md) |
| Private repositories over SSH, one read-only key for the build | a deploy key on devcontainer-builder, host key pinned | the user's own key (`coder publickey`) | any | [Private repositories over SSH with a deploy key](private-ssh-deploy-key.md) |

All three use the same service and template; only the configuration
differs. How credentials are handled is in [Credential
handling](../concepts/credential-handling.md) and the [security
model](../concepts/security.md).

!!! note "Coming next"
    A self-hosted registry (Harbor) in the cluster, so private images never
    leave it.
