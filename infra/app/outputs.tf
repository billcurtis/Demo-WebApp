output "resource_group_name" {
  description = "Application resource group."
  value       = azurerm_resource_group.app.name
}

output "app_service_plan_name" {
  description = "App Service plan name."
  value       = azurerm_service_plan.app.name
}

output "website_name" {
  description = "App Service web app name."
  value       = azurerm_linux_web_app.app.name
}

output "website_hostname" {
  description = "Default hostname of the web app."
  value       = azurerm_linux_web_app.app.default_hostname
}

output "website_url" {
  description = "Public HTTPS address of the website."
  value       = "https://${azurerm_linux_web_app.app.default_hostname}"
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace name."
  value       = azurerm_log_analytics_workspace.app.name
}

output "application_insights_name" {
  description = "Application Insights name."
  value       = azurerm_application_insights.app.name
}

output "web_app_principal_id" {
  description = "Principal ID of the web app's system-assigned managed identity."
  value       = azurerm_linux_web_app.app.identity[0].principal_id
}
