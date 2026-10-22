data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

data "azuread_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
  numeric = true
}

locals {
  base_name  = "${var.prefix}-${var.environment}"
  repository = "${var.github_owner}/${var.github_repository}"

  # Storage account names: 3-24 chars, lowercase letters and digits only.
  state_storage_account_name = substr("${replace(var.prefix, "/[^a-z0-9]/", "")}tf${random_string.suffix.result}", 0, 24)

  github_oidc_issuer  = "https://token.actions.githubusercontent.com"
  github_oidc_subject = "repo:${local.repository}:ref:refs/heads/${var.github_branch}"

  tags = {
    environment = var.environment
    application = "cloud-gone-wild"
    managed-by  = "terraform"
    repository  = local.repository
    workload    = "demo-webapp"
    purpose     = "terraform-state"
  }
}

# ---------------------------------------------------------------------------
# Remote state storage
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "state" {
  name     = "${local.base_name}-tfstate-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "state" {
  name                = local.state_storage_account_name
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  access_tier              = "Hot"

  https_traffic_only_enabled        = true
  min_tls_version                   = "TLS1_2"
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  cross_tenant_replication_enabled  = false
  infrastructure_encryption_enabled = true

  # GitHub-hosted runners need to reach the blob endpoint; access is gated by Entra ID RBAC.
  public_network_access = "Enabled"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

resource "azurerm_management_lock" "state" {
  name       = "${local.base_name}-tfstate-lock"
  scope      = azurerm_storage_account.state.id
  lock_level = "CanNotDelete"
  notes      = "Protects Terraform remote state. Remove this lock deliberately before deleting the account."
}

# ---------------------------------------------------------------------------
# GitHub Actions workload identity (OIDC, no client secret)
# ---------------------------------------------------------------------------

resource "azuread_application" "github" {
  display_name     = "${local.base_name}-github-actions"
  description      = "GitHub Actions OIDC identity for ${local.repository} (${var.environment})."
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "github" {
  client_id = azuread_application.github.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

# Used by both deploy.yml (push) and destroy.yml (workflow_dispatch) when run on the default branch.
resource "azuread_application_federated_identity_credential" "default_branch" {
  application_id = azuread_application.github.id
  display_name   = "github-${var.github_repository}-${var.github_branch}"
  description    = "Push and workflow_dispatch runs on ${local.repository}@${var.github_branch}."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.github_oidc_issuer
  subject        = local.github_oidc_subject
}

# ---------------------------------------------------------------------------
# Least-privilege authorization
# ---------------------------------------------------------------------------

# Scoped to the resource types used by infra/app. No Microsoft.Authorization (RBAC) rights.
resource "azurerm_role_definition" "deployer" {
  name        = "${local.base_name}-github-deployer"
  scope       = data.azurerm_subscription.current.id
  description = "Create, update, and destroy the Cloud Gone Wild application resources."

  permissions {
    actions = [
      "Microsoft.Resources/subscriptions/read",
      "Microsoft.Resources/subscriptions/operationresults/read",
      "Microsoft.Resources/subscriptions/resourceGroups/*",
      "Microsoft.Web/*",
      "Microsoft.OperationalInsights/*",
      "Microsoft.Insights/*",
      "Microsoft.AlertsManagement/*",
    ]
    not_actions = []
  }

  assignable_scopes = [data.azurerm_subscription.current.id]
}

resource "azurerm_role_assignment" "github_deployer" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.deployer.role_definition_resource_id
  principal_id       = azuread_service_principal.github.object_id
  principal_type     = "ServicePrincipal"
  description        = "GitHub Actions deploys Cloud Gone Wild application resources."
}

resource "azurerm_role_assignment" "github_state" {
  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.github.object_id
  principal_type       = "ServicePrincipal"
  description          = "GitHub Actions reads and writes Terraform state via Entra ID."
}

# Lets the operator who ran bootstrap initialize infra/app locally against the same backend.
resource "azurerm_role_assignment" "operator_state" {
  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Bootstrap operator access to Terraform state via Entra ID."
}
