# Partial configuration. Values come from bootstrap outputs at init time:
#   terraform init \
#     -backend-config="resource_group_name=<TF_STATE_RESOURCE_GROUP>" \
#     -backend-config="storage_account_name=<TF_STATE_STORAGE_ACCOUNT>" \
#     -backend-config="container_name=<TF_STATE_CONTAINER>" \
#     -backend-config="key=<TF_STATE_KEY>"
terraform {
  backend "azurerm" {
    use_azuread_auth = true
  }
}
