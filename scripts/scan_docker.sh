#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"
CTX="${DOCKER_CONTEXT:-.}"

#####################
# 1. Hadolint Scan  #
#####################
if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "▶️ Hadolint scanning Dockerfile"
  hadolint -f json "${WORKDIR}/Dockerfile" > /tmp/hadolint.json || true
  jq -c '.[]' /tmp/hadolint.json | while read -r finding; do
    code=$(echo "$finding" | jq -r .code)
    msg=$(echo "$finding" | jq -r .message)
    title="Hadolint [$code] $msg"
    body="\`\`\`json\n${finding}\n\`\`\`"
    if ! issue_exists "$title"; then
      create_issue "$title" "$body" "lint"
    fi
  done
else
  echo "Nenhum Dockerfile encontrado - pulando Hadolint"
fi

####################################
# 2. Build + Trivy + Docker Scout  #
####################################
if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  image="local-scan:${GITHUB_SHA::7}"
  echo "▶️ Construindo imagem $image"
  if ! docker buildx inspect devops-linter >/dev/null 2>&1; then
  docker buildx create --name devops-linter --driver docker-container --use
  fi
  docker buildx build --load -t "$image" "$CTX"

  echo "▶️ Trivy image scan"
  trivy image --quiet --format json -o /tmp/trivy_image.json "$image" || true
  jq -c '.Results[]?.Vulnerabilities[]?' /tmp/trivy_image.json | while read -r vul; do
    id=$(echo "$vul" | jq -r .VulnerabilityID)
    pkg=$(echo "$vul" | jq -r .PkgName)
    sev=$(echo "$vul" | jq -r .Severity)
    title="Trivy: $id in $pkg ($sev)"
    if ! issue_exists "$title"; then
      create_issue "$title" "\`\`\`json\n${vul}\n\`\`\`" "docker-security"
    fi
  done

  echo "▶️ Docker Scout quickview"
  docker scout quickview "$image" --format json > /tmp/scout.json || true
  jq -c '.vulnerabilities[]?' /tmp/scout.json | while read -r vul; do
    id=$(echo "$vul" | jq -r .cve)
    sev=$(echo "$vul" | jq -r .severity)
    title="Docker Scout: $id ($sev)"
    if ! issue_exists "$title"; then
      create_issue "$title" "\`\`\`json\n${vul}\n\`\`\`" "docker-security"
    fi
  done
fi
