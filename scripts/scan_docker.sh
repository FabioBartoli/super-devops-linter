#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"
CTX="${BUILD_CONTEXT:-.}"
image="imagem-verificada"

if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "Linting Dockerfile with Hadolint..."
  hadolint -f json "${WORKDIR}/Dockerfile" > /tmp/hadolint.json || true

  if jq -e 'length > 0' /tmp/hadolint.json >/dev/null 2>&1; then
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
    echo "No Hadolint issues found."
  fi

  echo "Building image '$image'..."
  docker build -t "$image" "$CTX"

  echo "Scanning image with Trivy (HIGH,CRITICAL)..."
  trivy image \
    --format json \
    --severity HIGH,CRITICAL \
    --skip-update \
    --exit-code 0 \
    --output /tmp/trivy_image.json \
    "$image" || true
  if [[ -s /tmp/trivy_image.json ]] && jq -e '.Results[].Vulnerabilities | length > 0' /tmp/trivy_image.json >/dev/null 2>&1; then
    vuln_count=$(jq '[.Results[].Vulnerabilities[]?] | length' /tmp/trivy_image.json)
    echo "Trivy Docker vulnerabilities count: $vuln_count"

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
    echo "::warning:: Trivy image scan did not produce any HIGH/CRITICAL vulnerabilities"
  fi
else
  echo "Nenhum Dockerfile encontrado — pulando verificações Docker"
fi
