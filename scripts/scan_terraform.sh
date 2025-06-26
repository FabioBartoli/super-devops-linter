#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"

###############################################################################
# Sai cedo se não houver Terraform                                            #
###############################################################################
if ! find "$WORKDIR" -name '*.tf' -print -quit | grep -q .; then
  echo "ℹ️ Nenhum arquivo .tf encontrado - pulando verificações Terraform"
  exit 0
fi

###############################################################################
# 1. tfsec                                                                    #
###############################################################################
echo "▶️ tfsec scanning"
tfsec --no-color --format json --out /tmp/tfsec.json "$WORKDIR" || true

if [[ -s /tmp/tfsec.json ]]; then
  jq -c '.results[]?' /tmp/tfsec.json 2>/dev/null | \
  while read -r res; do
    rule=$(echo "$res" | jq -r .rule_id)
    title="tfsec: $rule"
    body="\`\`\`json\n${res}\n\`\`\`"

    mark_problem
    issue_info=$(find_issue "$title")
    if [[ -z "$issue_info" ]]; then
      create_issue "$title" "$body" "terraform-security"
    else
      num=${issue_info%%:*}; state=${issue_info##*:}
      [[ "$state" == "closed" ]] && reopen_issue "$num"
    fi
  done
fi

###############################################################################
# 2. TFLint                                                                   #
###############################################################################
echo "▶️ TFLint scanning"
tflint --format json "$WORKDIR" > /tmp/tflint.json || true

if [[ -s /tmp/tflint.json ]]; then
  jq -c '.diagnostics[]?' /tmp/tflint.json 2>/dev/null | \
  while read -r diag; do
    rule=$(echo "$diag" | jq -r .rule_name)
    msg=$(echo  "$diag" | jq -r .message)
    title="tflint: $rule - $msg"
    body="\`\`\`json\n${diag}\n\`\`\`"

    mark_problem
    issue_info=$(find_issue "$title")
    if [[ -z "$issue_info" ]]; then
      create_issue "$title" "$body" "terraform-security"
    else
      num=${issue_info%%:*}; state=${issue_info##*:}
      [[ "$state" == "closed" ]] && reopen_issue "$num"
    fi
  done
fi

###############################################################################
# 3. Trivy Config                                                             #
###############################################################################
echo "▶️ Trivy config scanning"
trivy config --quiet --format json -o /tmp/trivy_tf.json "$WORKDIR" || true

if [[ -s /tmp/trivy_tf.json ]]; then
  jq -c '.Results[]?.Misconfigurations[]?' /tmp/trivy_tf.json 2>/dev/null | \
  while read -r mis; do
    id=$(echo "$mis" | jq -r .ID)
    title="Trivy Terraform: $id"
    body="\`\`\`json\n${mis}\n\`\`\`"

    mark_problem
    issue_info=$(find_issue "$title")
    if [[ -z "$issue_info" ]]; then
      create_issue "$title" "$body" "terraform-security"
    else
      num=${issue_info%%:*}; state=${issue_info##*:}
      [[ "$state" == "closed" ]] && reopen_issue "$num"
    fi
  done
fi

exit 0 
