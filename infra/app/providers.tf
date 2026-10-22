# Authentication comes from the environment:
#   GitHub Actions: ARM_USE_OIDC, ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
#   Local:          Azure CLI login + ARM_SUBSCRIPTION_ID
provider "azurerm" {
  # Resource providers are registered once by bootstrap.ps1; the deploy identity has no register rights.
  resource_provider_registrations = "none"

  features {
    resource_group {
      # Application Insights auto-creates smart detection rules in the group that Terraform does not manage.
      prevent_deletion_if_contains_resources = false
    }
  }
}
