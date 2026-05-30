#!/usr/bin/env bash
set -euo pipefail

PROXY_URL="${LLM_PROXY_URL:-__PROXY_URL__}"
API_KEY="${1:-${PROVIDER_API_KEY:-}}"

if [[ -z "$API_KEY" ]]; then
  echo "usage: $0 <proxy-api-key>" >&2
  exit 1
fi

curl -fsSL -H "Authorization: Bearer $API_KEY" "$PROXY_URL/setup/env"
