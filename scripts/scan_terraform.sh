#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"

if ! find "$WORKDIR" -name '*.tf' -print -quit | grep -q .; then
  echo "Nenhum arquivo .tf encontrado - pulando verificações Terraform"
  exit 0
fi

echo "=== 1) Terrascan ==="
set +e
terrascan scan \
  -i terraform \
  -t aws \
  --iac-dir "$WORKDIR" \
  -o json > /tmp/terrascan.json
ts_exit=$?
set -e

if [[ $ts_exit -ne 0 && $ts_exit -ne 3 && $ts_exit -ne 4 && $ts_exit -ne 5 ]]; then
  echo "::error:: Terrascan falhou com código $ts_exit"
  exit 1
fi

if [[ ! -s /tmp/terrascan.json ]]; then
  echo "::error:: Terrascan não gerou /tmp/terrascan.json"
  exit 1
fi

jq -c '.results.violations[]?' /tmp/terrascan.json | while read -r vio; do
  rule=$(jq -r .rule_name <<<"$vio")
  title="Terrascan: $rule"
  mark_problem
  issue_info=$(find_issue "$title" || true)
  if [[ -z "$issue_info" ]]; then
    create_issue "$title" "```json\n$vio\n```" "terraform-security"
  else
    num=${issue_info%%:*}
    state=${issue_info##*:}
    if [[ "$state" == "closed" ]]; then
      reopen_issue "$num"
    fi
  fi
done || true

echo "=== 2) Trivy Config (Terraform only) ==="
trivy config \
  --format json \
  --severity MEDIUM,HIGH,CRITICAL \
  --skip-files Dockerfile \
  -o /tmp/trivy_tf.json \
  "$WORKDIR" || true

if [[ -s /tmp/trivy_tf.json ]]; then
  mis_count=$(jq '[(.Results // [])[]?.Misconfigurations[]?] | length' /tmp/trivy_tf.json 2>/dev/null || echo 0)
  if (( mis_count > 0 )); then
    jq -c '(.Results // [])[]?.Misconfigurations[]?' /tmp/trivy_tf.json | while read -r mis; do
      id=$(jq -r .ID <<<"$mis")
      title="Trivy Terraform: $id"
      mark_problem
      issue_info=$(find_issue "$title" || true)
      if [[ -z "$issue_info" ]]; then
        create_issue "$title" "```json\n$mis\n```" "terraform-security"
      else
        num=${issue_info%%:*}
        state=${issue_info##*:}
        [[ "$state" == "closed" ]] && reopen_issue "$num"
      fi
    done
  else
    echo "::warning:: nenhum problema de configuração HIGH/CRITICAL encontrado no Terraform"
  fi
else
  echo "::warning:: Trivy config não gerou /tmp/trivy_tf.json"
fi
