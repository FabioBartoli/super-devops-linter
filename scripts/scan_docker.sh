#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"
CTX="${BUILD_CONTEXT:-.}"
image="local-scan:${GITHUB_SHA::7}"

# --- DEBUG INICIAL ---
echo "▶️ INFO: usuário=$(whoami) Docker Server Version=$(docker version --format '{{.Server.Version}}')"
echo "▶️ INFO: context=$CTX, image tag=$image"

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
    body="\`\`\`json\n${finding}\n\`\`\`"
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
  echo "ℹ️ Nenhum Dockerfile encontrado - pulando Hadolint"
fi

################## 2. Build + Trivy + Scout ########################
build_failed=false

if [[ -f "${WORKDIR}/Dockerfile" ]]; then
  echo "▶️ Construindo imagem $image via buildx"
  if ! docker buildx build --load -t "$image" "$CTX"; then
    echo "::warning:: Buildx falhou — tentando docker build clássico"
    if ! DOCKER_BUILDKIT=0 docker build -t "$image" "$CTX"; then
      echo "::error:: Falha total no build"
      build_failed=true
    fi
  fi

  # --- DEBUG: lista de imagens locais após o build ---
  echo "---- docker images grep $image ----"
  docker images | grep "$image" || echo "⚠️ Imagem $image não encontrada"
  echo "------------------------------------"

  if [[ "$build_failed" == false && -n "$(docker images -q "$image")" ]]; then
    # --- Trivy ---
    echo "▶️ Trivy image scan"
    trivy image --quiet --format json -o /tmp/trivy_image.json "$image" || true

    # DEBUG Trivy
    if [[ -s /tmp/trivy_image.json ]]; then
      echo "---- Trivy raw (head) ----"
      head -n 30 /tmp/trivy_image.json || true
      echo "--------------------------"
      trivy_cnt=$(jq '[.Results[]?.Vulnerabilities[]?] | length' /tmp/trivy_image.json 2>/dev/null || echo 0)
      echo "▶️ Trivy vulnerabilities count: $trivy_cnt"
    else
      echo "::warning:: Trivy não gerou /tmp/trivy_image.json"
    fi

    jq -c '.Results[]?.Vulnerabilities[]?' /tmp/trivy_image.json | while read -r vul; do
      id=$(echo "$vul" | jq -r .VulnerabilityID)
      pkg=$(echo "$vul" | jq -r .PkgName)
      sev=$(echo "$vul" | jq -r .Severity)
      title="Trivy Docker: $id in $pkg ($sev)"
      mark_problem
      body="\`\`\`json\n${vul}\n\`\`\`"
      issue_info=$(find_issue "$title" || true)
      if [[ -z "$issue_info" ]]; then
        create_issue "$title" "$body" "docker-security"
      else
        issue_no=${issue_info%%:*}
        issue_state=${issue_info##*:}
        [[ "$issue_state" == "closed" ]] && reopen_issue "$issue_no"
      fi
    done || true

    # --- Docker Scout ---
    echo "▶️ Docker Scout CVEs scan"
    docker scout cves "$image" --format sarif > /tmp/scout.json || true

    # DEBUG Scout
    if [[ -s /tmp/scout.json ]]; then
      echo "---- Scout raw (head) ----"
      head -n 30 /tmp/scout.json || true
      echo "--------------------------"
      scout_cnt=$(jq '[.runs[].results[]?] | length' /tmp/scout.json 2>/dev/null || echo 0)
      echo "▶️ Scout findings count: $scout_cnt"
    else
      echo "::warning:: Scout não gerou /tmp/scout.json"
    fi

    jq -c '.runs[].results[]?' /tmp/scout.json | while read -r vul; do
      id=$(echo "$vul" | jq -r .ruleId)
      sev=$(echo "$vul" | jq -r '.properties.severity // "unknown"')
      title="Docker Scout: $id ($sev)"
      mark_problem
      issue_info=$(find_issue "$title" || true)
      if [[ -z "$issue_info" ]]; then
        create_issue "$title" "\`\`\`json\n${vul}\n\`\`\`" "docker-security"
      else
        issue_no=${issue_info%%:*}
        issue_state=${issue_info##*:}
        [[ "$issue_state" == "closed" ]] && reopen_issue "$issue_no"
      fi
    done || true

  else
    echo "::warning:: Imagem $image não disponível ou build falhou — pulando Trivy e Scout"
  fi

else
  echo "ℹ️ Dockerfile não encontrado - pulando Docker scan"
fi
