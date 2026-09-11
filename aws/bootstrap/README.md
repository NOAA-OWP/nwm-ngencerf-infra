# Bootstrap: one-time per-account state backend

Creates the Terraform state backend (S3 bucket + customer-managed KMS key) that every env's root module under `aws/envs/<env>/` uses to store its state. One bucket per AWS account, shared across all envs in that account; envs use different state keys (`sandbox/terraform.tfstate`, `dev/terraform.tfstate`, `ea/terraform.tfstate`, etc.).

State **locking** uses S3's native lock-file mechanism (`use_lockfile = true` in the backend config). **DynamoDB is NOT used** because that pattern is deprecated as of Terraform 1.10. References:

- [HashiCorp Terraform S3 backend docs](https://developer.hashicorp.com/terraform/language/backend/s3)
- [AWS Prescriptive Guidance: Backend best practices](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/backend.html)

You run this **once per AWS account**, then never again (unless tearing the whole account's infrastructure down).

## Why this is its own module

Terraform's state backend has to exist *before* Terraform can use it as a backend (chicken-and-egg). We solve it by running this module with **local state** first, then migrating its own state into the bucket it just created. After that, every env's root module under `aws/envs/<env>/` uses the same bucket as its state backend from the start.

## Run order

```bash
# From repo root
cd aws/bootstrap

# 1. Initialize (uses local state because no backend block is configured)
terraform init

# 2. Apply: creates KMS key and S3 bucket
terraform apply

# 3. Read the values it produced
terraform output

# 4. Create backend.hcl in this directory using those values
cat > backend.hcl <<EOF
bucket       = "$(terraform output -raw state_bucket)"
key          = "bootstrap/terraform.tfstate"
region       = "$(terraform output -raw region)"
encrypt      = true
kms_key_id   = "$(terraform output -raw kms_key_alias)"
use_lockfile = true
EOF

# 5. Migrate this module's local state INTO the S3 bucket it created
terraform init -backend-config=backend.hcl -migrate-state
# (type "yes" when prompted to copy state)

# 6. Delete the now-empty local state files
rm -f terraform.tfstate terraform.tfstate.backup
```

After this, the bootstrap module's state lives in S3. No local state file ever gets committed.

## Set up env backends

After bootstrap, each env in this account gets its own `backend.hcl` under
`aws/envs/<env>/`. They share the bucket created above but use different state
keys so the files don't collide.

For each env in this account. Current layout: the NGWPC Sandbox account holds `sandbox`; the NGWPC Test account holds `test/dev`, `test/dev2`, `test/perf`, `test/integration`; the NGWPC Optimization account holds `optimization/ea`, `optimization/uat`, `optimization/uat2`. NGWPC's state buckets (`ngwpc-infra-sbox` for the Sandbox account, `ngwpc-infra-test` for the Test account, and `ngwpc-infra-oe` for the Optimization account, all matching the `{account-short-name}` pattern) are pre-existing in the NGWPC infra org; how they were provisioned (LZA vs manual vs another repo) is unverified. The NGWPC Sandbox, Test, and Optimization accounts therefore do NOT run this bootstrap module; it is only run in an account that needs Terraform to create its own state backend.

```bash
cd aws/envs/<env>   # e.g. aws/envs/dev
cat > backend.hcl <<EOF
bucket       = "$(cd ../../bootstrap && terraform output -raw state_bucket)"
key          = "<env>/terraform.tfstate"
region       = "$(cd ../../bootstrap && terraform output -raw region)"
encrypt      = true
kms_key_id   = "$(cd ../../bootstrap && terraform output -raw kms_key_alias)"
use_lockfile = true
EOF
```

Replace `<env>` in both places. Then from the repo root:
`make init ENV=<env> && make plan ENV=<env> && make apply ENV=<env>`.
