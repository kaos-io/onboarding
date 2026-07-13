terraform {
  # 1.11+ required for write-only arguments (value_wo on azurerm_key_vault_secret).
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.23, < 5.0" # 4.23 introduced value_wo / value_wo_version
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # The org KV has purge protection ON; never attempt purge on destroy.
      purge_soft_delete_on_destroy = false
    }
  }
  subscription_id = var.subscription_id
  # Default "core" auto-registration covers Microsoft.Network/KeyVault/ManagedIdentity/
  # ContainerService/Authorization. Verified against deliberate-v2 at first plan; if a
  # provider is missing, register explicitly with az CLI (do NOT switch to "none").
}
