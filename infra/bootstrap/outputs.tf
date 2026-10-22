output "azure_client_id" {
  description = "Client ID of the GitHub Actions Entra application."
  value       = azuread_application.github.client_id
}

output "azure_tenant_id" {
  description = "Microsoft Entra tenant ID."
  value       = data.azurerm_client_config.current.tenant_id
}

output "azure_subscription_id" {
  description = "Azure subscription ID."
  value       = data.azurerm_subscription.current.subscription_id
}

output "state_resource_group_name" {
  description = "Resource group that holds Terraform state."
  value       = azurerm_resource_group.state.name
}

output "state_storage_account_name" {
  description = "Storage account that holds Terraform state."
  value       = azurerm_storage_account.state.name
}

output "state_container_name" {
  description = "Blob container that holds Terraform state."
  value       = azurerm_storage_container.state.name
}

output "state_key" {
  description = "Blob name of the application state file."
  value       = var.state_key
}

output "github_federated_credential_subject" {
  description = "OIDC subject trusted by the federated identity credential."
  value       = azuread_application_federated_identity_credential.default_branch.subject
}

output "github_service_principal_object_id" {
  description = "Object ID of the GitHub Actions service principal."
  value       = azuread_service_principal.github.object_id
}
