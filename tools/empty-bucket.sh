#!/usr/bin/env bash
# Deletes every object version and delete marker in a bucket, so the bucket can be deleted.
# Usage: bash tools/empty-bucket.sh <bucket-name>
set -euo pipefail

BUCKET="${1:?Usage: bash tools/empty-bucket.sh <bucket-name>}"

if ! aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "Bucket ${BUCKET} does not exist or is not yours. Nothing to do."
  exit 0
fi

delete_all() {
  # $1 = Versions or DeleteMarkers
  local kind="$1" count=0 key version
  while IFS=$'\t' read -r key version; do
    [ -z "${key}" ] && continue
    [ "${key}" = "None" ] && continue
    aws s3api delete-object --bucket "${BUCKET}" --key "${key}" --version-id "${version}" >/dev/null
    count=$((count + 1))
  done < <(aws s3api list-object-versions --bucket "${BUCKET}" \
             --query "${kind}[].[Key,VersionId]" --output text)
  echo "Deleted ${count} item(s) from ${kind}."
}

delete_all Versions
delete_all DeleteMarkers
echo "Bucket ${BUCKET} is empty."
