---
title: v1.0.0 readiness - review findings and where each one went
created: 2026-10-07
---

# v1.0.0 readiness

## Status (2026-10-07): fixes and features merged; waiting on rts applies and tags

Six reviews ran ahead of 1.0, each read-only, against the code at `main`
after #44:

- the service;
- the image and chart;
- the Coder template;
- the VS Code extension;
- the docs;
- CI, the release, and the Terraform provider.

This page tracks every "fix before 1.0" finding and where it was handled.
"Later" findings are listed at the end.

## Where the fixes are

| Area | PR | Findings it covers |
|---|---|---|
| Service | #51 ✅ (verified on a scratch release) | userinfo in repository URLs (argv, errors, logs, Sentry, spans); repository URL schemes (SSRF, `git://` only behind an opt-in); image names not lowercased; `exit` vs `close`; timeouts and a concurrency limit; buildx builder race; `http://` registry prefixes bypassing `insecureRegistries`; caller-controlled `cacheTo`/`cacheFrom`; `Object.hasOwn`; undeclared `pino`; OpenAPI for `/logs`; the remote's default branch when `branch` is omitted; OTel service name and shutdown |
| Image + chart | #46 ✅ (verified on a scratch release: uid 2000, read-only root) | Node 20 end of life; base image digests; pinned `@devcontainers/cli`; `npm ci`; an init process; a numeric `USER`; OCI labels; pod/container `securityContext`; `automountServiceAccountToken`; termination grace; `values.schema.json` (one replica: logs are per pod); the chart-owned namespace with bundled BuildKit; HELM.md accuracy |
| Template | #47 ✅ | shared image tags deleted under other workspaces (per-workspace tags); `postAttachCommand` racing the other hooks; interrupted clones never retried; `git init -b` and missing git; shell quoting; provider version bounds; storage growth after creation; parameter texts (GiB, the fallback); `seed-home` failures; mount path collisions; repository settings overwriting user settings; the node arch selector; `subdomain_apps` in the reference |
| Extension | #48 ✅ | session tokens sent to a workspace-configured URL; `XDG_CONFIG_HOME`; API timeouts; waits that never end or end on a single error; interval overflow; Restricted Mode declared (`limited`); stale "Check for Rebuild" results; failed/stopping workspaces; credentials typed into repository URLs; unpushed changes alongside Rebuild; git argument hygiene; askpass during background fetches; login fallback; JSONC strings; force-pushed image commits; a Marketplace CHANGELOG and name |
| Docs + CI | #45 ✅ | quickstart namespace and troubleshooting; the provider page (data source, `commit`, the deprecated module); ADR-0014 (hostRequirements are minimums); security, troubleshooting and uninstall pages; terminology; README; stale doc paths; CHANGELOG order and compare links; CI permissions and concurrency; template validation and a Docker build on PRs; release prerelease handling, `latest` only for the highest version, and `npm ci`; docs deploy permissions; actions pinned to SHAs; Dependabot |
| Provider | provider #5 ✅ (not released) | credentials updatable without a rebuild; `branch` resolved by the service instead of defaulting to `main`; tests against a fake service; CHANGELOG; import; goreleaser signing; pinned actions; Dependabot |

## Done overnight (2026-10-07)

All merged on `main`, each verified as noted:

- **Fix PRs:**
  - service hardening #51 (scratch release: credentials in URLs, schemes, tags and cache types → 400;
    no token in logs);
  - image and chart #46 (scratch release as uid 2000 with a read-only root: real build plus `/logs`);
  - template robustness #47 (scratch workspace: per-workspace tag, clone marker, Rebuild);
  - extension hardening #48;
  - docs and CI #45;
  - provider readiness (provider #5, not released).
- **Follow-ups:**
  - Node 24 in CI and chart values for the new settings #54;
  - `helm upgrade --reuse-values` from 0.5.0 crashing #56 (reproduced on a real 0.5.0 release);
  - template picker matching names #58;
  - dead pre-Thomas BDD files #62.
- **Features:**
  - `customizations.kubernetes` for pod resources and node placement #59 (ADR-0015; scratch workspace:
    requests and limits applied, hostRequirements and placement ignored with warnings);
  - one image per devcontainer.json in sub-folders #60 (ADR-0016, additive API; scratch release:
    dry run, a folder build, a root build unchanged, unknown ids → 400).
- **Tests:**
  - route tests and a fake registry #61: 87% → 94% lines, 74% → 88% branches, 129 unit tests;
  - BDD `request_validation` on the cluster: 53 of 53 scenarios.
- **Docs:**
  - clone-command screenshots captured by the script #53;
  - repositories and registries tutorials #57 (public with GHCR; private with each user's account;
    private over SSH with a pinned deploy key, all verified).

## Waiting for you

- **rts-terraform PRs (you apply):**
  - #37 Harbor;
  - #38 Coder subdomain apps (wildcard access URL);
  - #39 template sync of #47.
  - And syncs of #59/#60 once you're happy with them.
- **Coder Registry:** coder/registry#1167, waiting for Coder's maintainers (updated with the current
  template and a screenshot).
- **Tags:** provider 1.0.0, then devcontainer-builder 1.0.0.
- **GHCR retention:** per-workspace tags accumulate, because GHCR can't delete through the registry
  API.

## Still open before tagging

- **Multiple configurations end to end:**
  - provider `images`/`instances` (PR in progress);
  - template Phase A, keyed by instance with `moved` blocks (PR in progress);
  - then Phase B, which needs a provider release.
- **Harbor tutorial** once rts #37 is applied, including whether `DELETE /image` by digest can remove
  another tag that shares it.

## Decisions for the maintainer

- **Tags:** provider 1.0.0, then devcontainer-builder 1.0.0. These go only on your go.
- **Coder Registry:** coder/registry#1167 is waiting for Coder's maintainers. The suggestion is to
  not hold 1.0 for it.
- **Breaking changes in 1.0** (listed in the CHANGELOG):
  - `hostRequirements` are now minimums;
  - repository URLs with userinfo, and `file://`/`http://` URLs, are rejected;
  - per-workspace image tags, so each workspace rebuilds once on update;
  - the chart no longer owns its namespace when bundling BuildKit.
- **Kept on purpose:** the pre-0.3.0 uid-1000 fallback in the template (an upgrade must never dead-end),
  to be removed in 2.0.

## Later (not blocking 1.0)

- **Service:**
  - an RFC 9457 `problem+json` error shape (it can be added with content negotiation later);
  - `sshHostKeyPolicy: pinned` as the default;
  - streaming size limits in the registry client.
- **Template:**
  - Dev Container variables in a Secret instead of the Deployment's env;
  - the git token from external auth stays in Terraform state (documented in the security page).
- **Extension:** check scheduling tests beyond the scheduler module.
- **Provider:** per-resource `timeouts`, validators, `MarkdownDescription`.
- **Tests:**
  - route tests with Fastify `inject()` and a fake registry (`server.ts` has no unit coverage; the
    service is at about 70% of lines);
  - faster BDD runs.
- **Kubernetes-native resources in devcontainer.json** (requested 2026-10-07): a tool-specific
  `customizations` block (e.g. `customizations.kubernetes`) with requests/limits for cpu, memory
  and ephemeral storage, plus node selector and tolerations. When present, it overrides
  `hostRequirements`. Needs: the service exposing it through `GET /devcontainer`, the provider's
  data source, and the template mapping (capped like today), plus an ADR.
- **Harbor** (rts #37): a self-hosted registry, after which come private-registry tutorials.
- **Multiple Dev Container configurations** ([plan 004](004-devcontainer-instance-list.md)):
  - the service side can land additively (`images[]` next to today's single-image fields);
  - the template side needs a provider release.
