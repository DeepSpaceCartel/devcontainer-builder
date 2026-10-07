<title>Private repositories with each user's account</title>

# Private repositories with each developer's own GitHub account

Each developer links their GitHub account in Coder once. From then on, both
the image build and the clone in the workspace use **their** access: they can
open exactly the repositories they can read on GitHub, and devcontainer-builder
holds no git credentials of its own.

This is the setup we run ourselves. It was verified against a private
repository with devcontainer-builder configured with **no** `gitCredentials`
at all: the build, the clone, a restart and a Rebuild all used the
developer's linked account.

## 1. Configure GitHub as a Coder external auth provider

Follow Coder's [external auth guide](https://coder.com/docs/admin/external-auth)
for GitHub. In short, create a GitHub App (or OAuth app) and pass it to Coder:

```bash
CODER_EXTERNAL_AUTH_0_ID=github
CODER_EXTERNAL_AUTH_0_TYPE=github
CODER_EXTERNAL_AUTH_0_CLIENT_ID=<client-id>
CODER_EXTERNAL_AUTH_0_CLIENT_SECRET=<client-secret>
```

The app needs read access to repository contents. The ID (`github` here) is
what the template refers to.

## 2. Tell the template to use it

```bash
coder templates push kubernetes-devcontainer \
  --var namespace=coder-workspaces \
  --var devcontainer_builder_endpoint=http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080 \
  --var image_pull_secret_name=devcontainer-images \
  --var external_auth_id=github
```

With `external_auth_id` set:

- **Creating a workspace** requires the user's GitHub account to be linked. The dashboard shows
  **Login with GitHub**, and **Coder: Clone Repository in Workspace…** opens the link page and
  waits.
- **The image build** gets the user's token in the build request. devcontainer-builder writes it
  to a temporary `.netrc` for the clone and never logs it, puts it in argv, or keeps it
  ([Credential handling](../concepts/credential-handling.md)).
- **The workspace's clone** uses it through Coder's `GIT_ASKPASS`, and so do the user's own `git
  pull`/`push` in the workspace.
- **A refreshed token** doesn't rebuild the image; the next Rebuild uses the current one.

## 3. Registry

Push to GHCR as in [Public repositories and GHCR](public-ghcr.md), and keep
the packages private: images of private repositories contain their code.
The nodes pull with the `devcontainer-images` pull secret.

## 4. Try it

As a developer with access to a private repository, in VS Code: **Coder:
Clone Repository in Workspace…** → **GitHub** → pick the repository. If
GitHub isn't linked yet, the command opens the link page first.

## What's in Terraform state

The token sent to the build is a `sensitive` value in the workspace's
Terraform state, which Coder stores. Treat access to Coder's database like
access to those tokens. See the [security model](../concepts/security.md).
