# =============================================================
# Base template — copy this whole _base/ folder to start a new day:
#   Copy-Item -Recurse _base dayNN-topic-name
# Then add your exercise files (exNN-*.tf) into the new day folder.
# =============================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  subscription_id = "<your-subscription-id>"
  features {}
}
