#!/usr/bin/env bash
set -euo pipefail

RAW_WIN_PATH="${RAW_WIN_PATH:-C:\\ffmpeg\\k8s-data-platform-ami.raw}"
REGION="${REGION:-}"
BUCKET="${BUCKET:-}"
S3_KEY="${S3_KEY:-}"
DESCRIPTION="${DESCRIPTION:-k8s-data-platform raw image import}"
SKIP_UPLOAD=0
WAIT_IMPORT=0
POLL_INTERVAL_SEC=20

usage() {
  cat <<'EOF'
Usage: bash scripts/import_ami_from_tmp.sh --region <aws-region> --bucket <s3-bucket> [options]

Options:
  --region <region>         AWS region (required)
  --bucket <bucket>         S3 bucket name (required)
  --s3-key <key>            S3 object key. Default: basename of RAW file
  --raw-win-path <path>     Windows raw path. Default: C:\ffmpeg\k8s-data-platform-ami.raw
  --description <text>      Import task description
  --skip-upload             Skip S3 upload and only start import-image
  --wait                    Wait until import task reaches completed/deleted
  --poll-interval <sec>     Poll interval for --wait mode. Default: 20
  -h, --help                Show this help

Examples:
  bash scripts/import_ami_from_tmp.sh \
    --region ap-northeast-2 \
    --bucket my-ami-import-bucket \
    --s3-key images/k8s-data-platform-ami.raw \
    --wait

  REGION=ap-northeast-2 BUCKET=my-ami-import-bucket \
    bash scripts/import_ami_from_tmp.sh --skip-upload
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      [[ $# -ge 2 ]] || die "--region requires a value"
      REGION="$2"
      shift 2
      ;;
    --bucket)
      [[ $# -ge 2 ]] || die "--bucket requires a value"
      BUCKET="$2"
      shift 2
      ;;
    --s3-key)
      [[ $# -ge 2 ]] || die "--s3-key requires a value"
      S3_KEY="$2"
      shift 2
      ;;
    --raw-win-path)
      [[ $# -ge 2 ]] || die "--raw-win-path requires a value"
      RAW_WIN_PATH="$2"
      shift 2
      ;;
    --description)
      [[ $# -ge 2 ]] || die "--description requires a value"
      DESCRIPTION="$2"
      shift 2
      ;;
    --skip-upload)
      SKIP_UPLOAD=1
      shift
      ;;
    --wait)
      WAIT_IMPORT=1
      shift
      ;;
    --poll-interval)
      [[ $# -ge 2 ]] || die "--poll-interval requires a value"
      POLL_INTERVAL_SEC="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ -n "${REGION}" ]] || die "Provide --region."
[[ -n "${BUCKET}" ]] || die "Provide --bucket."

require_command aws
require_command wslpath
require_command basename

RAW_PATH="$(wslpath -u "${RAW_WIN_PATH}")"
[[ -f "${RAW_PATH}" ]] || die "RAW file not found: ${RAW_PATH}"

if [[ -z "${S3_KEY}" ]]; then
  S3_KEY="$(basename "${RAW_PATH}")"
fi

if [[ "${SKIP_UPLOAD}" == "0" ]]; then
  printf '[import_ami_from_tmp] Uploading RAW to s3://%s/%s\n' "${BUCKET}" "${S3_KEY}"
  aws s3 cp "${RAW_PATH}" "s3://${BUCKET}/${S3_KEY}" --region "${REGION}"
fi

TMP_JSON="$(mktemp)"
cleanup() {
  rm -f "${TMP_JSON}"
}
trap cleanup EXIT

cat > "${TMP_JSON}" <<EOF
[
  {
    "Description": "${DESCRIPTION}",
    "Format": "raw",
    "UserBucket": {
      "S3Bucket": "${BUCKET}",
      "S3Key": "${S3_KEY}"
    }
  }
]
EOF

printf '[import_ami_from_tmp] Starting import-image in region %s\n' "${REGION}"
IMPORT_TASK_ID="$(
  aws ec2 import-image \
    --region "${REGION}" \
    --description "${DESCRIPTION}" \
    --disk-containers "file://${TMP_JSON}" \
    --query 'ImportTaskId' \
    --output text
)"

printf '[import_ami_from_tmp] ImportTaskId: %s\n' "${IMPORT_TASK_ID}"

if [[ "${WAIT_IMPORT}" != "1" ]]; then
  printf '[import_ami_from_tmp] Check status:\n'
  printf '  aws ec2 describe-import-image-tasks --region %s --import-task-ids %s\n' "${REGION}" "${IMPORT_TASK_ID}"
  exit 0
fi

printf '[import_ami_from_tmp] Waiting for import completion...\n'
while true; do
  STATUS="$(
    aws ec2 describe-import-image-tasks \
      --region "${REGION}" \
      --import-task-ids "${IMPORT_TASK_ID}" \
      --query 'ImportImageTasks[0].Status' \
      --output text
  )"
  PROGRESS="$(
    aws ec2 describe-import-image-tasks \
      --region "${REGION}" \
      --import-task-ids "${IMPORT_TASK_ID}" \
      --query 'ImportImageTasks[0].Progress' \
      --output text
  )"
  AMI_ID="$(
    aws ec2 describe-import-image-tasks \
      --region "${REGION}" \
      --import-task-ids "${IMPORT_TASK_ID}" \
      --query 'ImportImageTasks[0].ImageId' \
      --output text
  )"
  printf '[import_ami_from_tmp] status=%s progress=%s image_id=%s\n' "${STATUS}" "${PROGRESS}" "${AMI_ID}"

  if [[ "${STATUS}" == "completed" ]]; then
    printf '[import_ami_from_tmp] AMI created: %s\n' "${AMI_ID}"
    exit 0
  fi
  if [[ "${STATUS}" == "deleted" ]]; then
    die "Import task ended with status=deleted. Check AWS task message."
  fi

  sleep "${POLL_INTERVAL_SEC}"
done
