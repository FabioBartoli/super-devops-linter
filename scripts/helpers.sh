#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Constantes                                                                    #
################################################################################
REPO="${GITHUB_REPOSITORY}"
API_ROOT="https://api.github.com/repos/${REPO}"

AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
JSON_HEADER="Content-Type: application/json"
HDRS=(-H "$AUTH_HEADER" -H "$JSON_HEADER")

################################################################################
# Labels                                                                        #
################################################################################
# $1 = nome  $2 = cor (hex sem #)
ensure_label() {
  local label="$1" color="$2"
  curl -s "${HDRS[@]}" "${API_ROOT}/labels" \
  | jq -e --arg l "$label" '.[] | select(.name==$l)' >/dev/null || \
  curl -s -X POST "${HDRS[@]}" \
       -d "{\"name\":\"${label}\",\"color\":\"${color}\"}" \
       "${API_ROOT}/labels" >/dev/null
}

################################################################################
# Issues                                                                        #
################################################################################
# Procura issue por título — retorna "num:state" (ex.: "42:closed") ou vazio
find_issue() {               # $1 = title
  curl -s "${HDRS[@]}" "${API_ROOT}/issues?state=all&per_page=100" \
  | jq -r --arg t "$1" '.[] | select(.title==$t) | "\(.number):\(.state)"' \
  | head -n1
}

# Retorna 0 se a issue (aberta ou fechada) existe
issue_exists() {             # $1 = title
  [[ -n "$(find_issue "$1")" ]]
}

# Reabre issue fechada
reopen_issue() {             # $1 = número
  jq -n --arg s "open" '{state:$s}' \
  | curl -s -X PATCH "${HDRS[@]}" -d @- "${API_ROOT}/issues/$1" >/dev/null
}

# Cria nova issue com label
create_issue() {             # $1=title $2=body $3=label
  ensure_label "$3" "f14aad"
  jq -n --arg t "$1" --arg b "$2" --arg l "$3" \
     '{title:$t,body:$b,labels:[$l]}' \
  | curl -s -X POST "${HDRS[@]}" -d @- "${API_ROOT}/issues" >/dev/null
  touch "$GITHUB_WORKSPACE/issues_found.flag"
}

################################################################################
# Flags de controle                                                             #
################################################################################
# Marca que achamos algum problema (mesmo que já exista issue)
mark_problem() { 
  touch "$GITHUB_WORKSPACE/problems_found.flag"; 
}
