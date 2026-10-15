#!/usr/bin/env bash
set -euo pipefail

POC_RG="${POC_RG:-rg-copilot-otel-poc}"
POC_APP="${POC_APP:-ca-copilot-otel-poc}"

az containerapp logs show \
  --name "$POC_APP" \
  --resource-group "$POC_RG" \
  --type console \
  --tail "${TAIL:-100}"
