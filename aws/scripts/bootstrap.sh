#!/usr/bin/env bash
#
# bootstrap.sh: one-time-per-bring-up EFS staging (SIFs + ngen static data).
#
# Seeds a freshly created (empty) EFS in two stages:
#   - sif-sync (sif_sync.tf): one standalone ECS task per var.sif_workloads,
#     oras-pulling each pinned SIF onto EFS /singularity and repointing the
#     <name>.sif symlink.
#   - static-data: the ngen static-input tree (module parameter files, BMI
#     forcing templates, forcing static dir, NWM retrospective) loaded onto EFS
#     /data/ngen-cal-data/ngen-static-files. Run over SSM on the PCS login node,
#     which has git + aws-cli + the EFS mount in its AMI: it `aws s3 sync`s the
#     bulk from ngwpc-dev and git-clones the config dirs from the public repos.
#
# Run once after the first `terraform apply` for an env, and again after any cold
# bring-up (a fresh EFS is empty). Idempotent.
#
# Usage:
#   make bootstrap ENV=<env>          # both stages (default)
#   make load-static ENV=<env>        # static-data stage only
#   bash aws/scripts/bootstrap.sh <env> [all|sifs|static]
#
# Requires: AWS credentials for the target account, the env already
# `terraform apply`-ed, and jq.

set -euo pipefail

ENV="${1:?usage: bootstrap.sh <env> [all|sifs|static]  (e.g. sandbox)}"
STAGE="${2:-all}"
REGION="us-east-1"
DIR="aws/envs/${ENV}"
PREFIX="ngencerf-$(echo "${ENV}" | tr '/' '-')"

case "${STAGE}" in
  all | sifs | static) ;;
  *)
    echo "ERROR: stage must be all, sifs, or static (got '${STAGE}')." >&2
    exit 1
    ;;
esac

if [ ! -d "${DIR}" ]; then
  echo "ERROR: env dir '${DIR}' not found (run from the repo root)." >&2
  exit 1
fi
cd "${DIR}"

cluster=$(terraform output -raw ecs_cluster_name 2>/dev/null || true)
subnets=$(terraform output -json private_subnet_ids 2>/dev/null | jq -r 'join(",")' || true)

if [ -z "${cluster}" ] || [ -z "${subnets}" ]; then
  echo "ERROR: cluster/subnet outputs missing for env '${ENV}'. Is the env applied?" >&2
  exit 1
fi

# --- SIF staging: run one standalone ECS task to completion -----------------
# Returns non-zero on failure (callers keep going and surface an overall failure
# at the end). Args: <label> <task-definition> <security-group-id> <log-suffix>
run_task() {
  local label="$1" taskdef="$2" sg="$3" logsuffix="$4"
  local netcfg task_arn exit_code reason
  netcfg="awsvpcConfiguration={subnets=[${subnets}],securityGroups=[${sg}],assignPublicIp=DISABLED}"
  echo "=== ${label}: running task '${taskdef}' on cluster '${cluster}' (env=${ENV}, region=${REGION})..."

  if ! task_arn=$(aws ecs run-task \
    --cluster "${cluster}" \
    --task-definition "${taskdef}" \
    --launch-type FARGATE \
    --region "${REGION}" \
    --network-configuration "${netcfg}" \
    --query 'tasks[0].taskArn' --output text) \
    || [ -z "${task_arn}" ] || [ "${task_arn}" = "None" ]; then
    echo "ERROR: run-task failed for ${label}." >&2
    return 1
  fi
  echo "  task started: ${task_arn}"
  echo "  waiting (runs to completion; a few minutes)..."
  aws ecs wait tasks-stopped --cluster "${cluster}" --tasks "${task_arn}" --region "${REGION}" || true

  exit_code=$(aws ecs describe-tasks --cluster "${cluster}" --tasks "${task_arn}" --region "${REGION}" \
    --query 'tasks[0].containers[0].exitCode' --output text 2>/dev/null || echo "unknown")
  if [ "${exit_code}" != "0" ]; then
    reason=$(aws ecs describe-tasks --cluster "${cluster}" --tasks "${task_arn}" --region "${REGION}" \
      --query 'tasks[0].stoppedReason' --output text 2>/dev/null || true)
    echo "ERROR: ${label} failed (exitCode=${exit_code}, reason=${reason})." >&2
    echo "  logs: aws logs tail /aws/ecs/${PREFIX}/${logsuffix} --region ${REGION} --since 30m" >&2
    return 1
  fi
  echo "  OK: ${label} (exitCode=0)."
}

# --- static-data: load the ngen static-input tree onto EFS via the login node
# The PCS login node (c6i.large) has git + aws-cli + the EFS root mounted at
# /ngencerf-app. We run the load there over SSM Run Command: sync the bulk from
# ngwpc-dev and clone the config dirs + verification parquet inputs from the
# public repos. The target is the
# cal-data subtree both tiers read (server /ngencerf/data/ngen-static-files ==
# login /ngencerf-app/data/ngen-cal-data/ngen-static-files). Cross-account read
# on ngwpc-dev is granted to the node role (pcs.tf) + the Data side.
run_static_login() {
  local iid cmd_id status i b64 script
  echo "=== static-data: loading ngen static-input tree via the login node (env=${ENV})..."

  iid=$(aws ec2 describe-instances --region "${REGION}" \
    --filters "Name=tag:Name,Values=${PREFIX}-pcs-node" "Name=instance-type,Values=c6i.large" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
  if [ -z "${iid}" ] || [ "${iid}" = "None" ]; then
    echo "ERROR: login node not found (running c6i.large tagged ${PREFIX}-pcs-node). Is PCS up?" >&2
    return 1
  fi
  echo "  login node: ${iid}"

  # The load script, run on the login node as root. Pinned to development for now
  # (tighten to a tag/commit when the static config is versioned).
  script=$(
    cat <<'EOS'
set -eu
STATIC=/ngencerf-app/data/ngen-cal-data/ngen-static-files
mkdir -p "$STATIC"
echo "Syncing nwm_retrospective + esmf from ngwpc-dev (nwm-tools-data)..."
aws s3 sync s3://ngwpc-dev/nwm-tools-data/nwm_retrospective "$STATIC/nwm_retrospective" --no-progress
aws s3 sync s3://ngwpc-dev/nwm-tools-data/esmf "$STATIC/forcing_static_dir" --no-progress
echo "Cloning module_parameter_files (nwm-msw-mgr)..."
cd "$STATIC" && rm -rf module_parameter_files tmp-msw
git clone --depth 1 --filter=blob:none --sparse -b development https://github.com/NGWPC/nwm-msw-mgr.git tmp-msw
( cd tmp-msw && git sparse-checkout set src/mswm/module_parameter_files )
mv tmp-msw/src/mswm/module_parameter_files "$STATIC/" && rm -rf tmp-msw
echo "Cloning bmi_forcing_templates (ngen-forcing)..."
cd "$STATIC" && rm -rf bmi_forcing_templates tmp-forcing
git clone --depth 1 --filter=blob:none --sparse -b development https://github.com/NGWPC/ngen-forcing.git tmp-forcing
( cd tmp-forcing && git sparse-checkout set NextGen_Forcings_Engine_BMI/BMI_NextGen_Configs/config_templates )
mv tmp-forcing/NextGen_Forcings_Engine_BMI/BMI_NextGen_Configs/config_templates "$STATIC/bmi_forcing_templates" && rm -rf tmp-forcing
echo "Cloning verification_data parquet inputs (nwm-eval-mgr)..."
cd "$STATIC" && rm -rf verification_data tmp-nwm-eval-mgr
git clone --depth 1 --filter=blob:none --sparse -b development https://github.com/NGWPC/nwm-eval-mgr.git tmp-nwm-eval-mgr
( cd tmp-nwm-eval-mgr && git sparse-checkout set data/inputs/gage_files )
mkdir -p "$STATIC/verification_data"
find tmp-nwm-eval-mgr/data/inputs/gage_files -type f -name '*.parquet' -exec cp {} "$STATIC/verification_data/" \;
rm -rf tmp-nwm-eval-mgr
echo "Static data staged. Top level:"
ls -la "$STATIC"
EOS
  )
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
  echo "  ssm command: ${cmd_id}"
  echo "  waiting (S3 sync + git clones; can take ~20 min on a fresh EFS)..."

  # Poll until terminal (the sync can outlast the CLI waiter's window).
  status="Pending"
  for i in $(seq 1 180); do
    status=$(aws ssm get-command-invocation --region "${REGION}" \
      --command-id "${cmd_id}" --instance-id "${iid}" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
    case "${status}" in
      Success) break ;;
      Failed | Cancelled | TimedOut) break ;;
      *) sleep 10 ;;
    esac
  done

  if [ "${status}" != "Success" ]; then
    echo "ERROR: static-data load did not succeed (status=${status})." >&2
    aws ssm get-command-invocation --region "${REGION}" --command-id "${cmd_id}" --instance-id "${iid}" \
      --query 'StandardErrorContent' --output text 2>/dev/null | tail -20 >&2 || true
    return 1
  fi
  echo "  OK: static-data loaded on EFS /data/ngen-cal-data/ngen-static-files."
}

overall=0

# Stage each workload's SIF with its own run-to-completion task. Sequential so a
# failure is clearly attributable; each is attempted regardless of the others.
if [ "${STAGE}" = "all" ] || [ "${STAGE}" = "sifs" ]; then
  taskdefs=$(terraform output -json sif_sync_task_definitions 2>/dev/null || echo '{}')
  sg=$(terraform output -raw sif_sync_security_group_id 2>/dev/null || true)
  names=$(echo "${taskdefs}" | jq -r 'keys[]' 2>/dev/null || true)

  if [ -z "${sg}" ] || [ "${sg}" = "null" ] || [ -z "${names}" ]; then
    echo "ERROR: sif-sync outputs missing for env '${ENV}'. Is enable_pcs = true and sif_workloads set?" >&2
    exit 1
  fi

  for name in ${names}; do
    taskdef=$(echo "${taskdefs}" | jq -r --arg n "${name}" '.[$n]')
    run_task "SIF ${name}" "${taskdef}" "${sg}" "sif-sync" || overall=1
  done
fi

# Load the ngen static-input tree onto EFS via the login node.
if [ "${STAGE}" = "all" ] || [ "${STAGE}" = "static" ]; then
  run_static_login || overall=1
fi

if [ "${overall}" != "0" ]; then
  echo "Bootstrap FAILED: one or more stages did not complete (see errors above)." >&2
  exit 1
fi

echo "Bootstrap OK (stage=${STAGE})."
