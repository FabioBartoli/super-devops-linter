#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"
CTX="${BUILD_CONTEXT:-.}"
image="imagem-verificada"

if [[ -f "$WORKDIR/Dockerfile" ]]; then

  echo "=== 1) Hadolint ==="
  set +e
  hadolint -f json "$WORKDIR/Dockerfile" > /tmp/hadolint.json
  HL_EXIT=$?
  set -e
  cat /tmp/hadolint.json || echo "(empty or missing)"
  
  if jq -e '.[0]?' /tmp/hadolint.json >/dev/null 2>&1; then
    set +e
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
        if [[ "$state" == "closed" ]]; then
          reopen_issue "$num"
        fi
      fi
    done
    set -e
  fi

  echo "=== 2) Build ==="
  docker build -t "$image" "$CTX"

  echo "=== 3) Trivy image (HIGH,CRITICAL) ==="
  trivy image "$image" \
    --severity HIGH,CRITICAL \
    --format json \
    --output /tmp/trivy_image.json || true

  if [[ -s /tmp/trivy_image.json ]] && jq -e '[.Results[].Vulnerabilities[]?] | length > 0' /tmp/trivy_image.json >/dev/null 2>&1; then
    jq -c '.Results[].Vulnerabilities[]?' /tmp/trivy_image.json | while read -r vuln; do
      id=$(jq -r .VulnerabilityID <<<"$vuln")
      pkg=$(jq -r .PkgName           <<<"$vuln")
      sev=$(jq -r .Severity          <<<"$vuln")
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
  fi

else
  echo "Nenhum Dockerfile encontrado — pulando verificações Docker"
fi
