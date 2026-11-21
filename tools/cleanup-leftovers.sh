#!/usr/bin/env bash
# Removes things the console path can leave behind, so the CloudFormation path starts clean.
# It deletes only the fixed log group name. IAM roles are listed for you to delete by hand.
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
LOG_GROUP="/aws/codebuild/gitleaks-demo-scan"

echo "Region: ${REGION}"

if aws logs describe-log-groups --region "${REGION}" --log-group-name-prefix "${LOG_GROUP}" \
     --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" --output text | grep -q .; then
  aws logs delete-log-group --region "${REGION}" --log-group-name "${LOG_GROUP}" \
    && echo "Deleted log group ${LOG_GROUP}"
else
  echo "Log group ${LOG_GROUP} not found. Nothing to delete."
fi

echo
echo "IAM roles with 'gitleaks-demo' in the name (delete these by hand if they are leftovers):"
aws iam list-roles --query "Roles[?contains(RoleName, 'gitleaks-demo')].RoleName" --output text \
  | tr '\t' '\n' | sed 's/^/  /'

echo
echo "Customer managed IAM policies with 'gitleaks-demo' in the name:"
aws iam list-policies --scope Local \
  --query "Policies[?contains(PolicyName, 'gitleaks-demo')].PolicyName" --output text \
  | tr '\t' '\n' | sed 's/^/  /'
