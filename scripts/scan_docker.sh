#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"
CTX="${BUILD_CONTEXT:-.}"
unset DOCKER_CONTEXT 
image="local-scan:${GITHUB_SHA::7}"

######## Contexto e Builder ########################################
# garante docker context 'default'
docker context inspect default >/dev/null 2>&1 || \
  docker context create default --docker host=unix:///var/run/docker.sock
docker context use default

# garante builder 'devops-linter'
if ! docker buildx inspect devops-linter >/dev/null 2>&1; then
  docker buildx create --name devops-linter --driver docker-container \
                       --use --bootstrap --platform linux/amd64
else
  docker buildx use devops-linter
fi
####################################################################

################## 1. Hadolint #####################################
if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "▶️ Hadolint scanning Dockerfile"
  hadolint -f json "${WORKDIR}/Dockerfile" > /tmp/hadolint.json || true
  jq -c '.[]' /tmp/hadolint.json | while read -r finding; do
    code=$(echo "$finding" | jq -r .code)
    msg=$(echo "$finding" | jq -r .message)
    title="Hadolint [$code] $msg"
    mark_problem
    body="\`\`\`json\n${finding}\n\`\`\`"
    if ! issue_exists "$title"; then
      create_issue "$title" "$body" "lint"
    fi
  done
else
  echo "Nenhum Dockerfile encontrado - pulando Hadolint"
fi

################## 2. Build + Trivy + Scout ########################
if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "▶️ Construindo imagem $image"
  if ! docker buildx build --load -t "$image" "$CTX"; then
    echo "::warning:: Buildx falhou — tentando docker build clássico"
    DOCKER_BUILDKIT=0 docker build -t "$image" "$CTX" || \
      { echo "::error:: Falha total no build"; exit 0; }
  fi

  # --- Trivy ---
  echo "▶️ Trivy image scan"
  trivy image --quiet --format json -o /tmp/trivy_image.json "$image" || true
  jq -c '.Results[]?.Vulnerabilities[]?' /tmp/trivy_image.json | while read -r vul; do
    id=$(echo "$vul" | jq -r .VulnerabilityID)
    pkg=$(echo "$vul" | jq -r .PkgName)
    sev=$(echo "$vul" | jq -r .Severity)
    title="Trivy: $id in $pkg ($sev)"
    mark_problem
    if ! issue_exists "$title"; then
      create_issue "$title" "\`\`\`json\n${vul}\n\`\`\`" "docker-security"
    fi
  done

  # --- Docker Scout ---
  echo "▶️ Docker Scout quickview"
  docker scout quickview "$image" --format json > /tmp/scout.json || true
  jq -c '.vulnerabilities[]?' /tmp/scout.json | while read -r vul; do
    id=$(echo "$vul" | jq -r .cve)
    sev=$(echo "$vul" | jq -r .severity)
    title="Docker Scout: $id ($sev)"
    mark_problem
    if ! issue_exists "$title"; then
      create_issue "$title" "\`\`\`json\n${vul}\n\`\`\`" "docker-security"
    fi
  done
fi