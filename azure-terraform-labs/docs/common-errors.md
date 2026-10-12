# Common Errors & Fixes

| Error / symptom | Cause | Fix |
|---|---|---|
| `A managed resource "x" "y" has not been declared` | Referencing a resource not defined in THIS folder | Each day folder is standalone — the resource must exist in a .tf file in the same folder. Terraform never reads parent/sibling folders. |
| `Reference to undeclared input variable` | `var.x` used but no `variable "x"` in this folder | Copy the variable declaration into this folder's variables.tf (from _base) |
| `Reference to undeclared local value` | `local.x` used but not defined here | Ensure locals.tf (from _base) is present in this folder |
| Value from tfvars not applied | Name mismatch between tfvars key and variable name | The tfvars key must EXACTLY match the `variable "name"` — no fuzzy matching |
| `Duplicate ... configuration` / duplicate declaration | Same resource/variable declared in two .tf files in one folder | Terraform merges all .tf in a folder — declare each name once |
| `for_each ... tuple` error | Passed a list to for_each | Wrap in `toset(...)` — for_each needs a map or set |
| `Invalid function argument` on regex | `regex()` threw on no match | Wrap in `can(regex(...))` — regex errors on no match |
| `optional` value is null downstream | Used `optional(type)` with no default | Use `optional(list(string), [])` to default to empty |
| `prevent_destroy` didn't stop a portal delete | It only blocks Terraform-initiated destroys | Add `azurerm_management_lock` (CanNotDelete) for real protection |
| AuthorizationFailed on RG create | SP has Network Contributor, not Contributor | Need Contributor at subscription scope (resolved) |
| Backend init fails | Storage account/container missing | Create them first (Day 2), then `terraform init` |

## The #1 folder-structure rule
Terraform only reads `.tf` files in the **current directory**. It does not read
parent folders, sibling folders, or subfolders (except declared modules).
Every day folder must be self-contained: main.tf + variables.tf + locals.tf +
terraform.tfvars + your exercise files, all together.
