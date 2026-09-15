output "image" {
  description = "The built and pushed container image reference, e.g. ghcr.io/org/repo-devcontainer:sha-abc1234."
  value       = devcontainerbuilder_build.this.image
}
