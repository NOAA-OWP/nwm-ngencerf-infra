#!/usr/bin/env bash
#
# smoke.sh: end-to-end smoke test for a deployed env.
#
# Verifies the stack that `terraform apply` + `bootstrap.sh` should have
# produced, in five checks:
#   1. ecs: the django + nuxt services are running and fully rolled out.
#   2. alb: both target groups report healthy. The django target's health
#      check is GET /api/health_check/ expecting HTTP 200, so a healthy state
#      proves the server API booted (not just that a task is running).
#   3. pcs: the PCS (managed Slurm) cluster is ACTIVE.
#   4. efs: the staged artifacts exist on EFS: one <name>.sif symlink per
#      var.sif_workloads entry plus a non-empty ngen static-input tree.
#   5. http: the application answers through the ALB: / (UI) and
#      /api/health_check/ (server API) both return HTTP 200.
#
# Checks 4 and 5 run on the PCS login node over SSM Run Command, because EFS
# and the internal ALB are reachable only inside the VPC; the workstation
# needs only AWS credentials. Read-only: nothing is created or modified.
#
# Run after `make apply ENV=<env>` and `make bootstrap ENV=<env>`. A fresh
# django task can spend ~10 min on first-boot init (migrations + gage load)
# before its first passing health check; re-run if the apply just finished.
# Assumes the committed posture of enable_pcs = true (all envs today).
#
# Usage:
#   make smoke ENV=<env>
#   bash aws/scripts/smoke.sh <env>
#
# Requires: AWS credentials for the target account, the env already
# `terraform apply`-ed (reads its terraform outputs), and jq.

set -euo pipefail

ENV="${1:?usage: smoke.sh <env>  (e.g. sandbox)}"
REGION="us-east-1"
DIR="aws/envs/${ENV}"
PREFIX="ngencerf-$(echo "${ENV}" | tr '/' '-')"

if [ ! -d "${DIR}" ]; then
  echo "ERROR: env dir '${DIR}' not found (run from the repo root)." >&2
  exit 1
fi
cd "${DIR}"

alb=$(terraform output -raw alb_dns_name 2>/dev/null || true)
sif_names=$(terraform output -json sif_sync_task_definitions 2>/dev/null | jq -r 'keys[]' || true)

if [ -z "${alb}" ] || [ -z "${sif_names}" ]; then
  echo "ERROR: terraform outputs missing for env '${ENV}'. Is the env applied?" >&2
  exit 1
fi

# --- check 1: ECS services running + rolled out ------------------------------
check_ecs() {
  local out svc row
  echo "=== ecs: django + nuxt services running and rolled out..."
  out=$(aws ecs describe-services --region "${REGION}" --cluster "${PREFIX}-cluster" \
    --services "${PREFIX}-django" "${PREFIX}-nuxt" \
    --query 'services[].[serviceName,desiredCount,runningCount,deployments[0].rolloutState]' \
    --output text 2>/dev/null || true)
  if [ -z "${out}" ]; then
    echo "ERROR: could not describe services on cluster ${PREFIX}-cluster." >&2
    return 1
  fi
  for svc in "${PREFIX}-django" "${PREFIX}-nuxt"; do
    row=$(echo "${out}" | awk -v s="${svc}" '$1 == s { print; found = 1 } END { exit !found }') \
      || { echo "ERROR: service ${svc} not found on cluster ${PREFIX}-cluster." >&2; return 1; }
    echo "  ${row}"
    echo "${row}" | awk '$2 + 0 >= 1 && $2 == $3 && $4 == "COMPLETED" { exit 0 } { exit 1 }' \
      || { echo "ERROR: ${svc} not settled (want desired == running >= 1 and rollout COMPLETED)." >&2; return 1; }
  done
  echo "  OK: both ECS services running, rollout COMPLETED."
}

# --- check 2: ALB target groups healthy --------------------------------------
check_alb() {
  local tg arn states s
  echo "=== alb: target groups healthy..."
  for tg in "${PREFIX}-django" "${PREFIX}-nuxt"; do
    arn=$(aws elbv2 describe-target-groups --region "${REGION}" --names "${tg}" \
      --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
    if [ -z "${arn}" ] || [ "${arn}" = "None" ]; then
      echo "ERROR: target group ${tg} not found." >&2
      return 1
    fi
    states=$(aws elbv2 describe-target-health --region "${REGION}" --target-group-arn "${arn}" \
      --query 'TargetHealthDescriptions[].TargetHealth.State' --output text 2>/dev/null || true)
    if [ -z "${states}" ]; then
      echo "ERROR: no targets registered in ${tg}." >&2
      return 1
    fi
    for s in ${states}; do
      if [ "${s}" != "healthy" ]; then
        echo "ERROR: ${tg} target state '${s}' (a fresh django task can need ~10 min of first-boot init; re-run shortly)." >&2
        return 1
      fi
    done
    echo "  ${tg}: ${states}"
  done
  echo "  OK: all ALB targets healthy (django health check = /api/health_check/)."
}

# --- check 3: PCS cluster ACTIVE ---------------------------------------------
check_pcs() {
  local status
  echo "=== pcs: cluster ACTIVE..."
  status=$(aws pcs list-clusters --region "${REGION}" \
    --query "clusters[?name=='${PREFIX}-pcs'].status" --output text 2>/dev/null || true)
  if [ -z "${status}" ]; then
    echo "ERROR: PCS cluster ${PREFIX}-pcs not found (this env should run enable_pcs = true)." >&2
    return 1
  fi
  if [ "${status}" != "ACTIVE" ]; then
    echo "ERROR: PCS cluster ${PREFIX}-pcs status=${status} (want ACTIVE)." >&2
    return 1
  fi
  echo "  OK: cluster ${PREFIX}-pcs ACTIVE."
}

# --- checks 4 + 5: EFS staging + HTTP through the ALB, via the login node ----
# The login node is the one always-on box inside the VPC that mounts EFS (at
# /ngencerf-app) and can reach the internal ALB, so both checks run there over
# SSM. The remote script prints marker lines (SIF_<name>=..., STATIC=...,
# HTTP_UI=..., HTTP_API=...) that are parsed locally into pass/fail.
check_efs_http() {
  local iid script b64 cmd_id status i out names_flat rc
  echo "=== efs+http: staged artifacts + app answering, via the login node..."

  iid=$(aws ec2 describe-instances --region "${REGION}" \
    --filters "Name=tag:Name,Values=${PREFIX}-pcs-node" "Name=instance-type,Values=c6i.large" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
  if [ -z "${iid}" ] || [ "${iid}" = "None" ]; then
    echo "ERROR: login node not found (running c6i.large tagged ${PREFIX}-pcs-node). Is PCS up?" >&2
    return 1
  fi
  echo "  login node: ${iid}"

  names_flat=$(echo ${sif_names} | tr '\n' ' ')
  script=$(
    cat <<'EOS'
set -u
SIFDIR=/ngencerf-app/singularity
STATIC=/ngencerf-app/data/ngen-cal-data/ngen-static-files
for name in __SIF_NAMES__; do
  if [ -e "$SIFDIR/$name.sif" ]; then
    echo "SIF_$name=OK -> $(readlink "$SIFDIR/$name.sif")"
  else
    echo "SIF_$name=MISSING"
  fi
done
if [ -d "$STATIC" ] && [ -n "$(ls -A "$STATIC" 2>/dev/null)" ]; then
  echo "STATIC=OK"
else
  echo "STATIC=MISSING"
fi
echo "HTTP_UI=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://__ALB__/ || echo 000)"
echo "HTTP_API=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://__ALB__/api/health_check/ || echo 000)"
EOS
  )
  script="${script//__SIF_NAMES__/${names_flat}}"
  script="${script//__ALB__/${alb}}"
  # base64 so the multi-line script survives SSM parameter quoting.
  b64=$(printf '%s' "${script}" | base64 | tr -d '\n')

  cmd_id=$(aws ssm send-command --region "${REGION}" --instance-ids "${iid}" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"echo ${b64} | base64 -d | bash\"]" \
    --query 'Command.CommandId' --output text 2>/dev/null || true)
  if [ -z "${cmd_id}" ] || [ "${cmd_id}" = "None" ]; then
    echo "ERROR: failed to send the SSM command to the login node." >&2
    return 1
  fi

  status="Pending"
  for i in $(seq 1 30); do
    status=$(aws ssm get-command-invocation --region "${REGION}" \
      --command-id "${cmd_id}" --instance-id "${iid}" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
    case "${status}" in
      Success) break ;;
      Failed | Cancelled | TimedOut) break ;;
      *) sleep 5 ;;
    esac
  done
  if [ "${status}" != "Success" ]; then
    echo "ERROR: login-node check did not complete (status=${status})." >&2
    return 1
  fi

  out=$(aws ssm get-command-invocation --region "${REGION}" --command-id "${cmd_id}" --instance-id "${iid}" \
    --query 'StandardOutputContent' --output text 2>/dev/null || true)
  echo "${out}" | sed 's/^/  /'

  rc=0
  if echo "${out}" | grep -q '=MISSING'; then
    echo "ERROR: EFS staging incomplete (run: make bootstrap ENV=${ENV})." >&2
    rc=1
  else
    echo "  OK: SIF symlinks + static-input tree present on EFS."
  fi
  if [ "$(echo "${out}" | sed -n 's/^HTTP_UI=//p')" = "200" ] \
    && [ "$(echo "${out}" | sed -n 's/^HTTP_API=//p')" = "200" ]; then
    echo "  OK: UI and server API answer HTTP 200 through the ALB."
  else
    echo "ERROR: app not answering through the ALB (want HTTP 200 from / and /api/health_check/)." >&2
    rc=1
  fi
  return "${rc}"
}

overall=0
check_ecs || overall=1
check_alb || overall=1
check_pcs || overall=1
check_efs_http || overall=1

if [ "${overall}" != "0" ]; then
  echo "Smoke test FAILED: one or more checks did not pass (see errors above)." >&2
  exit 1
fi

echo "Smoke OK (env=${ENV})."
