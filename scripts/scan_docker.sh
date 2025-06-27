#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"
CTX="${BUILD_CONTEXT:-.}"
image="local-scan:${GITHUB_SHA::7}"

######## Contexto e Builder ########################################
docker context inspect default >/dev/null 2>&1 || \
  docker context create default --docker host=unix:///var/run/docker.sock
docker context use default

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
    body="```json\n${finding}\n```"
    issue_info=$(find_issue "$title" || true)
    if [[ -z "$issue_info" ]]; then
      create_issue "$title" "$body" "lint"
    else
      issue_no=${issue_info%%:*}
      issue_state=${issue_info##*:}
      [[ "$issue_state" == "closed" ]] && reopen_issue "$issue_no"
    fi
  done || true
else
  echo "Nenhum Dockerfile encontrado - pulando Hadolint"
fi

################## 2. Build + Trivy + Scout ########################
if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "Construindo imagem $image"
  if ! docker buildx build --load -t "$image" "$CTX"; then
    echo "::warning:: Buildx falhou — tentando docker build clássico"
    DOCKER_BUILDKIT=0 docker build -t "$image" "$CTX" || { echo "::error:: Falha total no build"; exit 0; }
  fi

  echo "Trivy image scan"
  trivy image --quiet --format json --severity HIGH,CRITICAL -o /tmp/trivy_image.json "$image" || true

  if [[ -s /tmp/trivy_image.json ]]; then
    jq -c '.Results[]?.Vulnerabilities[]?' /tmp/trivy_image.json | while read -r vul; do
      id=$(echo "$vul" | jq -r .VulnerabilityID)
      pkg=$(echo "$vul" | jq -r .PkgName)
      sev=$(echo "$vul" | jq -r .Severity)
      title="Trivy Docker: $id in $pkg ($sev)"
      mark_problem
      body="```json\n${vul}\n```"
      issue_info=$(find_issue "$title" || true)
      if [[ -z "$issue_info" ]]; then
        create_issue "$title" "$body" "docker-security"
      else
        issue_no=${issue_info%%:*}
        issue_state=${issue_info##*:}
        [[ "$issue_state" == "closed" ]] && reopen_issue "$issue_no"
      fi
    done || true
  else
    echo "::warning:: Trivy image scan não gerou /tmp/trivy_image.json"
  fi
fi

# --- Docker Scout ---
echo "▶️ Docker Scout CVEs scan"
docker scout cves "$image" --format sarif > /tmp/scout.json || true

# DEBUG Scout
if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "Docker Scout CVEs scan"
  docker scout cves "$image" --format gitlab --only-severity high,critical > /tmp/scout.json || true

  if [[ -s /tmp/scout.json ]]; then
    jq -c '.vulnerabilities[]?' /tmp/scout.json | while read -r vul; do
      id=$(echo "$vul" | jq -r .id)
      pkg=$(echo "$vul" | jq -r .location.dependency.package.name)
      sev=$(echo "$vul" | jq -r .severity)
      title="Docker Scout: $id in $pkg ($sev)"
      mark_problem
      body="```json\n${vul}\n```"
      issue_info=$(find_issue "$title" || true)
      if [[ -z "$issue_info" ]]; then
        create_issue "$title" "$body" "docker-security"
      else
        issue_no=${issue_info%%:*}
        issue_state=${issue_info##*:}
        [[ "$issue_state" == "closed" ]] && reopen_issue "$issue_no"
      fi
    done || true
  else
    echo "::warning:: Docker Scout não gerou /tmp/scout.json"
  fi
fi
