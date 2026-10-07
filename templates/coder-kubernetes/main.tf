# A Coder Workspace Template for Kubernetes, adapted from the official
# https://registry.coder.com/templates/coder/kubernetes template. The one
# real change from that upstream template: instead of a fixed/parameterized
# `image` variable, a workspace-level `coder_parameter` asks for a git
# repository (the one thing a stranger actually wants to type in), and a
# `devcontainerbuilder_build` resource (from
# https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder)
# turns it into a real, pushed image before the Deployment ever starts -
# see docs/guides/coder-workspace-template.md for the full walkthrough and
# the platform prerequisites this template itself does NOT set up (a
# running devcontainer-builder instance, BuildKit).
#
# Instances: the agent, its scripts and apps, the PVC and the Deployment
# are per Dev Container instance (local.instances), for now only `main`.
#
# Persistence: one PVC per instance (coder-<id>-data for `main`), mounted twice via
# subPaths - `home/` at the remote user's home and `workspaces/` at
# /workspaces - so both survive a pod restart. A `seed-home` init container
# copies the image's own home into the PVC on first start, so the mount
# doesn't hide the image's dotfiles (.bashrc, nvm, oh-my-zsh, ...).
#
# Dev Container behavior: a `devcontainerbuilder_devcontainer` data source
# reads the built image's merged devcontainer.json (base image + Features +
# the repo's own config). Its `remoteUser` decides whose home is persisted;
# its lifecycle commands (onCreate/updateContent/postCreate/postStart) run
# from a login-blocking script on every start - a pod's root filesystem is
# fresh each time, so they must be idempotent; and its
# customizations.vscode extensions/settings are installed into
# ~/.vscode-server, where VS Code Desktop picks them up.
terraform {
  # check blocks (1.5).
  required_version = ">= 1.5.0"
  required_providers {
    coder = {
      source = "coder/coder"
      # coder_parameter's form_type (2.4.0, fixed in 2.5.0); the vscode-web
      # and vscode-desktop modules need >= 2.5 too.
      version = ">= 2.5.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      # The pod security context's fs_group_change_policy (2.16.0).
      version = ">= 2.16.0"
    }
    devcontainerbuilder = {
      source = "deepspacecartel/devcontainer-builder"
      # >= 0.3.0 for the data source's runtime/env_scripts/variables (and a
      # devcontainer-builder service >= 0.3.0 behind it); < 2.0.0 because a
      # major version may change the schema this template uses.
      version = ">= 0.3.0, < 2.0.0"
    }
  }
}

provider "coder" {
}

# --- Template-level variables -----------------------------------------
# Set once, when this template is pushed/configured in Coder (`coder
# templates push -var ...`) - not per-workspace. See the guide for where
# each of these values actually comes from.

variable "use_kubeconfig" {
  type        = bool
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces. A valid "~/.kube/config" must be present on the Coder host.
  EOF
  default     = false
}

variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to create workspace Deployments in (must exist prior to creating workspaces)."
}

variable "devcontainer_builder_endpoint" {
  type        = string
  description = "Base URL of an already-running devcontainer-builder instance, e.g. http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080. This template never deploys devcontainer-builder or BuildKit itself - both are cluster-level platform infrastructure, set up once before this template is ever pushed. See the guide."
}

variable "image_pull_secret_name" {
  type        = string
  description = "Name of an existing Kubernetes Secret (kubernetes.io/dockerconfigjson) in `namespace`, used as an imagePullSecret for the built image. Leave empty if the registry allows anonymous pulls from your cluster's nodes."
  default     = ""
}

variable "accept_vscode_license" {
  type        = bool
  description = "Accept Microsoft's VS Code Server license (https://aka.ms/vscode-server-license) on behalf of this template's users, enabling VS Code in the browser (vscode-web, extensions from the Microsoft Marketplace). The terms allow use within your own organization; set false if workspaces are offered to others. VS Code Desktop is unaffected."
  default     = true
}

variable "allow_privileged" {
  type        = bool
  description = "Honor devcontainer.json's `privileged: true`, `--security-opt seccomp=unconfined` and capabilities beyond Pod Security baseline's list (e.g. SYS_PTRACE, NET_ADMIN). Off by default: they need a namespace whose Pod Security level allows them, and privileged pods can take over their node."
  default     = false
}

variable "subdomain_apps" {
  type        = bool
  description = "Serve VS Code in the browser and the forwarded-port apps on their own subdomains (Coder's recommendation). They need a wildcard access URL on the Coder deployment (CODER_WILDCARD_ACCESS_URL, https://coder.com/docs/admin/networking/wildcard-access-url); set false without one, and they're served on paths of the main Coder URL instead."
  default     = true
}

variable "max_forwarded_ports" {
  type        = number
  description = "How many of devcontainer.json's forwardPorts get a dashboard app. Coder needs a fixed number of app slots; unused ones are hidden."
  default     = 10
}

variable "vscode_extension" {
  type        = string
  description = "devcontainer-builder's VS Code extension (\"Dev Containers for Coder in K8S\"), installed into every workspace's VS Code: it offers to rebuild the workspace when the branch's Dev Container configuration changes on origin, and to add one where there's none. A Marketplace ID, or the http(s):// URL of a VSIX (e.g. an unreleased build). Empty to not install it."
  default     = "deepspacecartel.devcontainer-builder"
}

variable "external_auth_id" {
  type        = string
  description = "ID of a Coder external auth provider for the git host (e.g. \"github\", see https://coder.com/docs/admin/external-auth), for private repositories. When set, creating a workspace asks the user to link that account, the workspace's clone uses it (the agent's GIT_ASKPASS), and so does the image build: the user's own token is sent to devcontainer-builder instead of service-side gitCredentials. Empty: public repositories, or credentials configured on devcontainer-builder or below."
  default     = ""
}

variable "max_cpu" {
  type        = number
  description = "Most CPU cores a repository can reserve (requests), through hostRequirements.cpus or customizations.kubernetes.resources.requests.cpu - above it, the workspace gets this many and a warning."
  default     = 8
}

variable "max_memory" {
  type        = number
  description = "Most memory, in GiB, a repository can reserve (requests), through hostRequirements.memory or customizations.kubernetes.resources.requests.memory - above it, the workspace gets this much and a warning."
  default     = 32
}

variable "allow_node_placement" {
  type        = bool
  description = "Honor a repository's customizations.kubernetes nodeSelector and tolerations, e.g. to land on GPU or otherwise tainted nodes. The template's own node selector (kubernetes.io/arch) always wins. Off by default: they let any repository steer its workspaces onto nodes kept for other uses."
  default     = false
}

variable "git_credentials_username" {
  type        = string
  description = "Optional HTTPS git username, used for every workspace built from this template. Leave empty for public repositories only - devcontainer-builder's own server-side gitCredentials (configured once on the service itself) is the better place for per-host credentials that should apply regardless of which template/caller is asking."
  default     = ""
}

variable "git_credentials_token" {
  type        = string
  description = "Optional HTTPS git token/password, paired with git_credentials_username."
  default     = ""
  sensitive   = true
}

# --- Workspace parameters -----------------------------------------------
# What the person creating a workspace from this template actually fills
# in - this is the whole point of this template over the raw HTTP API or
# the bare Terraform module/provider used directly: type a repo URL, get a
# running workspace.

data "coder_parameter" "repository" {
  name         = "repository"
  display_name = "Git repository"
  order        = 1
  description  = "The git repository to work on: https://, ssh://, or SCP-style (git@host:path). Its .devcontainer/devcontainer.json (or .devcontainer.json) defines the workspace; without one, it gets devcontainer-builder's fallback image."
  icon         = "/icon/git.svg"
  mutable      = false
}

data "coder_parameter" "branch" {
  name         = "branch"
  display_name = "Branch"
  order        = 2
  description  = "Branch to build."
  default      = "main"
  icon         = "/icon/git.svg"
  mutable      = false
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  order        = 3
  description  = "The number of CPU cores"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores"
    value = "4"
  }
  option {
    name  = "6 Cores"
    value = "6"
  }
  option {
    name  = "8 Cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  order        = 4
  description  = "The amount of memory in GiB"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 GiB"
    value = "2"
  }
  option {
    name  = "4 GiB"
    value = "4"
  }
  option {
    name  = "6 GiB"
    value = "6"
  }
  option {
    name  = "8 GiB"
    value = "8"
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Disk size"
  order        = 5
  description  = "The size of the persistent disk (home + /workspaces) in GiB, set when the workspace is created"
  default      = "10"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 1
    max = 99999
  }
}

# ${localEnv:NAME} in devcontainer.json refers to the developer's machine,
# which a workspace doesn't have - values come from here instead. Coder
# can't create one parameter per variable (parameters can't depend on the
# image), so it's one free-form parameter; the "Dev Container variables"
# metadata item lists what the image uses and what's still unset.
data "coder_parameter" "devcontainer_variables" {
  name         = "devcontainer_variables"
  display_name = "Dev Container variables"
  order        = 6
  description  = "Values for $${localEnv:NAME} in the repository's devcontainer.json: one NAME=value per line. Changes apply on the next restart. Visible to anyone who can see this workspace's settings."
  type         = "string"
  form_type    = "textarea"
  default      = ""
  mutable      = true
  icon         = "/icon/docker.svg"
}

# Bump to rebuild the image from the branch's latest commit on the next
# start. The working copy in /workspaces is left as it is.
data "coder_parameter" "rebuild" {
  name         = "rebuild"
  display_name = "Rebuild"
  order        = 7
  description  = "Increase to rebuild the image from the branch's latest commit on the next start (e.g. after devcontainer.json changes). Your working copy is not touched."
  type         = "number"
  default      = 0
  mutable      = true
  icon         = "/icon/docker.svg"
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

provider "devcontainerbuilder" {
  endpoint = var.devcontainer_builder_endpoint
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  # The Dev Container instances this workspace runs, keyed by instance id:
  # each gets its own agent, PVC and Deployment (plan 004). For now a list
  # of one, `main`, the image devcontainerbuilder_build built; it becomes
  # devcontainerbuilder_build.workspace.images once the provider returns
  # one image per devcontainer.json (ADR-0016), which has these fields.
  instances = {
    main = {
      image    = devcontainerbuilder_build.workspace.image
      registry = devcontainerbuilder_build.workspace.resolved_registry
      name     = devcontainerbuilder_build.workspace.resolved_name
      tag      = devcontainerbuilder_build.workspace.resolved_tag
    }
  }
  instance_keys = keys(local.instances)
  # The ones whose resources only exist while the workspace runs (what
  # count = start_count did for the single instance).
  started_instances = { for inst, i in local.instances : inst => i if data.coder_workspace.me.start_count > 0 }

  # Kubernetes object names and labels. `main` keeps the names and labels
  # it had before instances existed (a Deployment's selector can't change,
  # and a renamed PVC would be a new, empty one); any other instance gets
  # an -<id> suffix and its own instance label, so no selector matches
  # another instance's pods.
  k8s_suffix          = { for inst in local.instance_keys : inst => inst == "main" ? "" : "-${inst}" }
  k8s_instance_labels = { for inst in local.instance_keys : inst => inst == "main" ? {} : { "com.deepspacecartel.devcontainer-builder/instance" = inst } }

  # Only read while the workspace is starting (for_each =
  # local.started_instances below), so stopping a workspace never depends
  # on devcontainer-builder being up. Per instance, as is everything below
  # that's derived from it. one() marks the whole object sensitive (the
  # data source has a sensitive input), as one(...[*]) did before
  # instances - so plans show exactly what they did.
  dc = { for inst in local.instance_keys : inst => one([for k, d in data.devcontainerbuilder_devcontainer.workspace : d if k == inst]) }

  # The user tools, IDEs and hooks run as (remoteUser, else containerUser,
  # else the image's USER, else root - resolved by devcontainer-builder)
  # and its uid/gid/home, recorded by the build: the pod runs as that user
  # from the start, and that home is persisted.
  remote_user = { for inst in local.instance_keys : inst => try(coalesce(local.dc[inst].remote_user, local.dc[inst].container_user), "root") }
  runtime     = { for inst in local.instance_keys : inst => try(local.dc[inst].runtime, null) }
  # An image built before devcontainer-builder 0.3.0 has no recorded
  # account. Fall back to uid/gid 1000 - what this template used before it
  # recorded them - so a workspace upgraded from an older template version
  # still starts (with a warning) and can then be rebuilt: Rebuild only
  # takes effect once a start has succeeded on this template version
  # (replace_triggered_by doesn't fire when terraform_data.rebuild is
  # created, only when it changes).
  recorded_uid = { for inst in local.instance_keys : inst => try(local.runtime[inst].remote_user_uid, null) }
  recorded_gid = { for inst in local.instance_keys : inst => try(local.runtime[inst].remote_user_gid, null) }
  uid          = { for inst in local.instance_keys : inst => local.recorded_uid[inst] != null ? local.recorded_uid[inst] : 1000 }
  gid          = { for inst in local.instance_keys : inst => local.recorded_gid[inst] != null ? local.recorded_gid[inst] : 1000 }
  home_dir     = { for inst in local.instance_keys : inst => try(coalesce(local.runtime[inst].remote_user_home), local.remote_user[inst] == "root" ? "/root" : "/home/${local.remote_user[inst]}") }

  lifecycle_scripts = { for inst in local.instance_keys : inst => try(local.dc[inst].lifecycle_scripts, {}) }
  env_scripts       = { for inst in local.instance_keys : inst => try(local.dc[inst].env_scripts, {}) }
  vscode_extensions = { for inst in local.instance_keys : inst => try(local.dc[inst].extensions, []) }
  vscode_settings   = { for inst in local.instance_keys : inst => try(local.dc[inst].settings_json, "{}") }
  host_requirements = { for inst in local.instance_keys : inst => try(local.dc[inst].host_requirements, null) }
  warnings          = { for inst in local.instance_keys : inst => try(local.dc[inst].warnings, []) }
  variables         = { for inst in local.instance_keys : inst => try(local.dc[inst].variables, []) }

  # devcontainer.json's workspaceFolder (default: Dev Containers'
  # "Clone Repository in Container Volume" convention,
  # /workspaces/<repo name>), with the workspace placeholders filled in.
  # The repository is cloned there.
  repo_name            = trimsuffix(basename(trimsuffix(data.coder_parameter.repository.value, "/")), ".git")
  raw_workspace_folder = { for inst in local.instance_keys : inst => coalesce(try(local.dc[inst].workspace_folder, null), "/workspaces/$${localWorkspaceFolderBasename}") }
  workspace_folder = { for inst in local.instance_keys : inst => (
    replace(replace(replace(local.raw_workspace_folder[inst],
      "$${localWorkspaceFolderBasename}", local.repo_name),
      "$${containerWorkspaceFolderBasename}", local.repo_name),
    "$${devcontainerId}", data.coder_workspace.me.id)
  ) }

  # The workspace folder gets its own directory on the PVC unless it's
  # already persisted by the /workspaces mount (at or below it) - or is the
  # home itself, which a second mount at the same path would collide with.
  workspace_folder_mounted = { for inst in local.instance_keys : inst => !(local.workspace_folder[inst] == "/workspaces" || startswith(local.workspace_folder[inst], "/workspaces/") || local.workspace_folder[inst] == local.home_dir[inst]) }

  # Mount targets may use the workspace placeholders too.
  requested_mounts = { for inst in local.instance_keys : inst => (
    [for i, m in try(local.dc[inst].mounts, []) : merge(m, {
      index = i
      target = replace(replace(replace(replace(m.target,
        "$${containerWorkspaceFolder}", local.workspace_folder[inst]),
        "$${localWorkspaceFolder}", local.workspace_folder[inst]),
        "$${containerWorkspaceFolderBasename}", basename(local.workspace_folder[inst])),
      "$${localWorkspaceFolderBasename}", basename(local.workspace_folder[inst]))
    })]
  ) }
  # A pod with two volume mounts at the same path is rejected, so a mount
  # whose target is one of the template's own mount points (or an earlier
  # mount's target) is dropped, with a warning. Compared without a
  # trailing slash.
  reserved_mount_paths = { for inst in local.instance_keys : inst => compact(["/workspaces", local.home_dir[inst], "/dev/shm", local.workspace_folder_mounted[inst] ? local.workspace_folder[inst] : ""]) }
  mount_keys           = { for inst in local.instance_keys : inst => [for m in local.requested_mounts[inst] : trimsuffix(m.target, "/")] }
  mount_collides = { for inst in local.instance_keys : inst => (
    [for i, key in local.mount_keys[inst] :
      contains(local.reserved_mount_paths[inst], key) || contains(slice(local.mount_keys[inst], 0, i), key)
    ]
  ) }
  mounts           = { for inst in local.instance_keys : inst => [for i, m in local.requested_mounts[inst] : m if !local.mount_collides[inst][i]] }
  colliding_mounts = { for inst in local.instance_keys : inst => [for i, m in local.requested_mounts[inst] : m if local.mount_collides[inst][i]] }
  mount_warnings = { for inst in local.instance_keys : inst => (
    [for m in local.colliding_mounts[inst] :
      "mounts: the ${m.kind} mount at ${m.target} is not mounted - that path is already a mount point (the home, /workspaces, the workspace folder, /dev/shm or another mount)"
    ]
  ) }
  volume_mounts = { for inst in local.instance_keys : inst => [for m in local.mounts[inst] : m if m.kind == "volume"] }
  tmpfs_mounts  = { for inst in local.instance_keys : inst => [for m in local.mounts[inst] : m if m.kind == "tmpfs"] }
  # PVC directory per named volume (volumes/<source>); anonymous volumes
  # get one per position.
  volume_dirs = { for inst in local.instance_keys : inst => [for m in local.volume_mounts[inst] : "volumes/${coalesce(m.source, "anonymous-${m.index}")}"] }

  ports = { for inst in local.instance_keys : inst => try(local.dc[inst].forward_ports, []) }

  # customizations.kubernetes (ADR-0015): Kubernetes-native resources and
  # node placement, read from the image's merged configuration. That has one
  # customizations.kubernetes entry per contributor - base image, Features,
  # then devcontainer.json - merged in that order: maps per key (the later
  # entry wins), tolerations appended. Non-objects are skipped; a value
  # that isn't a string or number becomes "" (invalid, so dropped with a
  # warning below). Maps and lists of the wrong shape are skipped.
  # Nothing here fails the plan.
  dc_configuration  = { for inst in local.instance_keys : inst => try(jsondecode(local.dc[inst].configuration_json), {}) }
  k8s_entries       = { for inst in local.instance_keys : inst => try([for e in local.dc_configuration[inst].customizations.kubernetes : e if can(keys(e))], []) }
  k8s_requests_raw  = { for inst in local.instance_keys : inst => merge(concat([{}], [for e in local.k8s_entries[inst] : try({ for k, v in e.resources.requests : k => v == null ? "" : try(tostring(v), "") if can(keys(e.resources.requests)) }, {})])...) }
  k8s_limits_raw    = { for inst in local.instance_keys : inst => merge(concat([{}], [for e in local.k8s_entries[inst] : try({ for k, v in e.resources.limits : k => v == null ? "" : try(tostring(v), "") if can(keys(e.resources.limits)) }, {})])...) }
  k8s_storage_raw   = { for inst in local.instance_keys : inst => try(reverse(compact([for e in local.k8s_entries[inst] : try(tostring(e.storage), null)]))[0], null) }
  k8s_node_selector = { for inst in local.instance_keys : inst => merge(concat([{}], [for e in local.k8s_entries[inst] : try({ for k, v in e.nodeSelector : k => v == null ? "" : try(tostring(v), "") if can(keys(e.nodeSelector)) }, {})])...) }
  k8s_tolerations = { for inst in local.instance_keys : inst => (
    distinct(flatten([for e in local.k8s_entries[inst] : try([for t in e.tolerations : {
      key                = try(tostring(t.key), null)
      operator           = try(tostring(t.operator), null)
      value              = try(tostring(t.value), null)
      effect             = try(tostring(t.effect), null)
      toleration_seconds = try(tostring(t.tolerationSeconds), null)
    } if !can(keys(e.tolerations))], [])]))
  ) }

  # Kubernetes quantities ("500m", "2", "1.5", "512Mi", "4Gi", "1G", plain
  # bytes; no exponent form), parsed to numbers to compare and cap them.
  # Where the repository's own string is used, it's kept as written.
  quantity_re      = "^([0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)(Ki|Mi|Gi|Ti|Pi|Ei|m|k|M|G|T|P|E)?$"
  quantity_factors = { "" = 1, m = 0.001, k = 1e3, M = 1e6, G = 1e9, T = 1e12, P = 1e15, E = 1e18, Ki = 1024, Mi = 1048576, Gi = 1073741824, Ti = 1099511627776, Pi = 1125899906842624, Ei = 1152921504606846976 }
  # cpu, memory, ephemeral-storage, hugepages-<size>, or an extended
  # resource (<domain>/<name>, e.g. nvidia.com/gpu). Also keeps the names
  # safe to echo in the agent metadata script.
  resource_name_re = "^(cpu|memory|ephemeral-storage|hugepages-[0-9]+[KMG]i|[a-z0-9]([-a-z0-9.]*[a-z0-9])?/[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?)$"
  k8s_requests_m   = { for inst in local.instance_keys : inst => { for k, v in local.k8s_requests_raw[inst] : k => regex(local.quantity_re, v) if can(regex(local.resource_name_re, k)) && can(regex(local.quantity_re, v)) } }
  k8s_limits_m     = { for inst in local.instance_keys : inst => { for k, v in local.k8s_limits_raw[inst] : k => regex(local.quantity_re, v) if can(regex(local.resource_name_re, k)) && can(regex(local.quantity_re, v)) } }
  k8s_requests     = { for inst in local.instance_keys : inst => { for k, m in local.k8s_requests_m[inst] : k => local.k8s_requests_raw[inst][k] } }
  k8s_limits       = { for inst in local.instance_keys : inst => { for k, m in local.k8s_limits_m[inst] : k => local.k8s_limits_raw[inst][k] } }
  k8s_requests_n   = { for inst in local.instance_keys : inst => { for k, m in local.k8s_requests_m[inst] : k => tonumber(startswith(m[0], ".") ? "0${m[0]}" : m[0]) * local.quantity_factors[m[1] == null ? "" : m[1]] } }
  k8s_limits_n     = { for inst in local.instance_keys : inst => { for k, m in local.k8s_limits_m[inst] : k => tonumber(startswith(m[0], ".") ? "0${m[0]}" : m[0]) * local.quantity_factors[m[1] == null ? "" : m[1]] } }
  k8s_storage_m    = { for inst in local.instance_keys : inst => try(regex(local.quantity_re, local.k8s_storage_raw[inst]), null) }
  k8s_storage_n    = { for inst in local.instance_keys : inst => try(tonumber(startswith(local.k8s_storage_m[inst][0], ".") ? "0${local.k8s_storage_m[inst][0]}" : local.k8s_storage_m[inst][0]) * local.quantity_factors[local.k8s_storage_m[inst][1] == null ? "" : local.k8s_storage_m[inst][1]], null) }
  # Any valid request or limit makes customizations.kubernetes.resources
  # authoritative for CPU and memory: hostRequirements' cpus/memory (and
  # runArgs --cpus/--memory) are then ignored.
  k8s_resources_set = { for inst in local.instance_keys : inst => length(local.k8s_requests[inst]) + length(local.k8s_limits[inst]) > 0 }
  k8s_invalid_resources = { for inst in local.instance_keys : inst => (
    concat(
      [for k, v in local.k8s_requests_raw[inst] : "customizations.kubernetes.resources.requests: ${can(regex(local.resource_name_re, k)) ? "${k} \"${v}\" is not a Kubernetes quantity" : "\"${k}\" is not a Kubernetes resource name"} - ignored" if !contains(keys(local.k8s_requests[inst]), k)],
      [for k, v in local.k8s_limits_raw[inst] : "customizations.kubernetes.resources.limits: ${can(regex(local.resource_name_re, k)) ? "${k} \"${v}\" is not a Kubernetes quantity" : "\"${k}\" is not a Kubernetes resource name"} - ignored" if !contains(keys(local.k8s_limits[inst]), k)],
      local.k8s_storage_raw[inst] != null && local.k8s_storage_n[inst] == null ? ["customizations.kubernetes.storage \"${local.k8s_storage_raw[inst]}\" is not a Kubernetes quantity - ignored"] : [],
    )
  ) }

  # The minimums: customizations.kubernetes' requests when it sets any
  # resources, else hostRequirements (ADR-0014), which are minimums as in
  # the spec. The scheduler reserves them (requests, capped by
  # var.max_cpu/max_memory). Limits are customizations.kubernetes' own,
  # else the larger of the request and the CPU/Memory parameters, and never
  # below the request. Storage (customizations.kubernetes.storage, else
  # hostRequirements.storage) is the larger of it and the Disk parameter,
  # so the PVC never shrinks. Where the parameter wins, values stay "<n>Gi"
  # as before (no spurious diffs).
  gib           = 1073741824
  param_cpu     = tonumber(data.coder_parameter.cpu.value)
  param_memory  = tonumber(data.coder_parameter.memory.value) * local.gib
  param_disk    = tonumber(data.coder_parameter.disk_size.value) * local.gib
  hr_cpu        = { for inst in local.instance_keys : inst => try(local.host_requirements[inst].cpus, null) }
  hr_mem        = { for inst in local.instance_keys : inst => try(local.host_requirements[inst].memory_bytes, null) }
  hr_disk       = { for inst in local.instance_keys : inst => try(local.host_requirements[inst].storage_bytes, null) }
  required_cpu  = { for inst in local.instance_keys : inst => local.k8s_resources_set[inst] ? lookup(local.k8s_requests_n[inst], "cpu", null) : local.hr_cpu[inst] }
  required_mem  = { for inst in local.instance_keys : inst => local.k8s_resources_set[inst] ? lookup(local.k8s_requests_n[inst], "memory", null) : local.hr_mem[inst] }
  required_disk = { for inst in local.instance_keys : inst => local.k8s_storage_n[inst] != null ? local.k8s_storage_n[inst] : local.hr_disk[inst] }
  cpu_capped    = { for inst in local.instance_keys : inst => local.required_cpu[inst] != null && try(local.required_cpu[inst] > var.max_cpu, false) }
  mem_capped    = { for inst in local.instance_keys : inst => local.required_mem[inst] != null && try(local.required_mem[inst] > var.max_memory * local.gib, false) }
  reserved_cpu  = { for inst in local.instance_keys : inst => local.required_cpu[inst] != null ? min(local.required_cpu[inst], var.max_cpu) : null }
  reserved_mem  = { for inst in local.instance_keys : inst => local.required_mem[inst] != null ? floor(min(local.required_mem[inst], var.max_memory * local.gib)) : null }
  k8s_cpu_limit = { for inst in local.instance_keys : inst => lookup(local.k8s_limits_n[inst], "cpu", null) }
  k8s_mem_limit = { for inst in local.instance_keys : inst => lookup(local.k8s_limits_n[inst], "memory", null) }
  # Without a reservation: 250m / 512Mi, or a smaller limit the repository
  # set (a request can't exceed its limit).
  cpu_request_n    = { for inst in local.instance_keys : inst => local.reserved_cpu[inst] != null ? local.reserved_cpu[inst] : try(min(local.k8s_cpu_limit[inst], 0.25), 0.25) }
  memory_request_n = { for inst in local.instance_keys : inst => local.reserved_mem[inst] != null ? local.reserved_mem[inst] : try(min(local.k8s_mem_limit[inst], 536870912), 536870912) }
  cpu_request = { for inst in local.instance_keys : inst => (
    (
      local.reserved_cpu[inst] == null ? (try(local.k8s_cpu_limit[inst] < 0.25, false) ? lookup(local.k8s_limits[inst], "cpu", "") : "250m") :
      local.cpu_capped[inst] ? tostring(var.max_cpu) :
      local.k8s_resources_set[inst] ? lookup(local.k8s_requests[inst], "cpu", "") : tostring(local.reserved_cpu[inst])
    )
  ) }
  memory_request = { for inst in local.instance_keys : inst => (
    (
      local.reserved_mem[inst] == null ? (try(local.k8s_mem_limit[inst] < 536870912, false) ? lookup(local.k8s_limits[inst], "memory", "") : "512Mi") :
      local.mem_capped[inst] ? (local.k8s_resources_set[inst] ? "${var.max_memory}Gi" : tostring(local.reserved_mem[inst])) :
      local.k8s_resources_set[inst] ? lookup(local.k8s_requests[inst], "memory", "") : tostring(local.reserved_mem[inst])
    )
  ) }
  cpu_limit_low = { for inst in local.instance_keys : inst => try(local.k8s_cpu_limit[inst] < local.cpu_request_n[inst], false) }
  mem_limit_low = { for inst in local.instance_keys : inst => try(local.k8s_mem_limit[inst] < local.memory_request_n[inst], false) }
  cpu_limit = { for inst in local.instance_keys : inst => (
    (
      local.k8s_cpu_limit[inst] != null ? (local.cpu_limit_low[inst] ? local.cpu_request[inst] : lookup(local.k8s_limits[inst], "cpu", "")) :
      local.reserved_cpu[inst] != null && try(local.reserved_cpu[inst] > local.param_cpu, false) ? local.cpu_request[inst] : data.coder_parameter.cpu.value
    )
  ) }
  memory_limit = { for inst in local.instance_keys : inst => (
    (
      local.k8s_mem_limit[inst] != null ? (local.mem_limit_low[inst] ? local.memory_request[inst] : lookup(local.k8s_limits[inst], "memory", "")) :
      local.reserved_mem[inst] != null && try(local.reserved_mem[inst] > local.param_memory, false) ? local.memory_request[inst] : "${data.coder_parameter.memory.value}Gi"
    )
  ) }
  disk_size = { for inst in local.instance_keys : inst => local.required_disk[inst] != null && try(local.required_disk[inst] > local.param_disk, false) ? (local.k8s_storage_n[inst] != null ? local.k8s_storage_raw[inst] : tostring(floor(local.required_disk[inst]))) : "${data.coder_parameter.disk_size.value}Gi" }

  # ephemeral-storage: passed through (no template cap), limit never below
  # the request.
  ephemeral_request   = { for inst in local.instance_keys : inst => lookup(local.k8s_requests[inst], "ephemeral-storage", null) }
  ephemeral_limit_low = { for inst in local.instance_keys : inst => try(local.k8s_limits_n[inst]["ephemeral-storage"] < local.k8s_requests_n[inst]["ephemeral-storage"], false) }
  ephemeral_limit     = { for inst in local.instance_keys : inst => local.ephemeral_limit_low[inst] ? local.ephemeral_request[inst] : lookup(local.k8s_limits[inst], "ephemeral-storage", null) }
  # Extended resources (nvidia.com/gpu, ...) and hugepages can't be
  # overcommitted: Kubernetes needs request == limit, and defaults the
  # request to the limit. So they're set as limits only - the limit if
  # given, else the request.
  k8s_extended_names  = { for inst in local.instance_keys : inst => distinct([for k in concat(keys(local.k8s_requests[inst]), keys(local.k8s_limits[inst])) : k if !contains(["cpu", "memory", "ephemeral-storage"], k)]) }
  k8s_extended_limits = { for inst in local.instance_keys : inst => { for k in local.k8s_extended_names[inst] : k => lookup(local.k8s_limits[inst], k, lookup(local.k8s_requests[inst], k, null)) } }
  gpu_json            = { for inst in local.instance_keys : inst => try(local.host_requirements[inst].gpu_json, null) }
  # hostRequirements.gpu: true or {cores, memory} -> one GPU; "optional" or
  # unset -> none. customizations.kubernetes' nvidia.com/gpu wins.
  gpu_limit = { for inst in local.instance_keys : inst => local.gpu_json[inst] != null && local.gpu_json[inst] != "\"optional\"" && local.gpu_json[inst] != "false" ? { "nvidia.com/gpu" = "1" } : {} }
  pod_requests = { for inst in local.instance_keys : inst => (
    { for k, v in {
      "cpu"               = local.cpu_request[inst]
      "memory"            = local.memory_request[inst]
      "ephemeral-storage" = local.ephemeral_request[inst]
    } : k => v if v != null }
  ) }
  pod_limits = { for inst in local.instance_keys : inst => (
    { for k, v in merge({
      "cpu"               = local.cpu_limit[inst]
      "memory"            = local.memory_limit[inst]
      "ephemeral-storage" = local.ephemeral_limit[inst]
    }, local.gpu_limit[inst], local.k8s_extended_limits[inst]) : k => v if v != null }
  ) }

  resource_warnings = { for inst in local.instance_keys : inst => (
    concat(
      local.k8s_invalid_resources[inst],
      local.k8s_resources_set[inst] && (local.hr_cpu[inst] != null || local.hr_mem[inst] != null) ? [
        "hostRequirements ${join(" and ", compact([local.hr_cpu[inst] != null ? "cpus ${local.hr_cpu[inst]}" : "", local.hr_mem[inst] != null ? "memory ${format("%.1f", local.hr_mem[inst] / local.gib)} GiB" : ""]))} (or runArgs --cpus/--memory) ignored - customizations.kubernetes.resources sets the workspace's resources"
      ] : [],
      local.k8s_storage_n[inst] != null && local.hr_disk[inst] != null ? ["hostRequirements.storage ${format("%.1f", local.hr_disk[inst] / local.gib)} GiB ignored - customizations.kubernetes.storage ${local.k8s_storage_raw[inst]} sets the volume's minimum size"] : [],
      local.cpu_capped[inst] ? ["${local.k8s_resources_set[inst] ? "customizations.kubernetes.resources.requests.cpu ${lookup(local.k8s_requests[inst], "cpu", "")}" : "hostRequirements.cpus ${local.required_cpu[inst]}"} is more than this template allows (max_cpu ${var.max_cpu}) - reserving ${var.max_cpu}"] : [],
      local.mem_capped[inst] ? ["${local.k8s_resources_set[inst] ? "customizations.kubernetes.resources.requests.memory ${lookup(local.k8s_requests[inst], "memory", "")}" : "hostRequirements.memory ${format("%.1f", local.required_mem[inst] / local.gib)} GiB"} is more than this template allows (max_memory ${var.max_memory} GiB) - reserving ${var.max_memory} GiB"] : [],
      local.cpu_limit_low[inst] ? ["customizations.kubernetes.resources.limits.cpu ${lookup(local.k8s_limits[inst], "cpu", "")} is below the request ${local.cpu_request[inst]} - the limit is ${local.cpu_request[inst]}"] : [],
      local.mem_limit_low[inst] ? ["customizations.kubernetes.resources.limits.memory ${lookup(local.k8s_limits[inst], "memory", "")} is below the request ${local.memory_request[inst]} - the limit is ${local.memory_request[inst]}"] : [],
      local.ephemeral_limit_low[inst] ? ["customizations.kubernetes.resources.limits.ephemeral-storage ${lookup(local.k8s_limits[inst], "ephemeral-storage", "")} is below the request ${local.ephemeral_request[inst]} - the limit is ${local.ephemeral_request[inst]}"] : [],
      [for k in local.k8s_extended_names[inst] : "customizations.kubernetes.resources: ${k} request ${local.k8s_requests[inst][k]} differs from its limit ${local.k8s_limits[inst][k]} - Kubernetes needs them equal; using the limit" if contains(keys(local.k8s_requests[inst]), k) && contains(keys(local.k8s_limits[inst]), k) && try(local.k8s_requests_n[inst][k] != local.k8s_limits_n[inst][k], false)],
    )
  ) }

  # Node placement, only with var.allow_node_placement: the repository's
  # nodeSelector under the template's own (which always wins), and its
  # tolerations. Tolerations Kubernetes would reject are dropped.
  template_node_selector = { "kubernetes.io/arch" = local.arch }
  node_selector          = { for inst in local.instance_keys : inst => merge({ for k, v in local.k8s_node_selector[inst] : k => v if var.allow_node_placement }, local.template_node_selector) }
  toleration_valid = { for inst in local.instance_keys : inst => (
    [for t in local.k8s_tolerations[inst] :
      contains(["Equal", "Exists"], t.operator == null ? "Equal" : t.operator) &&
      contains(["", "NoSchedule", "PreferNoSchedule", "NoExecute"], t.effect == null ? "" : t.effect) &&
      ((t.key == null ? "" : t.key) != "" || t.operator == "Exists") &&
      !(t.operator == "Exists" && (t.value == null ? "" : t.value) != "") &&
      (t.toleration_seconds == null || (t.effect == "NoExecute" && can(regex("^-?[0-9]+$", t.toleration_seconds))))
    ]
  ) }
  tolerations = { for inst in local.instance_keys : inst => [for i, t in local.k8s_tolerations[inst] : t if var.allow_node_placement && local.toleration_valid[inst][i]] }
  placement_warnings = { for inst in local.instance_keys : inst => (
    concat(
      [for i, t in local.k8s_tolerations[inst] : "customizations.kubernetes.tolerations: ${jsonencode(t)} is not a valid toleration - ignored" if var.allow_node_placement && !local.toleration_valid[inst][i]],
      [for k, v in local.template_node_selector : "customizations.kubernetes.nodeSelector ${k}=${local.k8s_node_selector[inst][k]} ignored - the template sets ${k}=${v}" if var.allow_node_placement && lookup(local.k8s_node_selector[inst], k, v) != v],
      !var.allow_node_placement && length(local.k8s_node_selector[inst]) + length(local.k8s_tolerations[inst]) > 0 ? [
        "customizations.kubernetes ${join(" and ", compact([length(local.k8s_node_selector[inst]) > 0 ? "nodeSelector" : "", length(local.k8s_tolerations[inst]) > 0 ? "tolerations" : ""]))} ignored, allow_node_placement is off (a template variable)"
      ] : [],
    )
  ) }

  # What the workspace got, for the agent metadata: request / limit, and
  # where they came from.
  resources_source = { for inst in local.instance_keys : inst => (
    join(" and ", compact([
      local.k8s_resources_set[inst] || local.k8s_storage_n[inst] != null ? "customizations.kubernetes" : "",
      (!local.k8s_resources_set[inst] && (local.hr_cpu[inst] != null || local.hr_mem[inst] != null)) || (local.k8s_storage_n[inst] == null && local.hr_disk[inst] != null) ? "hostRequirements" : "",
    ]))
  ) }
  resources_summary = { for inst in local.instance_keys : inst => (
    join(" · ", concat(
      [
        "CPU ${local.cpu_request[inst]} / ${local.cpu_limit[inst]}",
        "memory ${local.memory_request[inst]} / ${local.memory_limit[inst]}",
        "disk ${local.disk_size[inst]}",
      ],
      [for k in sort(distinct(concat(keys(local.pod_requests[inst]), keys(local.pod_limits[inst])))) : "${k} ${lookup(local.pod_requests[inst], k, lookup(local.pod_limits[inst], k, ""))} / ${lookup(local.pod_limits[inst], k, "none")}" if !contains(["cpu", "memory"], k)],
      ["from ${local.resources_source[inst] != "" ? local.resources_source[inst] : "the parameters"}"],
    ))
  ) }

  # Pod Security "baseline" (the usual namespace level) only allows these
  # added capabilities; anything else (SYS_PTRACE, NET_ADMIN, ...) would get
  # the whole pod rejected, so it's only added with var.allow_privileged.
  baseline_capabilities  = ["AUDIT_WRITE", "CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "MKNOD", "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT"]
  requested_capabilities = { for inst in local.instance_keys : inst => try(local.runtime[inst].cap_add, []) }
  capabilities           = { for inst in local.instance_keys : inst => var.allow_privileged ? local.requested_capabilities[inst] : [for c in local.requested_capabilities[inst] : c if contains(local.baseline_capabilities, c)] }
  skipped_capabilities   = { for inst in local.instance_keys : inst => var.allow_privileged ? [] : [for c in local.requested_capabilities[inst] : c if !contains(local.baseline_capabilities, c)] }
  all_warnings = { for inst in local.instance_keys : inst => (
    concat(local.warnings[inst], local.resource_warnings[inst], local.placement_warnings[inst], local.mount_warnings[inst], length(local.skipped_capabilities[inst]) > 0 ? [
      "capAdd ${join(", ", local.skipped_capabilities[inst])} not added - Pod Security baseline forbids it (template variable allow_privileged enables it)"
      ] : [], local.dc[inst] != null && local.recorded_uid[inst] == null ? [
      "the image doesn't record its remote user's uid/gid (built by devcontainer-builder older than 0.3.0) - running as uid/gid 1000; bump the Rebuild parameter to rebuild it"
    ] : [])
  ) }

  # Mount points that live on the PVC (the workspace folder itself, and any
  # mount target inside /workspaces, the home or the workspace folder):
  # seed-home creates them as the remote user first, or kubelet would
  # create them root-owned and unwritable (e.g. the workspace folder, when
  # a volume is mounted at <workspace folder>/node_modules).
  mount_point_dirs = { for inst in local.instance_keys : inst => (
    compact([for t in concat([local.workspace_folder[inst]], [for m in local.mounts[inst] : m.target]) :
      startswith(t, "/workspaces/") ? "workspaces/${trimprefix(t, "/workspaces/")}" :
      startswith(t, "${local.home_dir[inst]}/") ? "home/${trimprefix(t, "${local.home_dir[inst]}/")}" :
      local.workspace_folder_mounted[inst] && startswith(t, "${local.workspace_folder[inst]}/") ? "workspace-folder/${trimprefix(t, "${local.workspace_folder[inst]}/")}" : ""
    ])
  ) }

  # localEnv variables without a default that the user must provide -
  # ignoring ones only used by mounts, which only matter for bind mounts
  # (dropped anyway: there's no host).
  # Only shell-safe names (the service only reports those, but they end up
  # in a shell script and a regex below, so it's checked here too).
  required_variables = { for inst in local.instance_keys : inst => [for v in local.variables[inst] : v.name if v.kind == "localEnv" && v.default == null && can(regex("^[A-Za-z_][A-Za-z0-9_]*$", v.name)) && length([for u in v.used_in : u if !startswith(u, "mounts")]) > 0] }
  # Names only - the checks below must never reference the parameter itself:
  # Terraform prints referenced values in a failed check's diagnostics, and
  # the parameter holds the user's tokens.
  missing_variables = { for inst in local.instance_keys : inst => nonsensitive([for name in local.required_variables[inst] : nonsensitive(name) if !can(regex("(?m)^${name}=.+", data.coder_parameter.devcontainer_variables.value))]) }
  # Not secrets, but derived from the data source (whose registry
  # credentials input is sensitive) - unmarked so the build log shows them.
  warning_lines = { for inst in local.instance_keys : inst => nonsensitive([for w in local.all_warnings[inst] : nonsensitive(w)]) }

  # Values written into the scripts below as single-quoted shell words
  # ('...' with each ' as '\''): they come from the user's parameters and
  # the repository's devcontainer.json, so they may contain anything.
  sh_workspace_folder = { for inst in local.instance_keys : inst => "'${replace(local.workspace_folder[inst], "'", "'\\''")}'" }
  sh_repository       = "'${replace(data.coder_parameter.repository.value, "'", "'\\''")}'"
  sh_branch           = "'${replace(data.coder_parameter.branch.value, "'", "'\\''")}'"
  sh_own_extension    = "'${replace(var.vscode_extension, "'", "'\\''")}'"
  # One extension ID per line.
  sh_extensions = { for inst in local.instance_keys : inst => "'${replace(join("\n", local.vscode_extensions[inst]), "'", "'\\''")}'" }

  # Where the lifecycle script records its exit status: on the pod's root
  # filesystem, which is fresh on every start (unlike the home).
  lifecycle_status_file = "/tmp/devcontainer-lifecycle.status"

  # The architecture the agent binary, the image and the node agree on.
  arch = "amd64"

  # This workspace's own image tag. Without one, the tag is sha-<commit>,
  # shared by every workspace built from the same repository and commit -
  # and deleting the image (a Rebuild, or deleting the workspace) would
  # delete it from under the others. The Rebuild value is part of it so a
  # rebuilt image never reuses a tag a node may have cached (the pod pulls
  # IfNotPresent). Lowercase, OCI tag characters only, at most 128.
  image_tag = substr(replace(lower("ws-${data.coder_workspace.me.id}-${data.coder_parameter.rebuild.value}"), "/[^a-z0-9_.-]/", "-"), 0, 128)

  # What the per-instance resources read, as local.rt[each.key].
  rt = { for inst in local.instance_keys : inst => {
    remote_user              = local.remote_user[inst]
    runtime                  = local.runtime[inst]
    uid                      = local.uid[inst]
    gid                      = local.gid[inst]
    home_dir                 = local.home_dir[inst]
    lifecycle_scripts        = local.lifecycle_scripts[inst]
    env_scripts              = local.env_scripts[inst]
    vscode_settings          = local.vscode_settings[inst]
    workspace_folder         = local.workspace_folder[inst]
    workspace_folder_mounted = local.workspace_folder_mounted[inst]
    volume_mounts            = local.volume_mounts[inst]
    tmpfs_mounts             = local.tmpfs_mounts[inst]
    volume_dirs              = local.volume_dirs[inst]
    mount_point_dirs         = local.mount_point_dirs[inst]
    ports                    = local.ports[inst]
    node_selector            = local.node_selector[inst]
    tolerations              = local.tolerations[inst]
    pod_requests             = local.pod_requests[inst]
    pod_limits               = local.pod_limits[inst]
    disk_size                = local.disk_size[inst]
    capabilities             = local.capabilities[inst]
    required_variables       = local.required_variables[inst]
    resources_summary        = local.resources_summary[inst]
    all_warnings             = local.all_warnings[inst]
    sh_workspace_folder      = local.sh_workspace_folder[inst]
    sh_extensions            = local.sh_extensions[inst]
  } }

  # For the checks below: every instance's, prefixed with its id unless
  # it's `main`.
  all_warning_lines = flatten([for inst in local.instance_keys : [
    for w in local.warning_lines[inst] : inst == "main" ? w : "${inst}: ${w}"
  ]])
  all_missing_variables = distinct(flatten(values(local.missing_variables)))

  # coder_app.forwarded_port's slots: var.max_forwarded_ports per running
  # instance, keyed "<instance>/<slot>".
  forwarded_port_slots = { for pair in setproduct(keys(local.started_instances), range(var.max_forwarded_ports)) : "${pair[0]}/${pair[1]}" => {
    instance = pair[0]
    index    = pair[1]
  } }

  # The Deployment's labels, which are also its selector and its pods'.
  deployment_labels = { for inst in local.instance_keys : inst => merge({
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}${local.k8s_suffix[inst]}"
    "app.kubernetes.io/part-of"  = "coder"
    "com.coder.resource"         = "true"
    "com.coder.workspace.id"     = data.coder_workspace.me.id
    "com.coder.workspace.name"   = data.coder_workspace.me.name
    "com.coder.user.id"          = data.coder_workspace_owner.me.id
    "com.coder.user.username"    = data.coder_workspace_owner.me.name
  }, local.k8s_instance_labels[inst]) }
}

# --- The actual build ----------------------------------------------------
# Runs once per workspace, on `coder create`/whenever the repository or
# branch parameter changes (both are immutable=true above, so in practice
# only on create - see the guide's note on why these aren't mutable).
# Everything registryAuth/gitCredentials-shaped is left to devcontainer-
# builder's own ambient server-side config by default (image_spec.registry
# unset - resolved by the service's own registry mapping rules); the
# git_credentials block below is the one optional exception, for a
# template-wide default rather than requiring registryMapping-style
# server config for git.
resource "terraform_data" "rebuild" {
  input = data.coder_parameter.rebuild.value
}

# The workspace owner's linked git account (var.external_auth_id). With
# count = 0 Coder doesn't ask for it at all.
data "coder_external_auth" "git" {
  count = var.external_auth_id != "" ? 1 : 0
  id    = var.external_auth_id
}

resource "devcontainerbuilder_build" "workspace" {
  repository = data.coder_parameter.repository.value
  branch     = data.coder_parameter.branch.value

  # The image goes to this workspace's own tag (see local.image_tag); its
  # registry and name are still resolved by devcontainer-builder.
  image_spec = {
    tag = local.image_tag
  }

  # A Rebuild bump replaces the build: the old image tag (this workspace's
  # only) is deleted first and the branch's latest commit built under the
  # new one.
  # Credentials are only needed for the build itself: a linked account's
  # token is refreshed over time, and must not replace (rebuild) the image
  # each time it changes. A Rebuild bump builds with the current one.
  lifecycle {
    replace_triggered_by = [terraform_data.rebuild]
    ignore_changes       = [git_credentials]
  }

  # Template-wide credentials win; else the owner's linked account
  # ("oauth2" as the username works for GitHub and GitLab tokens alike).
  # git_credentials is a nested-object attribute (terraform-plugin-framework),
  # not a legacy SDKv2 block - conditionally assign the object itself (or
  # null to omit), not a `dynamic` block.
  git_credentials = var.git_credentials_username != "" ? {
    username = var.git_credentials_username
    token    = var.git_credentials_token
    } : length(data.coder_external_auth.git) > 0 ? {
    username = "oauth2"
    token    = data.coder_external_auth.git[0].access_token
  } : null
}

# The built image's Dev Container metadata - GET /devcontainer on
# devcontainer-builder, read straight from the registry.
data "devcontainerbuilder_devcontainer" "workspace" {
  for_each = local.started_instances
  registry = each.value.registry
  name     = each.value.name
  tag      = each.value.tag
  platform = "linux/${local.arch}"
}

# One agent per instance. Coder names an agent after its Terraform
# resource name, not the for_each key, so this stays coder_agent.main: the
# agent is "main", as it was before instances.
resource "coder_agent" "main" {
  for_each = local.instances
  os       = "linux"
  arch     = local.arch
  # No `dir`: it's deprecated, and anything but $HOME breaks Coder Desktop
  # file sync - so terminals/SSH start in $HOME. code-server and
  # vscode_desktop open the repo.

  # The built-in VS Code Desktop button takes its folder from `dir`, so
  # without it VS Code opens in $HOME with no folder - module.vscode_desktop
  # replaces it. Unset display_apps fields keep their defaults.
  display_apps {
    vscode = false
  }

  metadata {
    display_name = "Dev Container variables"
    key          = "7_devcontainer_variables"
    script       = <<-EOT
      missing=""
      for name in ${join(" ", local.rt[each.key].required_variables)}; do
        eval "value=\$${DEVCONTAINER_LOCALENV_$name-}"
        [ -n "$value" ] || missing="$missing $name"
      done
      if [ -n "$missing" ]; then echo "unset:$missing"; else echo "all set"; fi
    EOT
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "Resources (reserved / limit)"
    key          = "9_resources"
    script       = "echo '${replace(local.rt[each.key].resources_summary, "'", "'\\''")}'"
    interval     = 3600
    timeout      = 1
  }

  metadata {
    display_name = "Dev Container warnings"
    key          = "8_devcontainer_warnings"
    script       = "echo '${length(local.rt[each.key].all_warnings) == 0 ? "none" : "${length(local.rt[each.key].all_warnings)} - see the build log"}'"
    interval     = 3600
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Data Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    script       = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval     = 60
    timeout      = 1
  }
}

# VS Code in the browser - Microsoft's own VS Code Server (vscode-web),
# not code-server, so extensions come from the Microsoft Marketplace. It
# shares ~/.vscode-server (and so the extensions/settings installed by
# devcontainer_vscode below) with VS Code Desktop. Installed under the
# persisted home.
module "vscode_web" {
  for_each       = { for inst, i in local.started_instances : inst => i if var.accept_vscode_license }
  source         = "registry.coder.com/coder/vscode-web/coder"
  version        = "1.6.2"
  agent_id       = coder_agent.main[each.key].id
  folder         = local.rt[each.key].workspace_folder
  accept_license = true
  install_prefix = "$HOME/.cache/vscode-web"
  subdomain      = var.subdomain_apps
}

# VS Code Desktop, opened on the cloned repo (in place of the agent's
# built-in button - see coder_agent.main's display_apps).
module "vscode_desktop" {
  for_each = local.started_instances
  source   = "registry.coder.com/coder/vscode-desktop/coder"
  version  = "1.3.0"
  agent_id = coder_agent.main[each.key].id
  folder   = local.rt[each.key].workspace_folder
}

# devcontainer.json's lifecycle commands, from the image's merged metadata:
# each hook is one script devcontainer-builder already rendered with the
# Dev Containers CLI's semantics (base image, then Features, then
# devcontainer.json; string/array/object forms; stop at the first failure).
# Clones the repo first (see below), then runs them in the spec's order
# from the repo folder, before login. In Dev Containers the first three run once per
# container; here every start is a fresh root filesystem, so all four run
# on every start and must be idempotent. Output is in the agent's startup
# logs. Its exit status goes to local.lifecycle_status_file (on the pod's
# own filesystem, so never left over from an earlier start), which
# postAttachCommand waits for.
resource "coder_script" "devcontainer_lifecycle" {
  for_each           = local.started_instances
  agent_id           = coder_agent.main[each.key].id
  display_name       = "Dev Container lifecycle"
  icon               = "/icon/docker.svg"
  run_on_start       = true
  start_blocks_login = true
  script             = <<-EOT
    #!/bin/sh
    set -u
    status_file='${local.lifecycle_status_file}'
    rm -f "$status_file"
    trap 'rc=$?; echo "$rc" > "$status_file.tmp" && mv -f "$status_file.tmp" "$status_file"; exit "$rc"' EXIT
    workspace_folder=${local.rt[each.key].sh_workspace_folder}
    dir="$HOME/.cache/devcontainer-lifecycle"
    mkdir -p "$dir"

    # Clone the repository into the workspace folder on first start, at
    # the commit the image was built from (on its branch), so the hooks
    # below run the scripts that image was built for. git init + fetch
    # rather than `git clone`: the folder may already hold mount points
    # (e.g. a node_modules volume). Private repos authenticate like the
    # agent: GIT_ASKPASS (Coder external auth) for HTTPS, `coder gitssh`
    # for SSH.
    #
    # A finished clone is marked with .git/devcontainer-cloned, and is never
    # touched again. A .git without the marker is either a working copy
    # (HEAD has a commit - e.g. cloned by an older template version: kept,
    # and marked) or a clone that was cut short before its checkout
    # finished (HEAD unborn: removed and retried).
    repository=${local.sh_repository}
    branch=${local.sh_branch}
    commit='${devcontainerbuilder_build.workspace.commit != null ? devcontainerbuilder_build.workspace.commit : ""}'
    git_dir="$workspace_folder/.git"
    cloned_marker="$git_dir/devcontainer-cloned"
    retry=false
    if [ -d "$git_dir" ] && [ ! -e "$cloned_marker" ]; then
      if git -C "$workspace_folder" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        touch "$cloned_marker"
      else
        echo "devcontainer: $workspace_folder has an unfinished clone, starting over"
        rm -rf "$git_dir"
        retry=true
      fi
    fi
    if [ ! -e "$git_dir" ]; then
      if ! command -v git >/dev/null 2>&1; then
        echo "devcontainer: the image has no git, so $repository can't be cloned - add the git Feature (\"ghcr.io/devcontainers/features/git:1\": {}) to devcontainer.json's features, and rebuild" >&2
        exit 1
      fi
      case "$repository" in
        ssh://* | *@*:*)
          host=$(printf '%s' "$repository" | sed -E 's#^ssh://##; s#^[^@]*@##; s#[:/].*$##')
          mkdir -p "$HOME/.ssh" && touch "$HOME/.ssh/known_hosts"
          ssh-keygen -F "$host" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 || ssh-keyscan -H -- "$host" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
          ;;
      esac
      echo "devcontainer: cloning $repository ($branch) into $workspace_folder"
      mkdir -p "$workspace_folder"
      # `init` + symbolic-ref rather than `init -b`, which needs git 2.28.
      git -C "$workspace_folder" init -q &&
        git -C "$workspace_folder" symbolic-ref HEAD "refs/heads/$branch" &&
        git -C "$workspace_folder" remote add origin "$repository" &&
        git -C "$workspace_folder" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" || {
          echo "devcontainer: cloning $repository failed" >&2
          rm -rf "$git_dir"
          exit 1
        }
      target="origin/$branch"
      if [ -n "$commit" ] && { git -C "$workspace_folder" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$workspace_folder" fetch -q origin "$commit"; }; then
        target="$commit"
      fi
      # A retry overwrites the files the interrupted checkout already
      # wrote. A first checkout doesn't: files that were already in the
      # folder and are in the way fail it (git lists them), and its .git is
      # removed, so the next start tries the same way again.
      force=""
      if [ "$retry" = true ]; then force="-f"; fi
      if ! git -C "$workspace_folder" checkout -q $force -B "$branch" "$target"; then
        echo "devcontainer: checking out $target in $workspace_folder failed" >&2
        [ "$retry" = true ] || rm -rf "$git_dir"
        exit 1
      fi
      git -C "$workspace_folder" branch -q --set-upstream-to="origin/$branch" "$branch" ||
        echo "devcontainer: couldn't set origin/$branch as $branch's upstream" >&2
      touch "$cloned_marker"
      echo "devcontainer: checked out $(git -C "$workspace_folder" rev-parse --short HEAD), the commit the image was built from"
    fi

    run_hook() {
      [ -n "$2" ] || return 0
      echo "$2" | base64 -d > "$dir/$1.sh" || return 1
      (cd "$workspace_folder" && sh "$dir/$1.sh")
    }

    # initializeCommand runs on the host before the container exists in Dev
    # Containers; here it's simply the first hook.
    run_hook initializeCommand '${base64encode(lookup(local.rt[each.key].lifecycle_scripts, "initializeCommand", ""))}' || exit $?
    run_hook onCreateCommand '${base64encode(lookup(local.rt[each.key].lifecycle_scripts, "onCreateCommand", ""))}' || exit $?
    run_hook updateContentCommand '${base64encode(lookup(local.rt[each.key].lifecycle_scripts, "updateContentCommand", ""))}' || exit $?
    run_hook postCreateCommand '${base64encode(lookup(local.rt[each.key].lifecycle_scripts, "postCreateCommand", ""))}' || exit $?
    run_hook postStartCommand '${base64encode(lookup(local.rt[each.key].lifecycle_scripts, "postStartCommand", ""))}' || exit $?
  EOT
}

# postAttachCommand runs each time a tool attaches in Dev Containers. There
# is no attach event here, so it runs once per start - without blocking
# login, after the lifecycle script above has succeeded (as in Dev
# Containers, where it follows postStartCommand). Gives up after 30 minutes.
resource "coder_script" "devcontainer_post_attach" {
  # Always present (whether it exists can't depend on the image's metadata,
  # which is unknown until the first build) - exits at once if no hook is
  # set.
  for_each           = local.started_instances
  agent_id           = coder_agent.main[each.key].id
  display_name       = "Dev Container postAttachCommand"
  icon               = "/icon/docker.svg"
  run_on_start       = true
  start_blocks_login = false
  script             = <<-EOT
    #!/bin/sh
    set -u
    hook='${base64encode(lookup(local.rt[each.key].lifecycle_scripts, "postAttachCommand", ""))}'
    [ -n "$hook" ] || exit 0
    workspace_folder=${local.rt[each.key].sh_workspace_folder}
    status_file='${local.lifecycle_status_file}'
    echo "devcontainer: waiting for the Dev Container lifecycle script before postAttachCommand"
    waited=0
    until [ -s "$status_file" ]; do
      if [ "$waited" -ge 1800 ]; then
        echo "devcontainer: the Dev Container lifecycle script hasn't finished after 30 minutes, not running postAttachCommand" >&2
        exit 1
      fi
      sleep 2
      waited=$((waited + 2))
    done
    status=$(cat "$status_file")
    if [ "$status" != 0 ]; then
      echo "devcontainer: the Dev Container lifecycle script failed (exit status $status), not running postAttachCommand" >&2
      exit 1
    fi
    script="$HOME/.cache/devcontainer-lifecycle/postAttachCommand.sh"
    mkdir -p "$(dirname "$script")"
    echo "$hook" | base64 -d > "$script"
    cd "$workspace_folder" && sh "$script"
  EOT
}

# customizations.vscode from the image's merged metadata, for VS Code
# Desktop: extensions are installed - from the Microsoft Marketplace - into
# ~/.vscode-server/extensions and settings merged into its Machine
# settings, the same folder Desktop's own remote server uses (home is
# persisted). The installer is Desktop's own server if it has connected
# before, else Microsoft's latest VS Code Server, downloaded once into
# ~/.cache - the same server Desktop downloads on first connect, used here
# only as an installer, never served. Doesn't block login: a Desktop
# window that attaches mid-install sees the rest after a reload.
resource "coder_script" "devcontainer_vscode" {
  # Always present, for the same reason - exits at once if there's nothing
  # to install.
  for_each           = local.started_instances
  agent_id           = coder_agent.main[each.key].id
  display_name       = "Dev Container VS Code extensions"
  icon               = "/icon/code.svg"
  run_on_start       = true
  start_blocks_login = false
  script             = <<-EOT
    #!/bin/sh
    set -u
    extensions=${local.rt[each.key].sh_extensions}
    settings_b64='${base64encode(local.rt[each.key].vscode_settings)}'
    own_extension=${local.sh_own_extension}
    data_dir="$HOME/.vscode-server"
    if [ -z "$extensions" ] && [ "$settings_b64" = "${base64encode("{}")}" ] && [ -z "$own_extension" ]; then
      exit 0
    fi

    server=$(ls -td "$data_dir"/cli/servers/Stable-*/server 2>/dev/null | head -n 1)
    if [ -z "$server" ] || [ ! -x "$server/bin/code-server" ]; then
      server="$HOME/.cache/vscode-server-installer"
      if [ ! -x "$server/bin/code-server" ]; then
        case "$(uname -m)" in
          x86_64) arch=x64 ;;
          aarch64 | arm64) arch=arm64 ;;
          *) echo "devcontainer: no VS Code Server for $(uname -m), skipping extensions" >&2; exit 0 ;;
        esac
        url="https://update.code.visualstudio.com/latest/server-linux-$arch/stable"
        rm -rf "$server" && mkdir -p "$server"
        if command -v curl >/dev/null 2>&1; then fetch="curl -fsSL"; else fetch="wget -qO-"; fi
        if ! $fetch "$url" | tar -xz -C "$server" --strip-components 1; then
          echo "devcontainer: could not download VS Code Server, skipping extensions" >&2
          rm -rf "$server"
          exit 0
        fi
      fi
    fi

    # devcontainer-builder's own extension (vscode-extension/), always the
    # latest (--force updates it). It was
    # deepspacecartel.devcontainer-builder-rebuild before 0.5.0 - removed,
    # or both would run.
    "$server/bin/code-server" --extensions-dir "$data_dir/extensions" --uninstall-extension deepspacecartel.devcontainer-builder-rebuild >/dev/null 2>&1 || true
    case "$own_extension" in
      "") ;;
      http://* | https://*)
        vsix="$HOME/.cache/devcontainer-builder.vsix"
        if command -v curl >/dev/null 2>&1; then download="curl -fsSL -o"; else download="wget -qO"; fi
        if $download "$vsix.tmp" "$own_extension" && mv "$vsix.tmp" "$vsix"; then
          own_extension="$vsix"
        else
          rm -f "$vsix.tmp"
          echo "devcontainer: could not download $own_extension" >&2
          own_extension=""
        fi
        ;;
    esac
    if [ -n "$own_extension" ]; then
      out=$("$server/bin/code-server" --extensions-dir "$data_dir/extensions" --install-extension "$own_extension" --force 2>&1)
      case "$out" in
        *"Failed Installing"* | *"not found"*) echo "devcontainer: could not install $own_extension: $out" >&2 ;;
        *) echo "devcontainer: $own_extension ready" ;;
      esac
    fi

    printf '%s\n' "$extensions" | while IFS= read -r extension; do
      [ -n "$extension" ] || continue
      out=$("$server/bin/code-server" --extensions-dir "$data_dir/extensions" --install-extension "$extension" 2>&1)
      case "$out" in
        *"Failed Installing"* | *"not found"*) echo "devcontainer: could not install $extension: $out" >&2 ;;
        *) echo "devcontainer: $extension ready" ;;
      esac
    done

    # The repository's settings are defaults: a setting is written only if
    # the Machine settings don't have it yet, or still have the value this
    # script wrote last time (recorded in devcontainer-vscode-settings.applied.json)
    # - so a repository's change reaches settings the user hasn't changed,
    # and the user's own values are never overwritten.
    if [ "$settings_b64" != "${base64encode("{}")}" ]; then
      mkdir -p "$data_dir/data/Machine"
      echo "$settings_b64" | base64 -d > "$HOME/.cache/devcontainer-vscode-settings.json"
      "$server/node" -e '
        const fs = require("fs");
        const [target, incoming, appliedFile] = process.argv.slice(1);
        const read = (file) => fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
        const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
        const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
        let current;
        try { current = read(target); }
        catch (e) { console.error("devcontainer: " + target + " is not plain JSON, leaving it unchanged"); process.exit(0); }
        let applied = {};
        try { applied = read(appliedFile); } catch (e) {}
        const repository = read(incoming);
        const written = [];
        for (const [key, value] of Object.entries(repository)) {
          const isDefault = !has(current, key) || (has(applied, key) && same(current[key], applied[key]));
          if (isDefault && !same(current[key], value)) { current[key] = value; written.push(key); }
        }
        if (written.length > 0) fs.writeFileSync(target, JSON.stringify(current, null, 2) + require("os").EOL);
        const nowApplied = {};
        for (const [key, value] of Object.entries(repository)) if (same(current[key], value)) nowApplied[key] = value;
        fs.writeFileSync(appliedFile, JSON.stringify(nowApplied, null, 2) + require("os").EOL);
        console.log("devcontainer: VS Code settings in " + target + ": " + (written.length > 0 ? "set " + written.join(", ") : "nothing to change"));
      ' "$data_dir/data/Machine/settings.json" "$HOME/.cache/devcontainer-vscode-settings.json" "$HOME/.cache/devcontainer-vscode-settings.applied.json"
    fi
  EOT
}

# Everything in devcontainer.json the workspace couldn't honor, as one
# Terraform warning in the workspace's build log (full text, one per line) -
# the agent metadata above only has room for a count.
check "devcontainer_warnings" {
  assert {
    condition     = length(local.all_warning_lines) == 0
    error_message = "devcontainer.json settings this workspace doesn't honor:\n- ${join("\n- ", local.all_warning_lines)}"
  }
}

check "devcontainer_variables" {
  assert {
    condition     = length(local.all_missing_variables) == 0
    error_message = "devcontainer.json uses $${localEnv:...} variables without a value: ${join(", ", local.all_missing_variables)}. Add NAME=value lines to the workspace's \"Dev Container variables\" setting and restart."
  }
}

# devcontainer.json's forwardPorts as dashboard apps. Coder needs a fixed
# number of apps at plan time, so there are var.max_forwarded_ports slots
# per instance; the ones without a port are hidden. Slugs are unique per
# workspace, across agents: `main`'s are port-<n>, any other instance's
# <id>-port-<n>.
resource "coder_app" "forwarded_port" {
  for_each     = local.forwarded_port_slots
  agent_id     = coder_agent.main[each.value.instance].id
  slug         = "${each.value.instance == "main" ? "" : "${each.value.instance}-"}port-${each.value.index}"
  display_name = each.value.index < length(local.rt[each.value.instance].ports) ? coalesce(try(local.rt[each.value.instance].ports[each.value.index].label, null), "Port ${try(local.rt[each.value.instance].ports[each.value.index].port, 0)}") : null
  url          = "${try(local.rt[each.value.instance].ports[each.value.index].protocol, "") == "https" ? "https" : "http"}://localhost:${try(local.rt[each.value.instance].ports[each.value.index].port, 0)}"
  icon         = each.value.index < length(local.rt[each.value.instance].ports) ? "/icon/widgets.svg" : null
  subdomain    = var.subdomain_apps
  share        = "owner"
  hidden       = each.value.index >= length(local.rt[each.value.instance].ports)
}

# For the rebuild prompt extension (see devcontainer_vscode): the commit
# the image was built from, compared with origin/<branch>, and the Rebuild
# value it increases.
resource "coder_env" "devcontainer_image_commit" {
  for_each = local.instances
  agent_id = coder_agent.main[each.key].id
  name     = "DEVCONTAINER_IMAGE_COMMIT"
  value    = devcontainerbuilder_build.workspace.commit != null ? devcontainerbuilder_build.workspace.commit : ""
}

resource "coder_env" "devcontainer_branch" {
  for_each = local.instances
  agent_id = coder_agent.main[each.key].id
  name     = "DEVCONTAINER_BRANCH"
  value    = data.coder_parameter.branch.value
}

resource "coder_env" "devcontainer_rebuild" {
  for_each = local.instances
  agent_id = coder_agent.main[each.key].id
  name     = "DEVCONTAINER_REBUILD"
  value    = data.coder_parameter.rebuild.value
}

# Commits made in the workspace are attributed to its owner.
resource "coder_env" "git_author_name" {
  for_each = local.instances
  agent_id = coder_agent.main[each.key].id
  name     = "GIT_AUTHOR_NAME"
  value    = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
}

resource "coder_env" "git_committer_name" {
  for_each = local.instances
  agent_id = coder_agent.main[each.key].id
  name     = "GIT_COMMITTER_NAME"
  value    = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
}

resource "coder_env" "git_author_email" {
  for_each = local.instances
  agent_id = coder_agent.main[each.key].id
  name     = "GIT_AUTHOR_EMAIL"
  value    = data.coder_workspace_owner.me.email
}

resource "coder_env" "git_committer_email" {
  for_each = local.instances
  agent_id = coder_agent.main[each.key].id
  name     = "GIT_COMMITTER_EMAIL"
  value    = data.coder_workspace_owner.me.email
}

# One PVC per instance, kept while the workspace is stopped.
resource "kubernetes_persistent_volume_claim_v1" "data" {
  for_each = local.instances
  metadata {
    name      = "coder-${data.coder_workspace.me.id}${local.k8s_suffix[each.key]}-data"
    namespace = var.namespace
    labels = merge({
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${data.coder_workspace.me.id}${local.k8s_suffix[each.key]}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }, local.k8s_instance_labels[each.key])
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = local.rt[each.key].disk_size
      }
    }
  }

  # The size is decided when the workspace is created. Later it would come
  # from the image (customizations.kubernetes.storage or hostRequirements)
  # while the workspace runs and from the parameter while it's stopped, so
  # changes are ignored: never shrink (or churn) the claim over that. A
  # larger storage after a rebuild doesn't grow it (not every storage class
  # can expand volumes).
  lifecycle {
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# One Deployment per running instance.
resource "kubernetes_deployment_v1" "main" {
  for_each = local.started_instances
  depends_on = [
    kubernetes_persistent_volume_claim_v1.data
  ]

  wait_for_rollout = false
  metadata {
    name      = "coder-${data.coder_workspace.me.id}${local.k8s_suffix[each.key]}"
    namespace = var.namespace
    labels    = local.deployment_labels[each.key]
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = local.deployment_labels[each.key]
    }
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = local.deployment_labels[each.key]
      }
      spec {
        # Everything runs as the remote user; fsGroup makes the PVC
        # writable for it (OnRootMismatch: only re-owned when the volume
        # root doesn't match, not on every start).
        security_context {
          run_as_user            = local.rt[each.key].uid
          run_as_group           = local.rt[each.key].gid
          fs_group               = local.rt[each.key].gid
          fs_group_change_policy = "OnRootMismatch"
        }

        # devcontainer.json's `init` / --init: the pause container becomes
        # PID 1 and reaps zombies, like Docker's tini.
        share_process_namespace = try(local.rt[each.key].runtime.init, false)
        hostname                = try(local.rt[each.key].runtime.hostname, null)

        # Only nodes of the agent's (and the image's) architecture, plus
        # customizations.kubernetes' nodeSelector with allow_node_placement.
        node_selector = local.rt[each.key].node_selector

        # customizations.kubernetes' tolerations, with allow_node_placement.
        dynamic "toleration" {
          for_each = local.rt[each.key].tolerations
          content {
            key                = toleration.value.key
            operator           = toleration.value.operator
            value              = toleration.value.value
            effect             = toleration.value.effect
            toleration_seconds = toleration.value.toleration_seconds
          }
        }

        dynamic "host_aliases" {
          for_each = try(local.rt[each.key].runtime.host_aliases, [])
          content {
            ip        = host_aliases.value.ip
            hostnames = host_aliases.value.hostnames
          }
        }

        dynamic "image_pull_secrets" {
          for_each = var.image_pull_secret_name != "" ? [1] : []
          content {
            name = var.image_pull_secret_name
          }
        }

        # Runs before "dev", with the same image and user: there, the image's
        # own home is still visible (nothing is mounted over it), and the PVC
        # is at /mnt/data. On first start only (marker file), it copies that
        # home into the PVC's home/ - so the subPath mount below doesn't hide
        # the image's dotfiles - and from then on the user's own changes win.
        # It pre-creates every subPath dir (kubelet would create them
        # root-owned).
        init_container {
          name              = "seed-home"
          image             = each.value.image
          image_pull_policy = "IfNotPresent"
          command = ["sh", "-c", <<-EOT
            set -eu
            mkdir -p /mnt/data/home /mnt/data/workspaces /mnt/data/workspace-folder
            for dir in $VOLUME_DIRS $MOUNT_POINT_DIRS; do mkdir -p "/mnt/data/$dir"; done
            # A file that can't be copied (unreadable, a socket, ...) is
            # only a warning: it mustn't keep the workspace from starting.
            # -n (don't overwrite) is in GNU, BusyBox and BSD cp, though
            # some report skipped files as a failure.
            if [ ! -e /mnt/data/home/.devcontainer-home-seeded ]; then
              if [ ! -d "$HOME_DIR" ]; then
                echo "seed-home: $HOME_DIR isn't in the image, starting with an empty home"
              elif cp -R -p -n "$HOME_DIR"/. /mnt/data/home/; then
                echo "seed-home: seeded /mnt/data/home from $HOME_DIR"
              else
                echo "seed-home: warning: some of $HOME_DIR couldn't be copied (see above); seeded the rest"
              fi
              touch /mnt/data/home/.devcontainer-home-seeded
            fi
          EOT
          ]
          env {
            name  = "HOME_DIR"
            value = local.rt[each.key].home_dir
          }
          env {
            name  = "VOLUME_DIRS"
            value = join(" ", local.rt[each.key].volume_dirs)
          }
          env {
            name  = "MOUNT_POINT_DIRS"
            value = join(" ", local.rt[each.key].mount_point_dirs)
          }
          resources {
            requests = {
              "cpu"    = "50m"
              "memory" = "64Mi"
            }
            limits = {
              "cpu"    = "500m"
              "memory" = "256Mi"
            }
          }
          volume_mount {
            mount_path = "/mnt/data"
            name       = "data"
          }
        }

        container {
          name = "dev"
          # The one real change from the upstream coder/kubernetes template
          # - a fixed/parameterized `image` variable becomes the real,
          # pushed image this workspace's own devcontainerbuilder_build
          # resource just built.
          image             = each.value.image
          image_pull_policy = "IfNotPresent"
          # Sets the Dev Container environment (workspace variables, the
          # user's Dev Container variables, then containerEnv and remoteEnv -
          # so `$${PATH}:/x` expands against the image's real PATH), then
          # runs the agent. Everything the agent starts - terminals, IDEs,
          # the lifecycle scripts - inherits that environment.
          command = ["sh", "-c", <<-EOT
            set -eu
            export DEVCONTAINER_WORKSPACE_FOLDER="$DC_WORKSPACE_FOLDER"
            export DEVCONTAINER_WORKSPACE_FOLDER_BASENAME="$(basename "$DC_WORKSPACE_FOLDER")"
            export DEVCONTAINER_ID="$DC_ID"
            while IFS= read -r line || [ -n "$line" ]; do
              case "$line" in '' | '#'*) continue ;; esac
              key="$${line%%=*}"
              case "$key" in '' | *[!A-Za-z0-9_]*) echo "workspace: ignoring Dev Container variable line '$key'" >&2; continue ;; esac
              export "DEVCONTAINER_LOCALENV_$key=$${line#*=}"
            done <<EOF_VARIABLES
            $DC_VARIABLES
            EOF_VARIABLES
            # An unset variable (e.g. a Dev Container variable the user hasn't
            # provided yet) expands to empty, as with the Dev Containers CLI -
            # so no `set -u` while these run.
            set +u
            for script in "$DC_CONTAINER_ENV" "$DC_REMOTE_ENV"; do
              [ -n "$script" ] || continue
              printf '%s' "$script" | base64 -d > /tmp/devcontainer-env.sh
              . /tmp/devcontainer-env.sh
            done
            set -u
            rm -f /tmp/devcontainer-env.sh
            export HOME="$DC_HOME" USER="$DC_REMOTE_USER" LOGNAME="$DC_REMOTE_USER"
            init="$DC_INIT_SCRIPT"
            unset DC_WORKSPACE_FOLDER DC_ID DC_VARIABLES DC_CONTAINER_ENV DC_REMOTE_ENV DC_REMOTE_USER DC_INIT_SCRIPT DC_HOME
            exec sh -c "$init"
          EOT
          ]
          security_context {
            privileged = var.allow_privileged && try(local.rt[each.key].runtime.privileged, false)
            capabilities {
              add = local.rt[each.key].capabilities
            }
            dynamic "seccomp_profile" {
              for_each = var.allow_privileged && try(local.rt[each.key].runtime.seccomp_unconfined, false) ? [1] : []
              content {
                type = "Unconfined"
              }
            }
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main[each.key].token
          }
          env {
            name  = "DC_INIT_SCRIPT"
            value = coder_agent.main[each.key].init_script
          }
          env {
            name  = "DC_REMOTE_USER"
            value = local.rt[each.key].remote_user
          }
          env {
            name  = "DC_HOME"
            value = local.rt[each.key].home_dir
          }
          env {
            name  = "DC_WORKSPACE_FOLDER"
            value = local.rt[each.key].workspace_folder
          }
          env {
            name  = "DC_ID"
            value = data.coder_workspace.me.id
          }
          env {
            name  = "DC_VARIABLES"
            value = data.coder_parameter.devcontainer_variables.value
          }
          env {
            name  = "DC_CONTAINER_ENV"
            value = base64encode(lookup(local.rt[each.key].env_scripts, "containerEnv", ""))
          }
          env {
            name  = "DC_REMOTE_ENV"
            value = base64encode(lookup(local.rt[each.key].env_scripts, "remoteEnv", ""))
          }
          resources {
            requests = local.rt[each.key].pod_requests
            limits   = local.rt[each.key].pod_limits
          }
          volume_mount {
            mount_path = local.rt[each.key].home_dir
            name       = "data"
            sub_path   = "home"
            read_only  = false
          }
          volume_mount {
            mount_path = "/workspaces"
            name       = "data"
            sub_path   = "workspaces"
            read_only  = false
          }
          # A workspaceFolder outside /workspaces (and not the home itself)
          # gets its own directory on the PVC; otherwise this mount points at
          # an unused path.
          volume_mount {
            mount_path = local.rt[each.key].workspace_folder_mounted ? local.rt[each.key].workspace_folder : "/mnt/.devcontainer-unused-workspace-folder"
            name       = "data"
            sub_path   = "workspace-folder"
            read_only  = false
          }
          # devcontainer.json's volume mounts, persisted on the PVC.
          dynamic "volume_mount" {
            for_each = local.rt[each.key].volume_mounts
            content {
              mount_path = volume_mount.value.target
              name       = "data"
              sub_path   = "volumes/${coalesce(volume_mount.value.source, "anonymous-${volume_mount.value.index}")}"
              read_only  = volume_mount.value.read_only
            }
          }
          dynamic "volume_mount" {
            for_each = local.rt[each.key].tmpfs_mounts
            content {
              mount_path = volume_mount.value.target
              name       = "tmpfs-${volume_mount.value.index}"
            }
          }
          volume_mount {
            mount_path = "/dev/shm"
            name       = "dshm"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.data[each.key].metadata.0.name
            read_only  = false
          }
        }

        # /dev/shm sized from runArgs --shm-size (Docker's default is 64 MiB).
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = try(local.rt[each.key].runtime.shm_size_bytes, null) != null ? tostring(local.rt[each.key].runtime.shm_size_bytes) : "64Mi"
          }
        }

        dynamic "volume" {
          for_each = local.rt[each.key].tmpfs_mounts
          content {
            name = "tmpfs-${volume.value.index}"
            empty_dir {
              medium = "Memory"
            }
          }
        }

        affinity {
          # Spreads workspace pods evenly across nodes.
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 1
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_expressions {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["coder-workspace"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# --- Upgrading workspaces from before instances -----------------------------
# Before instances, these were single resources (or count = start_count).
# The moves keep an existing workspace's agent, PVC and Deployment as they
# are: its next build only renames them in the state. coder_app slots past
# the default max_forwarded_ports (10) aren't moved: they're recreated,
# which only re-registers the app in Coder.

moved {
  from = coder_agent.main
  to   = coder_agent.main["main"]
}

moved {
  from = module.vscode_web[0]
  to   = module.vscode_web["main"]
}

moved {
  from = module.vscode_desktop[0]
  to   = module.vscode_desktop["main"]
}

moved {
  from = coder_script.devcontainer_lifecycle[0]
  to   = coder_script.devcontainer_lifecycle["main"]
}

moved {
  from = coder_script.devcontainer_post_attach[0]
  to   = coder_script.devcontainer_post_attach["main"]
}

moved {
  from = coder_script.devcontainer_vscode[0]
  to   = coder_script.devcontainer_vscode["main"]
}

moved {
  from = coder_app.forwarded_port[0]
  to   = coder_app.forwarded_port["main/0"]
}

moved {
  from = coder_app.forwarded_port[1]
  to   = coder_app.forwarded_port["main/1"]
}

moved {
  from = coder_app.forwarded_port[2]
  to   = coder_app.forwarded_port["main/2"]
}

moved {
  from = coder_app.forwarded_port[3]
  to   = coder_app.forwarded_port["main/3"]
}

moved {
  from = coder_app.forwarded_port[4]
  to   = coder_app.forwarded_port["main/4"]
}

moved {
  from = coder_app.forwarded_port[5]
  to   = coder_app.forwarded_port["main/5"]
}

moved {
  from = coder_app.forwarded_port[6]
  to   = coder_app.forwarded_port["main/6"]
}

moved {
  from = coder_app.forwarded_port[7]
  to   = coder_app.forwarded_port["main/7"]
}

moved {
  from = coder_app.forwarded_port[8]
  to   = coder_app.forwarded_port["main/8"]
}

moved {
  from = coder_app.forwarded_port[9]
  to   = coder_app.forwarded_port["main/9"]
}

moved {
  from = coder_env.devcontainer_image_commit
  to   = coder_env.devcontainer_image_commit["main"]
}

moved {
  from = coder_env.devcontainer_branch
  to   = coder_env.devcontainer_branch["main"]
}

moved {
  from = coder_env.devcontainer_rebuild
  to   = coder_env.devcontainer_rebuild["main"]
}

moved {
  from = coder_env.git_author_name
  to   = coder_env.git_author_name["main"]
}

moved {
  from = coder_env.git_committer_name
  to   = coder_env.git_committer_name["main"]
}

moved {
  from = coder_env.git_author_email
  to   = coder_env.git_author_email["main"]
}

moved {
  from = coder_env.git_committer_email
  to   = coder_env.git_committer_email["main"]
}

moved {
  from = kubernetes_persistent_volume_claim_v1.data
  to   = kubernetes_persistent_volume_claim_v1.data["main"]
}

moved {
  from = kubernetes_deployment_v1.main[0]
  to   = kubernetes_deployment_v1.main["main"]
}
