# This module now wraps devcontainerbuilder_build (a real resource) instead
# of `data "http"`, which was the whole point of the rewrite (see
# terraform-provider-devcontainer-builder's own README): a resource's Create
# only runs on `terraform apply`, and only for a real diff - not on every
# single `terraform plan`. That makes real contract testing possible without
# a live service for the first time, via `mock_provider` (Terraform test
# mocking, stable since Terraform 1.8) - no more "left as follow-up".

variables {
  service_url    = "http://devcontainer-builder.example.svc.cluster.local:8080"
  repository     = "https://github.com/example/example-devcontainer.git"
  branch         = "main"
  image_registry = "ghcr.io/example"
  image_name     = "example-devcontainer"
  image_tag      = "sha-abc1234"
}

run "rejects_empty_repository" {
  command = plan

  variables {
    repository = ""
  }

  expect_failures = [
    var.repository,
  ]
}

run "rejects_empty_service_url" {
  command = plan

  variables {
    service_url = ""
  }

  expect_failures = [
    var.service_url,
  ]
}

run "rejects_registry_credentials_without_registry" {
  command = plan

  variables {
    image_registry    = ""
    image_name        = ""
    image_tag         = ""
    registry_username = "svc-bot"
    registry_password = "hunter2"
  }

  expect_failures = [
    devcontainerbuilder_build.this,
  ]
}

mock_provider "devcontainerbuilder" {
  mock_resource "devcontainerbuilder_build" {
    defaults = {
      id                = "ghcr.io/example/example-devcontainer:sha-abc1234"
      image             = "ghcr.io/example/example-devcontainer:sha-abc1234"
      resolved_registry = "ghcr.io/example"
      resolved_name     = "example-devcontainer"
      resolved_tag      = "sha-abc1234"
    }
  }
}

run "resolves_image_output_from_the_build_resource" {
  command = apply

  providers = {
    devcontainerbuilder = devcontainerbuilder
  }

  assert {
    condition     = output.image == "ghcr.io/example/example-devcontainer:sha-abc1234"
    error_message = "the image output did not resolve from devcontainerbuilder_build.this.image"
  }
}
