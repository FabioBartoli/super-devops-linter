#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"
CTX="${BUILD_CONTEXT:-.}"
image="imagem-verificada"

# 1. Hadolint
if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "Hadolint scanning Dockerfile"
  hadolint -f json "${WORKDIR}/Dockerfile" > /tmp/hadolint.json || true
  jq -c '.[]' /tmp/hadolint.json | while read -r finding; do
    code=$(jq -r .code <<<"$finding")
    msg=$(jq -r .message <<<"$finding")
    title="Hadolint [$code] $msg"
    mark_problem
    body="```json\n${finding}\n```"
    issue_info=$(find_issue "$title" || true)
    if [[ -z "$issue_info" ]]; then
      create_issue "$title" "$body" "lint"
    else
      no=${issue_info%%:*} state=${issue_info##*:}
      [[ "$state" == "closed" ]] && reopen_issue "$no"
    fi
  done || true
else
  echo "Nenhum Dockerfile encontrado – pulando Hadolint"
fi

# 2. Build + Trivy + Scout
if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "Construindo imagem $image"
  docker build -t "$image" "$CTX"

  # Trivy
  echo "Trivy image scan"
  trivy image --quiet --format json --severity HIGH,CRITICAL -o /tmp/trivy_image.json "$image" || true
  if [[ -s /tmp/trivy_image.json ]]; then
    jq -c '.Results[]?.Vulnerabilities[]?' /tmp/trivy_image.json | while read -r vul; do
      id=$(jq -r .VulnerabilityID <<<"$vul")
      pkg=$(jq -r .PkgName <<<"$vul")
      sev=$(jq -r .Severity <<<"$vul")
      title="Trivy Docker: $id in $pkg ($sev)"
      mark_problem
      body="```json\n${vul}\n```"
      issue_info=$(find_issue "$title" || true)
      if [[ -z "$issue_info" ]]; then
        create_issue "$title" "$body" "docker-security"
      else
        no=${issue_info%%:*} state=${issue_info##*:}
        [[ "$state" == "closed" ]] && reopen_issue "$no"
      fi
    done || true
  else
    echo "::warning:: Trivy image scan não gerou /tmp/trivy_image.json"
  fi

  # Docker Scout
  echo "Docker Scout CVEs scan"
  docker scout cves "$image" --format gitlab --only-severity high,critical > /tmp/scout.json || true
  if [[ -s /tmp/scout.json ]]; then
    jq -c '.vulnerabilities[]?' /tmp/scout.json | while read -r vul; do
      id=$(jq -r .id <<<"$vul")
      pkg=$(jq -r .location.dependency.package.name <<<"$vul")
      sev=$(jq -r .severity <<<"$vul")
      title="Docker Scout: $id in $pkg ($sev)"
      mark_problem
      body="```json\n${vul}\n```"
      issue_info=$(find_issue "$title" || true)
      if [[ -z "$issue_info" ]]; then
        create_issue "$title" "$body" "docker-security"
      else
        no=${issue_info%%:*} state=${issue_info##*:}
        [[ "$state" == "closed" ]] && reopen_issue "$no"
      fi
    done || true
  else
    echo "::warning:: Docker Scout não gerou /tmp/scout.json"
  fi
else
  echo "Nenhum Dockerfile encontrado – pulando scans de imagem"
fi
