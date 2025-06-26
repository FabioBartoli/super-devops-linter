#!/usr/bin/env bash
set -euo pipefail

REPO="${GITHUB_REPOSITORY}"
API_ROOT="https://api.github.com/repos/${REPO}"
AUTH="Authorization: Bearer ${GITHUB_TOKEN}"

# Cria label se não existir
ensure_label() {
  local label="$1" color="$2"
  curl -s -H "$AUTH" "${API_ROOT}/labels" | jq -e ".[] | select(.name==\"${label}\")" > /dev/null || \
  curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
       -d "{\"name\":\"${label}\",\"color\":\"${color}\"}" \
       "${API_ROOT}/labels" >/dev/null
}

# Verifica se título já existe
issue_exists() {
  local title="$1"
  local count
  count=$(curl -s -H "$AUTH" "${API_ROOT}/issues?state=all&per_page=100" | \
          jq "[.[] | select(.title==\"${title}\")] | length")
  [[ "$count" -gt 0 ]]
}

mark_problem() {
  touch "$GITHUB_WORKSPACE/problems_found.flag"
}

# Cria issue
create_issue() {
  local title="$1" body="$2" label="$3"
  ensure_label "$label" "f14aad"
  jq -n --arg t "$title" --arg b "$body" --argjson lbls "[\"$label\"]" \
     '{title:$t,body:$b,labels:$lbls}' \
     | curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
            -d @- "${API_ROOT}/issues" >/dev/null
  # marca para falhar no passo final
  touch "$GITHUB_WORKSPACE/issues_found.flag"
}
