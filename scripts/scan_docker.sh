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
  cat /tmp/hadolint.json || echo "(empty or missing)"
  
  echo "DEBUG: vérificando se é array JSON com ao menos um elemento"
  if jq -e '.[0]?' /tmp/hadolint.json >/dev/null 2>&1; then
    echo "DEBUG: encontrado array de issues, entrando no loop…"
    # permite continuar mesmo que um comando interno falhe
    set +e
    jq -c '.[]' /tmp/hadolint.json | while read -r finding; do
      echo "DEBUG: raw finding = $finding"
      code=$(jq -r .code    <<<"$finding"); echo "DEBUG: code = $code"
      msg=$(jq -r .message <<<"$finding"); echo "DEBUG: message = $msg"
      title="Hadolint [$code] $msg"
      echo "DEBUG: title = $title"

      echo "DEBUG: marcando problema em context"
      mark_problem || echo "DEBUG: mark_problem falhou (mas continuo)"

      body=$(printf '```json\n%s\n```' "$finding")
      echo "DEBUG: body preparado"

      echo "DEBUG: tentando find_issue"
      issue_info=$(find_issue "$title" || true)
      echo "DEBUG: issue_info = '$issue_info'"

      if [[ -z "$issue_info" ]]; then
        echo "DEBUG: criará nova issue Hadolint"
        create_issue "$title" "$body" "lint" || echo "DEBUG: create_issue falhou"
      else
        num=${issue_info%%:*}
        state=${issue_info##*:}
        echo "DEBUG: issue existente #$num estado=$state"
        if [[ "$state" == "closed" ]]; then
          echo "DEBUG: reabrindo issue #$num"
          reopen_issue "$num" || echo "DEBUG: reopen_issue falhou"
        fi
      fi

      echo "DEBUG: --- fim de iteração ---"
    done
    # volta a abortar no primeiro erro
    set -e
  else
    echo "DEBUG: não há issues Hadolint (ou JSON mal formado)"
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
  cat /tmp/trivy_image.json || echo "(empty or missing)"

  if [[ -s /tmp/trivy_image.json ]] && jq -e '[.Results[].Vulnerabilities[]?] | length > 0' /tmp/trivy_image.json >/dev/null 2>&1; then
    echo "DEBUG: existem vulnerabilidades HIGH/CRITICAL, processando..."
    jq -c '.Results[].Vulnerabilities[] | select(.Severity=="HIGH" or .Severity=="CRITICAL")' /tmp/trivy_image.json \
    | while read -r vuln; do
        echo "DEBUG: raw vuln = $vuln"
        id=$(jq -r .VulnerabilityID <<<"$vuln")
        pkg=$(jq -r .PkgName           <<<"$vuln")
        sev=$(jq -r .Severity          <<<"$vuln")
        title="Trivy Docker: $id in $pkg ($sev)"
        echo "DEBUG: title = $title"
        mark_problem || echo "DEBUG: mark_problem falhou"
        body=$(printf '```json\n%s\n```' "$vuln")
        issue_info=$(find_issue "$title" || true)
        if [[ -z "$issue_info" ]]; then
          create_issue "$title" "$body" "docker-security" \
            || echo "DEBUG: create_issue falhou para Trivy"
        else
          num=${issue_info%%:*}
          state=${issue_info##*:}
          [[ "$state" == "closed" ]] && reopen_issue "$num" \
            || echo "DEBUG: reopen_issue falhou para Trivy"
        fi
      done
  else
    echo "::warning:: sem vulnerabilidades HIGH/CRITICAL encontradas pelo Trivy"
  fi

else
  echo "Nenhum Dockerfile encontrado — pulando verificações Docker"
fi
