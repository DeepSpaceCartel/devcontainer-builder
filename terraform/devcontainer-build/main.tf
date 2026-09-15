terraform {
  # >= 1.2 for the `lifecycle.precondition` block below.
  required_version = ">= 1.2"

  required_providers {
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4"
    }
  }
}

locals {
  git_credentials = var.git_username != "" && var.git_token != "" ? {
    username = var.git_username
    token    = var.git_token
  } : null

  registry_credentials = var.registry_username != "" && var.registry_password != "" ? {
    registry = var.image_registry
    username = var.registry_username
    password = var.registry_password
  } : null

  # Omitted entirely (rather than sent as an object of empty strings) when
  # the caller supplies none of registry/name/tag, so the service can tell
  # "not provided" apart from an explicit value and apply its own defaults.
  image = (var.image_registry != "" || var.image_name != "" || var.image_tag != "") ? {
    registry = var.image_registry != "" ? var.image_registry : null
    name     = var.image_name != "" ? var.image_name : null
    tag      = var.image_tag != "" ? var.image_tag : null
  } : null
}

# Calls a running devcontainer-builder service, which clones `repository`,
# builds its devcontainer.json against a remote BuildKit builder, pushes the
# result, and returns the pushed image reference. Conceptually the same role
# as a PersistentVolumeClaim provisioned ahead of a workspace pod: a resource
# the Workspace Template depends on before the pod's image is known.
data "http" "build" {
  url    = "${var.service_url}/build"
  method = "POST"

  request_headers = {
    Content-Type = "application/json"
  }

  # gitCredentials/image/registryCredentials are omitted entirely (via
  # merge()) rather than sent as null/empty, so the service can distinguish
  # "not provided" (apply server-side defaults) from an explicit value.
  request_body = jsonencode(merge(
    {
      repository = var.repository
      branch     = var.branch
    },
    local.git_credentials != null ? { gitCredentials = local.git_credentials } : {},
    local.image != null ? { image = local.image } : {},
    local.registry_credentials != null ? { registryCredentials = local.registry_credentials } : {},
  ))

  lifecycle {
    precondition {
      condition     = var.registry_username == "" || var.image_registry != ""
      error_message = "image_registry must be set when registry_username is provided (registry_credentials needs to know which registry the credentials are for)."
    }
  }
}

locals {
  build_response = jsondecode(data.http.build.response_body)
}
