provider "azurerm" {
  subscription_id = var.subscription_id

  # Shared-key access is disabled on the state account, so data-plane calls must use Entra ID.
  storage_use_azuread = true

  features {}
}

provider "azuread" {}
