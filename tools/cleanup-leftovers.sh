#!/usr/bin/env bash
# Removes things the console path can leave behind, so the CloudFormation path starts clean.
# It deletes the fixed log group and any CodePipeline webhook that points at our pipeline.
# IAM roles and policies are only listed. Delete them by hand after you check the names.
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
LOG_GROUP="/aws/codebuild/gitleaks-demo-scan"
PIPELINE="gitleaks-demo-pipeline"

echo "Region: ${REGION}"

echo
echo "Log group"
if aws logs describe-log-groups --region "${REGION}" --log-group-name-prefix "${LOG_GROUP}" \
     --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" --output text | grep -q .; then
  aws logs delete-log-group --region "${REGION}" --log-group-name "${LOG_GROUP}" \
    && echo "  Deleted ${LOG_GROUP}"
else
  echo "  ${LOG_GROUP} not found. Nothing to delete."
fi

echo
echo "CodePipeline webhooks that point at ${PIPELINE}"
WEBHOOKS="$(aws codepipeline list-webhooks --region "${REGION}" \
  --query "webhooks[?definition.targetPipeline=='${PIPELINE}'].definition.name" --output text)"
if [ -z "${WEBHOOKS}" ] || [ "${WEBHOOKS}" = "None" ]; then
  echo "  None found."
else
  for name in ${WEBHOOKS}; do
    aws codepipeline deregister-webhook-with-third-party --region "${REGION}" --webhook-name "${name}" \
      && echo "  Deregistered ${name} from GitHub"
    aws codepipeline delete-webhook --region "${REGION}" --name "${name}" \
      && echo "  Deleted ${name}"
  done
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
