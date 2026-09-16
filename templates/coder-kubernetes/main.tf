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

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk size"
  description  = "The size of the home disk in GB"
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

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = <<-EOT
    set -e

    # Install the latest code-server.
    # Append "--version x.x.x" to install a specific version of code-server.
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server

    # Start code-server in the background.
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &
  EOT

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
    display_name = "Home Disk"
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

resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
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
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim_v1.home
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
            mount_path = "/home/coder"
            name       = "home"
            read_only  = false
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata.0.name
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
