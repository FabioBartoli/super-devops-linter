#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"

if ! find "$WORKDIR" -name '*.tf' -print -quit | grep -q .; then
  echo "ℹ️ Nenhum arquivo .tf encontrado - pulando verificações Terraform"
  exit 0
fi

###################
# 1. tfsec        #
###################
echo "▶️ tfsec scanning"
tfsec --no-color --format json --out /tmp/tfsec.json "$WORKDIR" || true
jq -c '.results[]?' /tmp/tfsec.json | while read -r res; do
  rule=$(echo "$res" | jq -r .rule_id)
  title="tfsec: $rule"
  if ! issue_exists "$title"; then
    create_issue "$title" "\`\`\`json\n${res}\n\`\`\`" "terraform-security"
  fi
done

###################
# 2. Checkov      #
###################
echo "▶️ Checkov scanning"
checkov -d "$WORKDIR" -o json > /tmp/checkov.json || true

# novo parser – funciona com 2.x e 3.x
jq -c '
  (
    if type=="array"
      then .[]                # Formato 3.x (array)
      else .results.failed_checks[]?   # Formato 2.x (objeto)
    end
  ) | select(.check_result.result=="FAILED")
' /tmp/checkov.json | while read -r res; do
  id=$(echo "$res" | jq -r .check_id)
  title="Checkov: $id"
  if ! issue_exists "$title"; then
    create_issue "$title" "\`\`\`json\n${res}\n\`\`\`" "terraform-security"
  fi
done


###################
# 3. Trivy Config #
###################
echo "▶️ Trivy config scanning"
trivy config --quiet --format json -o /tmp/trivy_tf.json "$WORKDIR" || true
jq -c '.Results[]?.Misconfigurations[]?' /tmp/trivy_tf.json | while read -r mis; do
  id=$(echo "$mis" | jq -r .ID)
  title="Trivy: $id"
  if ! issue_exists "$title"; then
    create_issue "$title" "\`\`\`json\n${mis}\n\`\`\`" "terraform-security"
  fi
done
