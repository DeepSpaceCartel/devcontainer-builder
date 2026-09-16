terraform {
  # >= 1.2 for the `lifecycle.precondition` block below.
  required_version = ">= 1.2"

  required_providers {
    devcontainerbuilder = {
      source  = "deepspacecartel/devcontainer-builder"
      version = ">= 1.0"
    }
  }
}

# This module owns its own provider configuration (rather than requiring
# the caller to configure "devcontainerbuilder" itself) so the module's
# variable/output interface stays exactly what it always was - a single
# service_url in, a single image out. Reasonable here (not something every
# module should do) because this module is meant to be instantiated once
# per Workspace Template, not composed multiple times against different
# devcontainer-builder instances in the same configuration - see
# terraform-provider-devcontainer-builder's own devcontainerbuilder_build
# resource if you need that.
provider "devcontainerbuilder" {
  endpoint = var.service_url
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
  image_spec = (var.image_registry != "" || var.image_name != "" || var.image_tag != "") ? {
    registry = var.image_registry != "" ? var.image_registry : null
    name     = var.image_name != "" ? var.image_name : null
    tag      = var.image_tag != "" ? var.image_tag : null
  } : null
}

# A real resource instead of a `data "http"` source: Create only runs on
# `terraform apply`, and only when there's an actual diff to reconcile - not
# on every single `terraform plan` the way `data "http"` always did (see
# terraform-provider-devcontainer-builder's own README for the full
# rationale). Every attribute forces replacement on change - the service has
# no partial-update API, so any input change means a brand-new build.
resource "devcontainerbuilder_build" "this" {
  repository = var.repository
  branch     = var.branch

  image_spec           = local.image_spec
  git_credentials      = local.git_credentials
  registry_credentials = local.registry_credentials

  lifecycle {
    precondition {
      condition     = var.registry_username == "" || var.image_registry != ""
      error_message = "image_registry must be set when registry_username is provided (registry_credentials needs to know which registry the credentials are for)."
    }
  }
}
