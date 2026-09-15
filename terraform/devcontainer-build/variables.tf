variable "service_url" {
  description = "Base URL of a running devcontainer-builder service, e.g. http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080 (no trailing slash)."
  type        = string
  validation {
    condition     = length(var.service_url) > 0
    error_message = "service_url must not be empty."
  }
}

variable "repository" {
  description = "Git URL of the repository containing the .devcontainer.json to build."
  type        = string
  validation {
    condition     = length(var.repository) > 0
    error_message = "repository must not be empty."
  }
}

variable "branch" {
  description = "Git branch to build from."
  type        = string
  default     = "main"
  validation {
    condition     = length(var.branch) > 0
    error_message = "branch must not be empty."
  }
}

variable "git_username" {
  description = "Username for git HTTPS authentication. Leave empty for public repositories."
  type        = string
  default     = ""
  sensitive   = true
}

variable "git_token" {
  description = "Password or token for git HTTPS authentication. Leave empty for public repositories."
  type        = string
  default     = ""
  sensitive   = true
}

variable "image_registry" {
  description = "Destination registry/namespace to push the built image to, e.g. ghcr.io/org. Leave empty to have the service resolve a registry from its repo-to-registry mapping config; the request fails if no mapping matches."
  type        = string
  default     = ""
}

variable "image_name" {
  description = "Name of the image to push, e.g. myrepo-devcontainer. Leave empty to have the service derive it from the repository path."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Tag to apply to the built image, e.g. a short git SHA. Leave empty to have the service derive it from the built commit's SHA."
  type        = string
  default     = ""
}

variable "registry_username" {
  description = "Username for registry push authentication. Leave empty to use the service's ambient/server-configured registry credentials. Requires image_registry to be set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "registry_password" {
  description = "Password or token for registry push authentication. Leave empty to use the service's ambient/server-configured registry credentials. Requires image_registry to be set."
  type        = string
  default     = ""
  sensitive   = true
}
