#!/usr/bin/env bash
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/helpers.sh"

WORKDIR="$GITHUB_WORKSPACE"

echo "=== DEBUG: Iniciando verificação Terraform ==="

echo "DEBUG: Verificando se existem arquivos .tf em '$WORKDIR'..."
if ! find "$WORKDIR" -name '*.tf' -print -quit | grep -q .; then
  echo "Nenhum arquivo .tf encontrado - pulando verificações Terraform"
  exit 0
fi

echo "=== 1) Terrascan ==="
echo "DEBUG: Executando terrascan scan..."
set +e
terrascan scan \
  -i terraform \
  -t aws \
  --iac-dir "$WORKDIR" \
  -o json > /tmp/terrascan.json
ts_exit=$?
set -e
echo "DEBUG: terrascan exit code = $ts_exit"

echo "DEBUG: Conteúdo de /tmp/terrascan.json:"
if [[ -s /tmp/terrascan.json ]]; then
  cat /tmp/terrascan.json
else
  echo "(vazio ou não existe)"
fi

echo "DEBUG: Validando código de saída do Terrascan..."
if [[ $ts_exit -ne 0 && $ts_exit -ne 3 && $ts_exit -ne 4 && $ts_exit -ne 5 ]]; then
  echo "::error:: Terrascan falhou com código $ts_exit"
  exit 1
fi

echo "DEBUG: Checando se /tmp/terrascan.json foi gerado e não está vazio..."
if [[ ! -s /tmp/terrascan.json ]]; then
  echo "::error:: Terrascan não gerou /tmp/terrascan.json"
  exit 1
fi

echo "DEBUG: Contando violações em terrascan.json..."
vio_count=$(jq '.results.violations | length' /tmp/terrascan.json 2>/dev/null || echo 0)
echo "DEBUG: encontrado $vio_count violações"

echo "DEBUG: Processando cada violação..."
set +e
jq -c '.results.violations[]?' /tmp/terrascan.json | while read -r vio; do
  echo "DEBUG: raw violation = $vio"
  rule=$(jq -r .rule_name <<<"$vio")
  echo "DEBUG: regra extraída = $rule"
  title="Terrascan: $rule"
  echo "DEBUG: título = $title"
  mark_problem || echo "DEBUG: mark_problem falhou"
  issue_info=$(find_issue "$title" || true)
  echo "DEBUG: issue_info = '$issue_info'"
  if [[ -z "$issue_info" ]]; then
    echo "DEBUG: criando nova issue Terrascan"
    create_issue "$title" "```json\n$vio\n```" "terraform-security" \
      || echo "DEBUG: create_issue falhou"
  else
    num=${issue_info%%:*}
    state=${issue_info##*:}
    echo "DEBUG: issue existente #$num estado=$state"
    if [[ "$state" == "closed" ]]; then
      echo "DEBUG: reabrindo issue #$num"
      reopen_issue "$num" || echo "DEBUG: reopen_issue falhou"
    fi
  fi
  echo "DEBUG: ---- fim iteração ----"
done
set -e

echo "=== 2) Trivy Config (Terraform only) ==="
echo "DEBUG: Executando trivy config..."
trivy config \
  --format json \
  --severity HIGH,CRITICAL \
  --skip-files Dockerfile \
  -o /tmp/trivy_tf.json \
  "$WORKDIR" || true

echo "DEBUG: Conteúdo de /tmp/trivy_tf.json:"
if [[ -s /tmp/trivy_tf.json ]]; then
  cat /tmp/trivy_tf.json
else
  echo "(vazio ou não existe)"
fi

echo "DEBUG: Contando misconfigurações em trivy_tf.json..."
mis_count=$(jq '[(.Results // [])[]?.Misconfigurations[]?] | length' /tmp/trivy_tf.json 2>/dev/null || echo 0)
echo "DEBUG: encontrado $mis_count misconfigurações"

if (( mis_count > 0 )); then
  echo "DEBUG: Processando cada misconfiguração..."
  set +e
  jq -c '(.Results // [])[]?.Misconfigurations[]?' /tmp/trivy_tf.json | while read -r mis; do
    echo "DEBUG: raw misconfiguration = $mis"
    id=$(jq -r .ID <<<"$mis")
    echo "DEBUG: ID = $id"
    title="Trivy Terraform: $id"
    echo "DEBUG: título = $title"
    mark_problem || echo "DEBUG: mark_problem falhou"
    issue_info=$(find_issue "$title" || true)
    echo "DEBUG: issue_info = '$issue_info'"
    if [[ -z "$issue_info" ]]; then
      echo "DEBUG: criando nova issue Trivy Terraform"
      create_issue "$title" "```json\n$mis\n```" "terraform-security" \
        || echo "DEBUG: create_issue falhou"
    else
      num=${issue_info%%:*}
      state=${issue_info##*:}
      echo "DEBUG: issue existente #$num estado=$state"
      if [[ "$state" == "closed" ]]; then
        echo "DEBUG: reabrindo issue #$num"
        reopen_issue "$num" || echo "DEBUG: reopen_issue falhou"
      fi
    fi
    echo "DEBUG: ---- fim iteração ----"
  done
  set -e
else
  echo "::warning:: Trivy config não gerou /tmp/trivy_tf.json ou não encontrou misconfigurações"
fi

echo "=== DEBUG: Fim das verificações Terraform ==="
