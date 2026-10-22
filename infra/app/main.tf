resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
  numeric = true
}

locals {
  base_name = "${var.prefix}-${var.environment}"

  names = {
    resource_group       = "${local.base_name}-rg"
    app_service_plan     = "${local.base_name}-plan"
    web_app              = "${local.base_name}-${random_string.suffix.result}"
    log_analytics        = "${local.base_name}-law"
    application_insights = "${local.base_name}-appi"
  }

  tags = {
    environment = var.environment
    application = "cloud-gone-wild"
    managed-by  = "terraform"
    repository  = var.repository
    workload    = "demo-webapp"
  }

  # App Service log categories available on the Basic tier for Linux apps.
  web_app_log_categories = [
    "AppServiceHTTPLogs",
    "AppServiceConsoleLogs",
    "AppServiceAppLogs",
    "AppServiceAuditLogs",
    "AppServiceIPSecAuditLogs",
    "AppServicePlatformLogs",
  ]
}

resource "azurerm_resource_group" "app" {
  name     = local.names.resource_group
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "app" {
  name                = local.names.log_analytics
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_application_insights" "app" {
  name                = local.names.application_insights
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  workspace_id        = azurerm_log_analytics_workspace.app.id
  application_type    = "web"
  tags                = local.tags
}

resource "azurerm_service_plan" "app" {
  name                = local.names.app_service_plan
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku
  tags                = local.tags
}

resource "azurerm_linux_web_app" "app" {
  name                = local.names.web_app
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  service_plan_id     = azurerm_service_plan.app.id

  https_only                                     = true
  public_network_access_enabled                  = true
  client_affinity_enabled                        = false
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on               = true
    ftps_state              = "Disabled"
    minimum_tls_version     = "1.2"
    scm_minimum_tls_version = "1.2"
    http2_enabled           = true
    use_32_bit_worker       = false

    # The PHP image fronts wwwroot with nginx, which serves index.html as a plain static file.
    application_stack {
      php_version = "8.4"
    }
  }

  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING      = azurerm_application_insights.app.connection_string
    ApplicationInsightsAgent_EXTENSION_VERSION = "~3"
    SCM_DO_BUILD_DURING_DEPLOYMENT             = "false"
  }

  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 3
        retention_in_mb   = 35
      }
    }
  }

  tags = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "web_app" {
  name                       = "${local.base_name}-webapp-diag"
  target_resource_id         = azurerm_linux_web_app.app.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.app.id

  dynamic "enabled_log" {
    for_each = toset(local.web_app_log_categories)
    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "service_plan" {
  name                       = "${local.base_name}-plan-diag"
  target_resource_id         = azurerm_service_plan.app.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.app.id

  enabled_metric {
    category = "AllMetrics"
  }
}
