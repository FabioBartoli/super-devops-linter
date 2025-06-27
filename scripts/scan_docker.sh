#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"
CTX="${BUILD_CONTEXT:-.}"
image="imagem-verificada"

if [[ -f "$WORKDIR/Dockerfile" ]]; then

  echo "=== 1) Hadolint ==="
  hadolint -f json "$WORKDIR/Dockerfile" > /tmp/hadolint.json || true
  HL_EXIT=$?
  echo "DEBUG: hadolint exit code = $HL_EXIT"
  echo "DEBUG: content of /tmp/hadolint.json:"
  cat /tmp/hadolint.json || echo "(arquivo vazio ou não existe)"

  echo "DEBUG: testando se é um array JSON com pelo menos um elemento"
  if jq -e '.[0]?' /tmp/hadolint.json >/dev/null 2>&1; then
    echo "DEBUG: parece conter issues, processando…"
    jq -c '.[]' /tmp/hadolint.json | while read -r finding; do
      code=$(jq -r .code    <<<"$finding")
      msg=$(jq -r .message <<<"$finding")
      title="Hadolint [$code] $msg"
      mark_problem
      body=$(printf '```json\n%s\n```' "$finding")
      issue_info=$(find_issue "$title" || true)
      if [[ -z "$issue_info" ]]; then
        create_issue "$title" "$body" "lint"
      else
        num=${issue_info%%:*}
        state=${issue_info##*:}
        [[ "$state" == "closed" ]] && reopen_issue "$num"
      fi
    done
  else
    echo "DEBUG: não há issues Hadolint (ou JSON malformado)"
  fi


  echo "=== 2) Build ==="
  docker build -t "$image" "$CTX"


  echo "=== 3) Trivy image (HIGH,CRITICAL) ==="
  trivy image \
    --format json \
    --severity HIGH,CRITICAL \
    --skip-update \
    --exit-code 0 \
    --output /tmp/trivy_image.json \
    "$image" || true
  TI_EXIT=$?
  echo "DEBUG: trivy exit code = $TI_EXIT"
  echo "DEBUG: content of /tmp/trivy_image.json:"
  cat /tmp/trivy_image.json || echo "(arquivo vazio ou não existe)"

  if [[ -s /tmp/trivy_image.json ]]; then
    VULN_COUNT=$(jq '[.Results[].Vulnerabilities[]?] | length' /tmp/trivy_image.json)
    echo "DEBUG: total de vulnerabilidades (todos níveis) = $VULN_COUNT"
    if (( VULN_COUNT > 0 )); then
      jq -c '.Results[].Vulnerabilities[] | select(.Severity=="HIGH" or .Severity=="CRITICAL")' /tmp/trivy_image.json \
      | while read -r vuln; do
          id=$(jq -r .VulnerabilityID <<<"$vuln")
          pkg=$(jq -r .PkgName            <<<"$vuln")
          sev=$(jq -r .Severity           <<<"$vuln")
          title="Trivy Docker: $id in $pkg ($sev)"
          mark_problem
          body=$(printf '```json\n%s\n```' "$vuln")
          issue_info=$(find_issue "$title" || true)
          if [[ -z "$issue_info" ]]; then
            create_issue "$title" "$body" "docker-security"
          else
            num=${issue_info%%:*}
            state=${issue_info##*:}
            [[ "$state" == "closed" ]] && reopen_issue "$num"
          fi
        done
    else
      echo "DEBUG: sem vulnerabilidades HIGH/CRITICAL"
    fi
  else
    echo "::warning:: Trivy image scan não gerou /tmp/trivy_image.json"
  fi

else
  echo "Nenhum Dockerfile encontrado — pulando verificações Docker"
fi
