variable "location" {
  description = "Azure region for the application."
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

variable "repository" {
  description = "Source repository, used for tagging."
  type        = string
  default     = "billcurtis/Demo-WebApp"
}

variable "app_service_sku" {
  description = "App Service plan SKU. B1 is the smallest tier that supports Always On."
  type        = string
  default     = "B1"
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}
