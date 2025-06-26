#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"

if ! find "$WORKDIR" -name '*.tf' -print -quit | grep -q .; then
  echo "ℹ️ Nenhum arquivo .tf encontrado - pulando verificações Terraform"
  exit 0
fi

###################
# 1. tfscan       #
###################
echo "▶️ tfscan scanning"
tfscan --format json "$WORKDIR" > /tmp/tfscan.json || true
jq -c '.results[]?' /tmp/tfscan.json | while read -r res; do
  rule=$(echo "$res" | jq -r .rule_id)
  title="tfscan: $rule"
  mark_problem
  issue_info=$(find_issue "$title")
  if [[ -z "$issue_info" ]]; then
    create_issue "$title" "\`\`\`json\n${res}\n\`\`\`" "terraform-security"
  else
    issue_no=${issue_info%%:*}
    issue_state=${issue_info##*:}
    if [[ "$issue_state" == "closed" ]]; then
      reopen_issue "$issue_no"
    fi
  fi
done

###################
# 2. TFLint       #
###################
echo "▶️ TFLint scanning"
tflint --format json "$WORKDIR" > /tmp/tflint.json || true
jq -c '.diagnostics[]?' /tmp/tflint.json | while read -r diag; do
  rule=$(echo "$diag" | jq -r .rule_name)
  msg=$(echo "$diag"  | jq -r .message)
  title="tflint: $rule - $msg"
  mark_problem
  issue_info=$(find_issue "$title")
  if [[ -z "$issue_info" ]]; then
    create_issue "$title" "\`\`\`json\n${diag}\n\`\`\`" "terraform-security"
  else
    issue_no=${issue_info%%:*}
    issue_state=${issue_info##*:}
    if [[ "$issue_state" == "closed" ]]; then
      reopen_issue "$issue_no"
    fi
  fi
done


###################
# 3. Trivy Config #
###################
echo "▶️ Trivy config scanning"
trivy config --quiet --format json -o /tmp/trivy_tf.json "$WORKDIR" || true
jq -c '.Results[]?.Misconfigurations[]?' /tmp/trivy_tf.json | while read -r mis; do
  id=$(echo "$mis" | jq -r .ID)
  title="Trivy Terraform: $id"
  mark_problem
  issue_info=$(find_issue "$title")
  if [[ -z "$issue_info" ]]; then
    create_issue "$title" "\`\`\`json\n${mis}\n\`\`\`" "terraform-security"
  else
    issue_no=${issue_info%%:*}
    issue_state=${issue_info##*:}
    if [[ "$issue_state" == "closed" ]]; then
      reopen_issue "$issue_no"
    fi
  fi
done
