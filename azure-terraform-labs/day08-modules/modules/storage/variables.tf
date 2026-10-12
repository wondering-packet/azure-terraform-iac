variable "rg_name" {
  type = string
}
variable "name" {
  type = string
}
variable "location" {
  type = string
}
variable "account_tier" {
  type = string
  validation {
    condition     = contains(["Standard", "Premium"], var.account_tier)
    error_message = "account tier can be 'Standard' or 'Premium' only"
  }
}
variable "account_replication_type" {
  type = string
  validation {
    condition     = contains(["LRS", "GRS", "RAGRS", "ZRS", "GZRS", "RAGZRS"], var.account_replication_type)
    error_message = "account_replication_type can be 'LRS, GRS, RAGRS, ZRS, GZRS, RAGZRS' only"
  }
}
variable "account_kind" {
  type = string
  validation {
    condition     = contains(["BlobStorage", "BlockBlobStorage", "FileStorage", "Storage", "StorageV2"], var.account_kind)
    error_message = "account_kind can be 'BlobStorage, BlockBlobStorage, FileStorage, Storage, StorageV2' only"
  }
  default = "StorageV2"
}
variable "allow_nested_items_to_be_public" {
  type    = bool
  default = true
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "network_rules_default_action" {
  type = string
  validation {
    condition     = contains(["Deny", "Allow"], var.network_rules_default_action)
    error_message = "action can be 'Allow, Deny' only"
  }
}
variable "network_rules_bypass" {
  type    = list(string)
  default = ["AzureServices"]
}
variable "network_rules_allowed_subnet_ids" {
  type = list(string)
}

