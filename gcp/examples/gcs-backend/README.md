# gcp module with remote (GCS) state

An opt-in wrapper that runs the `gcp/` module with its Terraform state in a GCS bucket.
The module and `onboard.sh` are unchanged: they still keep state in a local file.

## Use

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in; the file is git-ignored
terraform init -backend-config=kaos-io-dev.gcs.tfbackend
terraform plan
```

For another org, copy `kaos-io-dev.gcs.tfbackend` with its own `bucket` and `prefix`.
The bucket must exist before `init`, and the caller needs object read/write on it.

## attribute_condition

`attribute_condition` is a CEL expression set on the WIF provider. Tokens that fail it
are rejected at the STS exchange. Leave it unset (null) for no condition, which is the
module default. To admit only the org's own Zitadel sub, use the module's `zitadel_sub`
output: `assertion.sub=="<zitadel_sub>"`.
