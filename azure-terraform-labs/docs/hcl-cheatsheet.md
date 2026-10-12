# HCL Cheatsheet

## Block types
| Block | Purpose |
|---|---|
| `terraform {}` | settings, required_providers, backend |
| `provider "x" {}` | provider config |
| `resource "type" "name" {}` | managed infrastructure |
| `data "type" "name" {}` | read existing infra (read-only) |
| `variable "x" {}` | input parameter |
| `output "x" {}` | exposed value |
| `locals {}` | computed internal values |
| `module "x" {}` | call a reusable module |

## Types
```hcl
string  number  bool
list(string)          # ordered, indexed, dupes ok
set(string)           # unordered, no dupes — for_each
map(string)           # key-value, values same type
object({ f = type })  # named fields, mixed types
map(object({ ... }))  # N structured values, keyed
optional(type, default)  # inside object() only
```

## References
```hcl
var.name                              # variable
local.name                            # local (singular)
azurerm_x.name.attr                   # resource attribute
data.azurerm_x.name.attr              # data source attribute
each.key / each.value                 # inside for_each
count.index                           # inside count
module.name.output                    # module output
```

## for_each patterns
```hcl
for_each = var.subnets                                        # map
for_each = toset(var.names)                                   # list -> set
for_each = { for k, v in var.subnets : k => v if v.has_nsg }  # filtered
name             = each.key
address_prefixes = [each.value.cidr]
```

## for expressions
```hcl
[for x in list : x.field]                    # -> list
[for x in list : x.field if cond]            # filtered list
{ for k, v in map : k => v.field }           # -> map
{ for k, v in map : k => v if v.flag }        # filtered map
```

## Functions (common)
```hcl
cidrsubnet("172.22.0.0/16", 8, 10)  # -> 172.22.10.0/24
cidrhost("172.22.10.0/24", 4)       # -> 172.22.10.4
toset(list)  merge(m1, m2)  keys(m)  values(m)
lookup(m, key, default)  contains(list, val)  length(x)
can(expr)         # true if expr doesn't error
alltrue(list)     # true if every element true
regex(pat, str)   # THROWS on no match — wrap in can()
```

## Validation
```hcl
validation {
  condition     = alltrue([for c in var.cidrs : can(regex("^172\\.", c))])
  error_message = "All CIDRs must start with 172."
}
```

## lifecycle
```hcl
lifecycle {
  prevent_destroy       = true       # blocks TF destroy (not a hard lock)
  create_before_destroy = true       # avoid downtime on replace
  ignore_changes        = [tags]     # stop tracking drift on attrs
}
```
