---
title: gh auth login's default token scopes can't push to GHCR
created: 2026-09-06
---

# `docker login ghcr.io` can succeed and still fail on push

## What happened

Building and pushing a scratch test image to GHCR
(`ghcr.io/alexanderilyin/devcontainer-builder-test`) for the BDD suite's
Kubernetes-based service startup:

```
gh auth token | docker login ghcr.io -u alexanderilyin --password-stdin
# Login Succeeded
docker buildx build ... --push ...
# ERROR: failed to push ghcr.io/...: denied: permission_denied: The token
# provided does not match expected scopes.
```

`docker login` succeeded - the token is valid and authenticates fine - but
push was denied anyway.

## Root cause

`gh auth login`'s default token scopes (`gist`, `read:org`, `repo`) don't
include `write:packages` (or `read:packages`). `repo` is enough to
authenticate against `ghcr.io` at all, which is why `docker login` reports
success, but GHCR's package-write permission check is separate from repo
access and rejects the push with a scope error rather than an auth error.

## Fix

```
gh auth refresh -h github.com -s write:packages,read:packages,delete:packages
gh auth token | docker login ghcr.io -u <user> --password-stdin
```

`gh auth refresh` updates the same cached token in place - no need to
re-run `gh auth login` from scratch. Re-run the `docker login` afterward so
the docker credential store picks up the refreshed token.

`gh auth refresh` is itself interactive - it can't just add scopes to the
existing token silently. It prints a one-time device code and a
`https://github.com/login/device` URL and blocks until that code is
entered in a browser and the authorization is confirmed there, e.g.:

```
! First copy your one-time code: XXXX-XXXX
Open this URL to continue in your web browser: https://github.com/login/device
✓ Authentication complete.
```

`delete:packages` was added while investigating a *different* problem
(changing a container package's visibility via the API - see below) and
turned out not to fix that; it's included above only because it was already
granted and there's no reason to narrow it back down. `write:packages` +
`read:packages` alone are sufficient for push/pull.

## A related dead end: package visibility can't be changed via the API

`gh api -X PATCH /user/packages/container/<name> -f visibility=public`
returns a plain 404 for a personal-account-owned container package, even
with a freshly refreshed token that includes `delete:packages`, and even
though `GET` on that exact same path succeeds. This isn't a scope problem -
GitHub's REST API does not support changing a personal-account container
package's visibility at all; it's a web-UI-only action (package's
"Package settings" page, Danger Zone -> Change visibility).
