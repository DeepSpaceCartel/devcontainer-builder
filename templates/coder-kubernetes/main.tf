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
# Persistence: one PVC per workspace (coder-<id>-data), mounted twice via
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
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    devcontainerbuilder = {
      source = "deepspacecartel/devcontainer-builder"
      # >= 0.2.0 for the devcontainerbuilder_devcontainer data source (and
      # devcontainer-builder service >= 0.2.0 behind it).
      version = ">= 0.2.0"
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
  description  = "A git repository containing a .devcontainer.json (or .devcontainer/devcontainer.json) at its root. https://, ssh://, or SCP-style (git@host:path) all work."
  icon         = "/icon/git.svg"
  mutable      = false
}

data "coder_parameter" "branch" {
  name         = "branch"
  display_name = "Branch"
  description  = "Branch to build."
  default      = "main"
  icon         = "/icon/git.svg"
  mutable      = false
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
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
  description  = "The amount of memory in GB"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 GB"
    value = "2"
  }
  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "6 GB"
    value = "6"
  }
  option {
    name  = "8 GB"
    value = "8"
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Disk size"
  description  = "The size of the persistent disk (home + /workspaces) in GB"
  default      = "10"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 1
    max = 99999
  }
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
  # Only read while the workspace is starting (count = start_count below),
  # so stopping a workspace never depends on devcontainer-builder being up.
  dc = one(data.devcontainerbuilder_devcontainer.workspace[*])

  # The image's remoteUser (falling back to containerUser): whose home is
  # persisted. Pods still run as uid 1000 - seed-home fails with a clear
  # message if this user isn't uid 1000 in the image.
  remote_user = try(coalesce(local.dc.remote_user, local.dc.container_user), "root")
  home_dir    = local.remote_user == "root" ? "/root" : "/home/${local.remote_user}"

  lifecycle_scripts = try(local.dc.lifecycle_scripts, {})
  vscode_extensions = try(local.dc.extensions, [])
  vscode_settings   = try(local.dc.settings_json, "{}")

  # Dev Containers' "Clone Repository in Container Volume" convention:
  # /workspaces/<repo name>, on the PVC. Passed to git-clone as folder_name
  # explicitly so this is known even when the module has count = 0.
  repo_name        = trimsuffix(basename(trimsuffix(data.coder_parameter.repository.value, "/")), ".git")
  workspace_folder = "/workspaces/${local.repo_name}" # never in the image's metadata label
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
resource "devcontainerbuilder_build" "workspace" {
  repository = data.coder_parameter.repository.value
  branch     = data.coder_parameter.branch.value

  # git_credentials is a nested-object attribute (terraform-plugin-framework),
  # not a legacy SDKv2 block - conditionally assign the object itself (or
  # null to omit), not a `dynamic` block.
  git_credentials = var.git_credentials_username != "" ? {
    username = var.git_credentials_username
    token    = var.git_credentials_token
  } : null
}

# The built image's Dev Container metadata - GET /devcontainer on
# devcontainer-builder, read straight from the registry.
data "devcontainerbuilder_devcontainer" "workspace" {
  count    = data.coder_workspace.me.start_count
  registry = devcontainerbuilder_build.workspace.resolved_registry
  name     = devcontainerbuilder_build.workspace.resolved_name
  tag      = devcontainerbuilder_build.workspace.resolved_tag
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
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

# Clones the repository into /workspaces/<repo name> on first start, before
# login (start_blocks_login). It only clones into an empty folder, so the
# working copy on the PVC - local edits, other branches - is never touched
# on later starts. Private repos authenticate the way the agent does: a
# Coder external auth provider for HTTPS (GIT_ASKPASS), or the owner's
# Coder SSH key (`coder gitssh`) for ssh/scp-style URLs. Clones the branch
# tip; checking out the commit the image was built from is F1.
module "git_clone" {
  count       = data.coder_workspace.me.start_count
  source      = "registry.coder.com/coder/git-clone/coder"
  version     = "2.0.5"
  agent_id    = coder_agent.main.id
  url         = data.coder_parameter.repository.value
  branch_name = data.coder_parameter.branch.value
  base_dir    = "/workspaces"
  folder_name = local.repo_name
}

# code-server, opened on the cloned repo. Installed under the persisted
# home, so a restart finds it (and its download cache) already there.
module "code_server" {
  count          = data.coder_workspace.me.start_count
  source         = "registry.coder.com/coder/code-server/coder"
  version        = "1.6.0"
  agent_id       = coder_agent.main.id
  folder         = local.workspace_folder
  install_prefix = "$HOME/.cache/code-server"
}

# VS Code Desktop, opened on the cloned repo (in place of the agent's
# built-in button - see coder_agent.main's display_apps).
module "vscode_desktop" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/vscode-desktop/coder"
  version  = "1.3.0"
  agent_id = coder_agent.main.id
  folder   = local.workspace_folder
}

# devcontainer.json's lifecycle commands, from the image's merged metadata:
# each hook is one script devcontainer-builder already rendered with the
# Dev Containers CLI's semantics (base image, then Features, then
# devcontainer.json; string/array/object forms; stop at the first failure).
# Runs them in the spec's order from the repo folder, after git_clone has
# cloned it, before login. In Dev Containers the first three run once per
# container; here every start is a fresh root filesystem, so all four run
# on every start and must be idempotent. Output is in the agent's startup
# logs.
resource "coder_script" "devcontainer_lifecycle" {
  count              = data.coder_workspace.me.start_count
  agent_id           = coder_agent.main.id
  display_name       = "Dev Container lifecycle"
  icon               = "/icon/docker.svg"
  run_on_start       = true
  start_blocks_login = true
  script             = <<-EOT
    #!/bin/sh
    set -u
    workspace_folder='${local.workspace_folder}'
    dir="$HOME/.cache/devcontainer-lifecycle"
    mkdir -p "$dir"

    # git_clone runs alongside this script; the hooks need the working copy.
    i=0
    until [ -d "$workspace_folder/.git" ]; do
      i=$((i + 1))
      if [ "$i" -gt 300 ]; then
        echo "devcontainer: $workspace_folder was not cloned within 10 minutes, skipping lifecycle commands" >&2
        exit 1
      fi
      sleep 2
    done

    run_hook() {
      [ -n "$2" ] || return 0
      echo "$2" | base64 -d > "$dir/$1.sh" || return 1
      (cd "$workspace_folder" && sh "$dir/$1.sh")
    }

    run_hook onCreateCommand '${base64encode(lookup(local.lifecycle_scripts, "onCreateCommand", ""))}' || exit $?
    run_hook updateContentCommand '${base64encode(lookup(local.lifecycle_scripts, "updateContentCommand", ""))}' || exit $?
    run_hook postCreateCommand '${base64encode(lookup(local.lifecycle_scripts, "postCreateCommand", ""))}' || exit $?
    run_hook postStartCommand '${base64encode(lookup(local.lifecycle_scripts, "postStartCommand", ""))}' || exit $?
  EOT
}

# postAttachCommand runs each time a tool attaches in Dev Containers. There
# is no attach event here, so it runs once per start - without blocking
# login, after the clone.
resource "coder_script" "devcontainer_post_attach" {
  count              = lookup(local.lifecycle_scripts, "postAttachCommand", "") != "" ? data.coder_workspace.me.start_count : 0
  agent_id           = coder_agent.main.id
  display_name       = "Dev Container postAttachCommand"
  icon               = "/icon/docker.svg"
  run_on_start       = true
  start_blocks_login = false
  script             = <<-EOT
    #!/bin/sh
    set -u
    workspace_folder='${local.workspace_folder}'
    until [ -d "$workspace_folder/.git" ]; do sleep 2; done
    script="$HOME/.cache/devcontainer-lifecycle/postAttachCommand.sh"
    mkdir -p "$(dirname "$script")"
    echo '${base64encode(lookup(local.lifecycle_scripts, "postAttachCommand", ""))}' | base64 -d > "$script"
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
  count              = length(local.vscode_extensions) > 0 || local.vscode_settings != "{}" ? data.coder_workspace.me.start_count : 0
  agent_id           = coder_agent.main.id
  display_name       = "Dev Container VS Code extensions"
  icon               = "/icon/code.svg"
  run_on_start       = true
  start_blocks_login = false
  script             = <<-EOT
    #!/bin/sh
    set -u
    extensions='${join(" ", local.vscode_extensions)}'
    settings_b64='${base64encode(local.vscode_settings)}'
    data_dir="$HOME/.vscode-server"

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

    for extension in $extensions; do
      out=$("$server/bin/code-server" --extensions-dir "$data_dir/extensions" --install-extension "$extension" 2>&1)
      case "$out" in
        *"Failed Installing"* | *"not found"*) echo "devcontainer: could not install $extension: $out" >&2 ;;
        *) echo "devcontainer: $extension ready" ;;
      esac
    done

    if [ "$settings_b64" != "${base64encode("{}")}" ]; then
      mkdir -p "$data_dir/data/Machine"
      echo "$settings_b64" | base64 -d > "$HOME/.cache/devcontainer-vscode-settings.json"
      "$server/node" -e '
        const fs = require("fs");
        const [target, incoming] = process.argv.slice(1);
        let current = {};
        if (fs.existsSync(target)) {
          try { current = JSON.parse(fs.readFileSync(target, "utf8")); }
          catch (e) { console.error("devcontainer: " + target + " is not plain JSON, leaving it unchanged"); process.exit(0); }
        }
        fs.writeFileSync(target, JSON.stringify(Object.assign(current, JSON.parse(fs.readFileSync(incoming, "utf8"))), null, 2) + require("os").EOL);
        console.log("devcontainer: merged VS Code settings into " + target);
      ' "$data_dir/data/Machine/settings.json" "$HOME/.cache/devcontainer-vscode-settings.json"
    fi
  EOT
}

# Commits made in the workspace are attributed to its owner.
resource "coder_env" "git_author_name" {
  agent_id = coder_agent.main.id
  name     = "GIT_AUTHOR_NAME"
  value    = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
}

resource "coder_env" "git_committer_name" {
  agent_id = coder_agent.main.id
  name     = "GIT_COMMITTER_NAME"
  value    = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
}

resource "coder_env" "git_author_email" {
  agent_id = coder_agent.main.id
  name     = "GIT_AUTHOR_EMAIL"
  value    = data.coder_workspace_owner.me.email
}

resource "coder_env" "git_committer_email" {
  agent_id = coder_agent.main.id
  name     = "GIT_COMMITTER_EMAIL"
  value    = data.coder_workspace_owner.me.email
}

resource "kubernetes_persistent_volume_claim_v1" "data" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-data"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${data.coder_parameter.disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim_v1.data
  ]
  wait_for_rollout = false
  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "coder-workspace"
        "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
        "app.kubernetes.io/part-of"  = "coder"
        "com.coder.resource"         = "true"
        "com.coder.workspace.id"     = data.coder_workspace.me.id
        "com.coder.workspace.name"   = data.coder_workspace.me.name
        "com.coder.user.id"          = data.coder_workspace_owner.me.id
        "com.coder.user.username"    = data.coder_workspace_owner.me.name
      }
    }
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "coder-workspace"
          "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
          "app.kubernetes.io/part-of"  = "coder"
          "com.coder.resource"         = "true"
          "com.coder.workspace.id"     = data.coder_workspace.me.id
          "com.coder.workspace.name"   = data.coder_workspace.me.name
          "com.coder.user.id"          = data.coder_workspace_owner.me.id
          "com.coder.user.username"    = data.coder_workspace_owner.me.name
        }
      }
      spec {
        security_context {
          run_as_user     = 1000
          fs_group        = 1000
          run_as_non_root = true
        }

        dynamic "image_pull_secrets" {
          for_each = var.image_pull_secret_name != "" ? [1] : []
          content {
            name = var.image_pull_secret_name
          }
        }

        # Runs before "dev", with the same image: there, the image's own home
        # is still visible (nothing is mounted over it), and the PVC is at
        # /mnt/data. On first start only (marker file), it copies that home
        # into the PVC's home/ - so the subPath mount below doesn't hide the
        # image's dotfiles - and from then on the user's own changes win.
        # It also pre-creates both subPath dirs, since kubelet would create
        # them root-owned and unwritable for uid 1000.
        init_container {
          name              = "seed-home"
          image             = devcontainerbuilder_build.workspace.image
          image_pull_policy = "IfNotPresent"
          command = ["sh", "-c", <<-EOT
            set -eu
            entry=$(getent passwd "$REMOTE_USER" || true)
            if [ -z "$entry" ]; then
              echo "seed-home: user '$REMOTE_USER' (the image's remoteUser) does not exist in this image" >&2
              exit 1
            fi
            uid=$(echo "$entry" | cut -d: -f3)
            home=$(echo "$entry" | cut -d: -f6)
            if [ "$home" != "$HOME_DIR" ]; then
              echo "seed-home: '$REMOTE_USER' has home $home in this image, but the template mounts $HOME_DIR" >&2
              exit 1
            fi
            if [ "$uid" != "1000" ]; then
              echo "seed-home: '$REMOTE_USER' (the image's remoteUser) has uid $uid in this image, but workspace pods run as uid 1000" >&2
              exit 1
            fi
            mkdir -p /mnt/data/home /mnt/data/workspaces
            if [ ! -e /mnt/data/home/.devcontainer-home-seeded ]; then
              cp -R --preserve=mode,timestamps,links --no-clobber "$HOME_DIR"/. /mnt/data/home/
              touch /mnt/data/home/.devcontainer-home-seeded
              echo "seed-home: seeded /mnt/data/home from $HOME_DIR"
            fi
          EOT
          ]
          security_context {
            run_as_user = "1000"
          }
          env {
            name  = "REMOTE_USER"
            value = local.remote_user
          }
          env {
            name  = "HOME_DIR"
            value = local.home_dir
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
          image             = devcontainerbuilder_build.workspace.image
          image_pull_policy = "IfNotPresent"
          command           = ["sh", "-c", coder_agent.main.init_script]
          security_context {
            run_as_user = "1000"
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          resources {
            requests = {
              "cpu"    = "250m"
              "memory" = "512Mi"
            }
            limits = {
              "cpu"    = "${data.coder_parameter.cpu.value}"
              "memory" = "${data.coder_parameter.memory.value}Gi"
            }
          }
          volume_mount {
            mount_path = local.home_dir
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
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.data.metadata.0.name
            read_only  = false
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
