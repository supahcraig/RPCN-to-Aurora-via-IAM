#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <aws-profile> <role-name>"
  exit 1
fi

AWS_PROFILE="$1"
ROLE="$2"

AWS="aws --profile ${AWS_PROFILE}"

echo "=== ROLE: ${ROLE} ==="
echo "=== AWS PROFILE: ${AWS_PROFILE} ==="
echo

echo "=== TRUST POLICY ==="
$AWS iam get-role \
  --role-name "$ROLE" \
  --query 'Role.AssumeRolePolicyDocument' \
  --output json

echo
echo "=== INLINE POLICIES ==="
INLINE_POLICIES=$($AWS iam list-role-policies \
  --role-name "$ROLE" \
  --query 'PolicyNames[]' \
  --output text)

if [ -z "$INLINE_POLICIES" ]; then
  echo "(none)"
else
  for p in $INLINE_POLICIES; do
    echo "--- $p ---"
    $AWS iam get-role-policy \
      --role-name "$ROLE" \
      --policy-name "$p" \
      --query 'PolicyDocument' \
      --output json
  done
fi

echo
echo "=== ATTACHED MANAGED POLICIES ==="
$AWS iam list-attached-role-policies \
  --role-name "$ROLE" \
  --output table

echo
echo "=== MANAGED POLICY DOCUMENTS ==="
for arn in $($AWS iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text); do
  echo "--- $arn ---"
  ver=$($AWS iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text)
  $AWS iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query 'PolicyVersion.Document' --output json
done


echo
echo "=== TAGS ==="
$AWS iam list-role-tags \
  --role-name "$ROLE" \
  --output table

