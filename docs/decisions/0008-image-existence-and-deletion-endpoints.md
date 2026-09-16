<title>ADR-0008</title>

# ADR-0008: `GET`/`DELETE /image` for existence checks and best-effort deletion

Status: accepted
Date: 2026-09-12

## Context

A Terraform **provider** ([`terraform-provider-devcontainer-builder`](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder),
its own repo) was built alongside the existing
`terraform/devcontainer-build` module, wrapping `POST /build` as a
`devcontainerbuilder_build` resource instead of a `data "http"` source — so
a build only runs on `apply`, not on every `plan` (see
`docs/reference/TERRAFORM.md`).

A resource's `Read` and `Delete` need something to actually do. With only
`POST /build` available, both would have been permanent no-ops: `Read`
could never tell whether the built image still existed, and `Delete` had
nothing to call. That's a real gap, not just an awkward provider detail —
without it, `terraform plan` can never reflect an image that was deleted or
retagged out-of-band, and `terraform destroy` can never clean anything up.

## Decision

Add two new routes, `GET /image?registry=&name=&tag=` and
`DELETE /image?registry=&name=&tag=`, implemented against the real Docker
Registry HTTP API V2 (bearer-token challenge/exchange, manifest
GET/DELETE) via a new `service/src/registry-client.ts` — the service
previously never spoke that protocol directly, delegating all registry
interaction to `devcontainer build --push`'s subprocess chain.

Specific choices:

- **Query params, not path segments**, for `registry`/`name`/`tag` — both
  legitimately contain `/` (e.g. `ghcr.io/org/repo`), which path segments
  can't cleanly express without ambiguity.
- **Credentials as headers (`X-Registry-Username`/`X-Registry-Password`),
  never query params** — consistent with ADR-0002's "credentials never
  touch argv or URLs" rationale; a query param would land in access logs.
  Falls back to the service's ambient `DOCKER_CONFIG/config.json` (the same
  source `build.ts`'s `withRegistryAuthEnv` seeds from) when omitted, via a
  new small shared `service/src/docker-config.ts` helper.
- **`DELETE /image` returns `200 {deleted:false, reason}` for a registry
  that refuses deletion (405/400/501 from the registry), not an error.**
  Several major registries (Docker Hub notably) don't support manifest
  deletion via the standard API at all — that's an external limitation the
  caller can't fix, so it isn't treated as a request failure. A genuine
  auth/network failure (401/403/other) still surfaces as a 502 error,
  since that usually *is* something the caller can fix (wrong credentials).
- **`GET /image` returning `exists: false` is a normal `200`, not a `404`.**
  "The image isn't there" is a valid, successful answer for this endpoint
  (it's the expected way Terraform detects drift), not an error condition.
- **No new dependency.** Node 20's built-in `fetch` is sufficient for the
  bearer-challenge flow (parse `WWW-Authenticate`, exchange for a token,
  retry once) — `service/package.json` still has exactly one dependency
  (`yaml`).
- **`BuildResponse` gained `registry`/`name`/`tag` fields** (additive,
  alongside the existing `image` string) so callers don't have to re-parse
  an image reference, which is genuinely ambiguous in general (registry
  ports, default-registry conventions, tag-vs-digest forms). The service
  already computes these three values internally during a build; it just
  didn't hand them back before.

## Consequences

- **Real drift detection becomes possible**: the provider's `Read` can now
  tell whether its image still exists and drop it from state (triggering
  recreation) if not — something no `data "http"` source could ever do.
- **Real cleanup becomes possible on `terraform destroy`**, where the
  registry supports it.
- **A new capability, not just a new no-auth-required read**: the service
  already accepted arbitrary registry credentials in `POST /build` and
  pushed wherever told, so a network-adjacent caller already had
  equivalent blast radius for *creating* images. These two routes add
  *deletion* as a capability that didn't exist before, on the same
  unauthenticated API surface (still cluster-internal-only, no auth added
  to the service itself). Worth a second look from whoever owns this
  service's security posture before this ships somewhere it matters.
- **Deletion is registry-dependent and known-incomplete**: the "unsupported"
  branch is an honest, expected outcome for several major registries, not a
  bug to chase. Multi-arch manifest lists are handled by deleting only the
  top-level tag manifest digest — per-platform sub-manifests are not walked
  and deleted individually. Both are acceptable simplifications for a first
  pass, not silently swept under the rug.

**Alternatives considered**: giving the service its own persistent build-ID
tracking (an in-memory or on-disk record per build, looked up by an opaque
ID) — rejected in favor of treating the registry itself as the source of
truth. An in-memory record is wiped on every pod restart, which would cause
spurious drift (Terraform thinking an image vanished just because the pod
recycled) — worse than no drift detection at all. The registry's own state
doesn't have that problem, and the service already computes exactly the
`registry`/`name`/`tag` triple needed to ask it directly.
