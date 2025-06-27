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
  touch "$GITHUB_WORKSPACE/issues_found.flag"
}

find_issue() {
  local title="$1" page=1
  while :; do
    local page_json match
    page_json=$(curl -s -H "$AUTH" \
      "${API_ROOT}/issues?state=all&per_page=100&page=${page}")
    match=$(jq -r --arg t "$title" '.[] | select(.title==$t) | "\(.number):\(.state)"' <<<"$page_json" | head -n1)
    [[ -n "$match" ]] && { echo "$match"; return 0; }
    [[ "$(jq length <<<"$page_json" 2>/dev/null || true)" == "0" ]] && break   # página vazia
    ((page++))
  done
  return 1
}

# Reabre issue fechada
reopen_issue() {
  local number="$1"
  curl -s -X PATCH -H "$AUTH" -H "Content-Type: application/json" \
       -d '{"state":"open"}' \
       "${API_ROOT}/issues/${number}" >/dev/null
}

