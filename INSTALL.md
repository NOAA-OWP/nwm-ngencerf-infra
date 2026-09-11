# Installation

Step-by-step deployment guide for the ngenCERF AWS stack. Written for an
operator with administrator access to the target AWS account; no prior
knowledge of this repository is assumed. Each environment is a self-contained
Terraform root under `aws/envs/<env>/` (`sandbox`, `ea`, `uat2`) calling the
shared module in `aws/modules/ngencerf/`, with its own remote state.

`ea` and `uat2` deploy to the NGWPC Test account into the existing
`Test-ngen-Compute` VPC, which the stack discovers by tag at plan time. Nothing
in this repo creates VPCs, subnets, or internet-facing resources; the ALB it
creates is internal, and public reach is provided by the centralized edge
(public ALB, then an NLB in the account, then this stack's internal ALB).

## 1. Prerequisites

- Terraform >= 1.10
- AWS CLI v2, authenticated to the target account, region `us-east-1`
- `make` (all commands below are Makefile targets run from the repo root)

Account-side prerequisites that must exist before the first apply:

- The Secrets Manager secret `svc-ldap-ro-testdev` (LDAP read-only bind
  password under a `password` key) in the target account. The apply fails fast
  at a data lookup if it is missing.
- EC2 service quota headroom for `c5n.9xlarge` and `r8a.12xlarge` (the two
  Slurm compute partitions; they autoscale from zero).
- Write access to the state bucket named in the env's `backend.hcl`.

## 2. One-time setup per environment

```bash
cd aws/envs/ea   # or aws/envs/uat2
cp backend.hcl.example backend.hcl              # values are already correct per env
cp terraform.tfvars.example terraform.tfvars    # owner is already set
cd ../../..
```

## 3. Deploy

```bash
make init ENV=ea
make plan ENV=ea
make apply ENV=ea
```

What to expect:

- A fresh environment plans at roughly 99 resources to add, 0 to change, 0 to
  destroy. If a fresh env's plan wants to destroy anything, stop and
  investigate before applying.
- The first apply bakes a custom compute-node AMI with EC2 Image Builder
  before building the rest; that step alone takes 20 to 35 minutes. Expect up
  to an hour total. Later applies skip the bake unless the image recipe
  changes.
- If an apply fails partway (quota, transient API error), fix the cause and
  run plan and apply again; Terraform reconciles from where it stopped. Do not
  delete resources by hand.

Repeat for the second environment (`ENV=uat2`).

## 4. Post-apply bootstrap

```bash
make bootstrap ENV=ea
```

This stages the Slurm workload containers (SIF images) and the ngen static
data set onto the environment's EFS filesystem. It requires the cross-account
S3 grants (Data-account buckets) to be in place; the stack itself applies fine
without them, but jobs cannot run until this completes.

## 5. Handoff values for the public edge

```bash
cd aws/envs/ea && terraform output alb_dns_name
```

That DNS name is the environment's internal ALB and is the target for the
NLB in the sandwich: use an ALB-type target group on port 80. The ALB performs
the path routing (`/api/*` to the API service, everything else to the UI), so
the NLB must target the ALB, not the ECS services directly. The ALB answers
`HTTP 200` on `/api/health_check/` once the app is up (allow up to 10 minutes
after apply for first boot).

## 6. Verify

- From a host with VPC access: `curl http://<alb_dns_name>/api/health_check/`
  returns `ok`.
- Once the edge is wired: the public hostname loads the UI over HTTPS, a login
  succeeds, and browser API calls go to `https://<public hostname>/api/...`.
- After a redirect (for example the login flow), the address bar must stay
  `https://`; if a redirect downgrades to `http://`, the `X-Forwarded-Proto`
  header is not reaching the app, which means it is being lost between the
  edge and the internal ALB.

## 7. Updating a running environment

To move an environment to new application versions:

1. Edit the version pins in `aws/envs/<env>/main.tf`: `ngencerf_server_image`,
   `ngencerf_ui_image`, and the `sif_workloads` tags.
2. `make plan ENV=<env>` then `make apply ENV=<env>`. Changed server/UI pins
   roll the ECS services with no downtime; changed SIF tags update the
   sif-sync task definitions only.
3. `make bootstrap ENV=<env>` to stage the newly pinned SIFs onto EFS (safe to
   re-run; the static-data sync is idempotent).
4. If SIF tags changed, restart the API service afterward. The server reads
   version metadata out of the SIF files once and caches it until it
   restarts, so without this step the About dialog keeps reporting the
   previous versions:

   ```bash
   aws ecs update-service --cluster ngencerf-<env>-cluster \
     --service ngencerf-<env>-django --force-new-deployment
   ```

5. Check the About dialog after a hard browser refresh (the About response
   can also be cached by the browser).

## 8. Teardown

```bash
make destroy ENV=ea
```

Note: `ea` and `uat2` set `production = true`, which turns on RDS deletion
protection. A destroy will be refused until `production` is set to `false` in
the env's `main.tf` and applied first. This is deliberate: customer-facing
environments should not be trivially destroyable.

## 9. Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `Error acquiring the state lock` | A previous run was interrupted | `terraform force-unlock <id>` from the env dir, only if no other run is active |
| Apply fails at a Secrets Manager data lookup | `svc-ldap-ro-testdev` missing in this account | Create the secret, re-run apply |
| Compute jobs pend forever in Slurm | Instance quota too low | Raise the c5n/r8a quotas, jobs then schedule on their own |
| Gage setup in the app fails to fetch data | EDFS DNS not resolvable from this VPC | Associate the EDFS private hosted zone with this VPC and allow-list its CIDR |
| ZIP download links return 403 | Data-account bucket policy or task-role grants missing | Apply the per-env S3 grants on the Data side |
| About dialog shows old versions after a SIF update | Version metadata is cached until the API service restarts | Force a new deployment of the django service (section 7), then hard-refresh the browser |
