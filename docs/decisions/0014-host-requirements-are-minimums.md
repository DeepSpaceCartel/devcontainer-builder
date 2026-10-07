<title>ADR-0014</title>

# ADR-0014: `hostRequirements` are minimums

Status: accepted
Date: 2026-10-07

Supersedes the `hostRequirements` consequence of
[ADR-0012](0012-dev-container-to-kubernetes-runtime-mapping.md) ("override
the template's CPU, Memory and Disk parameters"). The rest of ADR-0012
stands.

## Context

[ADR-0012](0012-dev-container-to-kubernetes-runtime-mapping.md) translated a
repository's `hostRequirements` (`cpus`, `memory`, `storage`) into the
workspace pod's resources by **replacing** the template's CPU, Memory and
Disk parameters with them. Running that in practice showed two problems:

1. **It could make a workspace smaller than the user asked for.** A
   repository declaring `"cpus": 2` capped a user who picked 4 CPU on the
   create form at 2. The parameter was silently ignored.
2. **It reserved nothing.** Pod requests stayed a fixed 250m CPU / 512Mi,
   and `hostRequirements` only set limits. A heavy repository could be
   scheduled onto a nearly full node and be OOM-killed later, rather than
   waiting for a node that actually had room.

The [Dev Container specification](https://containers.dev/implementors/json_reference/#min-host-reqs)
defines `hostRequirements` as **minimum** host requirements, not exact
sizes. ADR-0012's constraint still holds: Coder can't take a parameter's
default from the image, so the parameters and `hostRequirements` have to be
reconciled in the template, not on the create form.

## Decision

We treat `hostRequirements` as minimums, as the spec does:

- `cpus` and `memory` become the pod's **requests**, so the scheduler
  reserves them. The reservation is capped by two new template variables,
  `max_cpu` (default 8) and `max_memory` (GiB, default 32); above a cap the
  workspace reserves the cap and the build log shows a warning.
- The **limits** are the larger of the requirement and the CPU/Memory
  parameter.
- `storage` sizes the PVC as the larger of it and the Disk parameter, so a
  volume never shrinks.
- Where the parameter wins, values keep their `"<n>Gi"` form, so existing
  deployments and PVCs see no spurious Terraform diffs.
- The workspace page shows what the workspace got as agent metadata,
  **Resources (reserved / limit)**.

Without `hostRequirements`, nothing changes (requests 250m CPU / 512Mi,
limits from the parameters).

## Consequences

- A user's CPU/Memory/Disk choice is never lowered by the repository; it
  can only be raised.
- Heavy repositories either get a node with real capacity or stay
  `Pending` with a scheduling reason, instead of failing later under
  memory pressure.
- **Breaking:** a repository's `hostRequirements` now reserve node
  capacity. Clusters sized around the old fixed requests may fit fewer
  workspaces; `max_cpu`/`max_memory` are the operator's lever for that.
- Two more template variables to understand and tune.
