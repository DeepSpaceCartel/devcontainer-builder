<title>ADR-0015</title>

# ADR-0015: `customizations.kubernetes` for pod resources and node placement

Status: accepted
Date: 2026-10-07

Builds on [ADR-0014](0014-host-requirements-are-minimums.md), which still
applies to repositories that don't use `customizations.kubernetes`.

## Context

`hostRequirements` ([ADR-0014](0014-host-requirements-are-minimums.md)) is
the only way a repository can size its workspace, and it can't say what a
Kubernetes workspace often needs:

- **A request apart from its limit.** `cpus: 4` reserves 4 cores; a repository
  can't ask for "1 core reserved, burst to 4", or for a memory limit equal to
  its request (Guaranteed QoS).
- **Other resources.** `ephemeral-storage`, a GPU count other than one, or
  any extended resource a device plugin exposes (`nvidia.com/gpu: 2`,
  `example.com/fpga`).
- **Node placement.** GPU or other dedicated nodes are usually tainted and
  labelled. A pod reaches them only with a `nodeSelector` and tolerations,
  and `devcontainer.json` has nothing that maps to either.

The Dev Container spec's extension point is `customizations.<tool>`. Each
tool owns its namespace. devcontainer-builder already exposes the image's
merged configuration to the template as the data source's
`configuration_json`, where `customizations.<tool>` is a **list**: one entry
per contributor (base image metadata, then each Feature, then
`devcontainer.json`), in that order. Reading it needs no service or
provider change.

Coder's own Dev Containers integration uses `customizations.coder`, so that
key is taken.

## Decision

The template reads **`customizations.kubernetes`**:

```jsonc
"customizations": {
  "kubernetes": {
    "resources": {
      "requests": { "cpu": "2", "memory": "4Gi", "ephemeral-storage": "10Gi" },
      "limits":   { "memory": "8Gi", "nvidia.com/gpu": "1" }
    },
    "storage": "20Gi",
    "nodeSelector": { "nvidia.com/gpu.present": "true" },
    "tolerations": [ { "key": "nvidia.com/gpu", "operator": "Exists", "effect": "NoSchedule" } ]
  }
}
```

- **Merge.** Entries merge in contribution order. `requests`, `limits` and
  `nodeSelector` merge per key, with the later entry winning. `storage` is the
  last one set. `tolerations` are appended, and identical ones are kept once.
  So a Feature can carry defaults that the repository's own `devcontainer.json`
  overrides.
- **`resources` is authoritative when it sets anything.** If the merged
  `resources` has any valid request or limit, it decides the pod's CPU and
  memory. `hostRequirements.cpus`/`.memory` (and `runArgs --cpus`/`--memory`)
  are then ignored, and the build log says which values were ignored. We
  don't combine the two: picking the larger would make a request below
  `hostRequirements` impossible, and that's the point of using
  `resources`.
- **Requests** are used as given. `cpu` and `memory` are still capped by
  `max_cpu`/`max_memory`, with a warning, as ADR-0014's are. Other names
  are passed through. When `resources` sets no CPU or memory request, the
  default (250m / 512Mi) applies, lowered to the limit if the limit is
  smaller.
- **Limits** are used as given, and are not capped: they reserve nothing.
  For `cpu`/`memory` without a limit, the limit is the larger of the request
  and the CPU/Memory parameter, as in ADR-0014. A limit below its request
  (a pod Kubernetes would reject) is raised to the request, with a warning.
- **Extended resources and hugepages** (anything but `cpu`, `memory`,
  `ephemeral-storage`) can't be overcommitted: Kubernetes requires request
  == limit and defaults the request to the limit. They're set as limits
  only, using the limit if given and else the request. A request that differs
  from the limit gets a warning.
- **GPU.** `hostRequirements.gpu` still means `nvidia.com/gpu: 1`, but a
  `nvidia.com/gpu` in `resources` wins.
- **`storage`** replaces `hostRequirements.storage` when it's set. It's a
  minimum, like `hostRequirements.storage`: the volume is the larger of it
  and the Disk parameter, decided when the workspace is created.
- **Node placement is opt-in.** `nodeSelector` and `tolerations` apply only
  with the new template variable **`allow_node_placement`** (default
  `false`). Placement is an operator decision: taints exist to keep
  workloads off nodes. With the variable off, the build log says they were
  ignored. With it on, the template's own selector keys (`kubernetes.io/arch`)
  always win.
- **Invalid input never fails the plan.** Quantities are parsed in
  Terraform locals ("500m", "1.5", "4Gi", "1G", plain numbers; no exponent
  form). Resource names must be `cpu`, `memory`, `ephemeral-storage`,
  `hugepages-<size>` or `<domain>/<name>`. Tolerations must be shaped the way
  Kubernetes accepts them. Anything else is dropped with a build-log warning,
  so a typo costs a warning and not a workspace that won't start.
- The **Resources (reserved / limit)** metadata item names the source:
  `from customizations.kubernetes`, `from hostRequirements`, or `from the
  parameters` (both, when `storage` and `resources` come from different
  places). It also lists the other resources the pod got.

## Consequences

- Repositories can describe a Kubernetes workspace in Kubernetes terms:
  separate requests and limits, Guaranteed QoS, any number of GPUs, ephemeral
  storage. The same file still works in VS Code Dev Containers and
  Codespaces, which ignore a customization namespace they don't own.
- A Feature can package a team's sizing and placement defaults.
- Operators keep their levers. `max_cpu`/`max_memory` cap what a repository
  can reserve, and `allow_node_placement` decides whether repositories may
  reach tainted or labelled nodes. Limits and extended resources aren't
  capped. A repository asking for GPUs the cluster lacks stays Pending.
- The rules live in Terraform locals (quantity parsing, merging, validation),
  so they're harder to unit-test than service code. They were checked with a
  scratch module that runs the template's locals against sample
  configurations.
- `customizations.kubernetes` is this project's own schema. It isn't part
  of the Dev Container spec or of any other tool, and changing it later is
  a breaking change for repositories that use it.
