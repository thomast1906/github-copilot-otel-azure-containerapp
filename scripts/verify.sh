#!/usr/bin/env bash
set -euo pipefail

: "${POC_FQDN:?Set POC_FQDN to the Container App hostname.}"
: "${POC_TOKEN:?Set POC_TOKEN to the token generated during deployment.}"

endpoint="https://${POC_FQDN}/v1/traces"
payload='{"resourceSpans":[]}'

printf 'Unauthenticated check (expected HTTP 401):\n'
curl --silent --show-error --output /dev/null --write-out 'HTTP %{http_code}\n' \
  --header 'Content-Type: application/json' \
  --data "$payload" \
  "$endpoint"

printf 'Authenticated check (expected HTTP 200):\n'
curl --silent --show-error --output /dev/null --write-out 'HTTP %{http_code}\n' \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${POC_TOKEN}" \
  --data "$payload" \
  "$endpoint"
