# Terraform Command Cheatsheet

| Command | When to use |
|---|---|
| `terraform init` | First run in a folder, or after changing providers/backend |
| `terraform fmt` | Format .tf files to standard style — run before commit |
| `terraform validate` | Check HCL syntax offline (no API calls) |
| `terraform plan` | Preview changes — always before apply |
| `terraform plan -out=tfplan` | Save plan to a file |
| `terraform apply` | Deploy changes (prompts for confirmation) |
| `terraform apply tfplan` | Apply a saved plan exactly |
| `terraform apply -auto-approve` | Apply without prompt (CI only — careful) |
| `terraform apply -target=<addr>` | Apply one specific resource |
| `terraform destroy` | Tear down all managed resources |
| `terraform output` | Print all outputs |
| `terraform output -raw <name>` | Print one output as plain text (sensitive too) |
| `terraform output -json` | Dump all outputs as JSON |
| `terraform state list` | List resources in state |
| `terraform state show <addr>` | Show one resource's state |
| `terraform state mv <old> <new>` | Rename in state without destroy/recreate |
| `terraform state rm <addr>` | Remove from state (leaves cloud resource) |
| `terraform import <addr> <cloud_id>` | Bring existing resource under management |
| `terraform workspace new <name>` | Create a workspace |
| `terraform workspace select <name>` | Switch workspace |

## Plan symbols
| Symbol | Meaning | Risk |
|---|---|---|
| `+` | create | low |
| `~` | update in-place | low — review |
| `-` | destroy | high — verify |
| `-/+` | replace (destroy + recreate) | critical — check dependents |
| `<=` | data source read | info |

## Daily folder workflow (Windows / PowerShell)
```powershell
# Start a new day by copying the base template
Copy-Item -Recurse _base dayNN-topic-name
cd dayNN-topic-name

# Set SP credentials (once per shell session)
$env:ARM_CLIENT_ID       = "<client-id>"
$env:ARM_CLIENT_SECRET   = "<client-secret>"
$env:ARM_TENANT_ID       = "<tenant-id>"
$env:ARM_SUBSCRIPTION_ID = "<subscription-id>"

terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
# ... work ...
terraform destroy   # tear down when done for the day
```
