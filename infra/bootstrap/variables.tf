variable "subscription_id" {
  description = "Azure subscription that hosts the Terraform state and the application."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

variable "location" {
  description = "Azure region for the state resources."
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Base prefix for resource names."
  type        = string
  default     = "bill-demo-webapp"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "github_owner" {
  description = "GitHub organization or user that owns the repository."
  type        = string
  default     = "billcurtis"
}

variable "github_repository" {
  description = "GitHub repository name (without owner)."
  type        = string
  default     = "Demo-WebApp"
}

variable "github_branch" {
  description = "Default branch whose push and workflow_dispatch runs may authenticate to Azure."
  type        = string
  default     = "main"
}

variable "github_oidc_subject_prefix" {
  description = "Repository sub-claim prefix from GET /repos/{owner}/{repo}/actions/oidc/customization/sub, e.g. repo:owner@123/name@456. Empty uses the legacy repo:owner/name form."
  type        = string
  default     = ""

  validation {
    condition     = var.github_oidc_subject_prefix == "" || startswith(var.github_oidc_subject_prefix, "repo:")
    error_message = "github_oidc_subject_prefix must start with 'repo:'."
  }
}

variable "state_key" {
  description = "Blob name for the application Terraform state."
  type        = string
  default     = "cloud-gone-wild/dev/app.tfstate"
}
