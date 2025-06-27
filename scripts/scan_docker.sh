#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"
CTX="${BUILD_CONTEXT:-.}"
image="imagem-verificada"

if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "Linting Dockerfile with Hadolint..."
  hadolint -f json "${WORKDIR}/Dockerfile" > /tmp/hadolint.json || true

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

  echo "Building image 'imagem-verificada'..."
  docker build -t imagem-verificada "$CTX"

  echo "Scanning image with Trivy (HIGH,CRITICAL)..."
  trivy image \
    --format json \
    --severity HIGH,CRITICAL \
    --skip-update \
    --exit-code 0 \
    -o /tmp/trivy_image.json \
    "$image" || true

  if [[ -s /tmp/trivy_image.json ]]; then 
    vuln_count=$(jq '[.Results[]?.Vulnerabilities[]?] | length' /tmp/trivy_image.json 2>/dev/null || echo 0)
    echo "Trivy Docker vulnerabilities count: $vuln_count"

    jq -c '.Results[]?.Vulnerabilities[]?' /tmp/trivy_image.json | while read -r vuln; do
      id=$(jq -r .VulnerabilityID <<<"$vuln")
      pkg=$(jq -r .PkgName            <<<"$vuln")
      sev=$(jq -r .Severity           <<<"$vuln")
      echo "Found $id in $pkg ($sev)"
      mark_problem
      body="```json\n$vuln\n```"
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
    echo "::warning:: Trivy image scan did not produce /tmp/trivy_image.json"
  fi

  echo "Scanning image with Docker Scout (only-packages, HIGH,CRITICAL)..."
  docker scout cves \
    --format only-packages \
    --only-vuln-packages \
    --only-severity high,critical \
    imagem-verificada \
    > /tmp/scout.json || true

  if [[ -s /tmp/scout.json ]]; then
    jq -c '.[]' /tmp/scout.json | while read -r vuln; do
      id=$(jq -r .package.name        <<<"$vuln")
      sev=$(jq -r .severity            <<<"$vuln")
      title="Docker Scout: $id ($sev)"
      mark_problem
      body="```json\n$vuln\n```"
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
    echo "::warning:: Docker Scout did not produce /tmp/scout.json"
  fi

else
  echo "Nenhum Dockerfile encontrado — pulando verificações Docker"
fi
