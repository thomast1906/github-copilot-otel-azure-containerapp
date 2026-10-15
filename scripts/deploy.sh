#!/usr/bin/env bash
set -euo pipefail

# Deploys the Collector, a workspace-based Application Insights component, and
# its Log Analytics workspace into one dedicated resource group.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

POC_RG="${POC_RG:-rg-copilot-otel-poc}"
POC_LOCATION="${POC_LOCATION:-uksouth}"
POC_ENV="${POC_ENV:-cae-copilot-otel-poc}"
POC_APP="${POC_APP:-ca-copilot-otel-poc}"
POC_LAW="${POC_LAW:-law-copilot-otel-poc}"
POC_APPINSIGHTS="${POC_APPINSIGHTS:-appi-copilot-otel-poc}"
# Use a pinned tag for a repeatable deployment. Change only after testing the
# desired Collector Contrib release in a non-production environment.
OTEL_COLLECTOR_IMAGE="${OTEL_COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.120.0}"

for command in az openssl; do
  command -v "$command" >/dev/null || {
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  }
done

if [[ ! -f otel-config.yaml ]]; then
  printf 'Run this script from the repository root (otel-config.yaml was not found).\n' >&2
  exit 1
fi

if ! az account show --output none 2>/dev/null; then
  az login
fi
az extension add --name containerapp --upgrade --only-show-errors

APP_EXISTS=false
if az containerapp show \
  --name "$POC_APP" --resource-group "$POC_RG" --output none 2>/dev/null; then
  APP_EXISTS=true
fi

if [[ "$APP_EXISTS" == "true" && -z "${POC_TOKEN:-}" ]]; then
  # Reuse the deployed secret when applying a configuration/image update. This
  # keeps existing desktop clients authenticated across revisions.
  POC_TOKEN="$(az containerapp secret show \
    --name "$POC_APP" \
    --resource-group "$POC_RG" \
    --secret-name ingest-token \
    --query value \
    --output tsv)"
elif [[ -z "${POC_TOKEN:-}" ]]; then
  POC_TOKEN="$(openssl rand -hex 32)"
fi
az group create --name "$POC_RG" --location "$POC_LOCATION" --output none

if ! az monitor log-analytics workspace show \
  --resource-group "$POC_RG" --workspace-name "$POC_LAW" --output none 2>/dev/null; then
  az monitor log-analytics workspace create \
    --resource-group "$POC_RG" \
    --workspace-name "$POC_LAW" \
    --location "$POC_LOCATION" \
    --sku PerGB2018 \
    --output none
fi
POC_LAW_ID="$(az monitor log-analytics workspace show \
  --resource-group "$POC_RG" \
  --workspace-name "$POC_LAW" \
  --query id \
  --output tsv)"
POC_LAW_CUSTOMER_ID="$(az monitor log-analytics workspace show \
  --resource-group "$POC_RG" \
  --workspace-name "$POC_LAW" \
  --query customerId \
  --output tsv)"
POC_LAW_KEY="$(az monitor log-analytics workspace get-shared-keys \
  --resource-group "$POC_RG" \
  --workspace-name "$POC_LAW" \
  --query primarySharedKey \
  --output tsv)"

if ! az monitor app-insights component show \
  --app "$POC_APPINSIGHTS" --resource-group "$POC_RG" --output none 2>/dev/null; then
  az monitor app-insights component create \
    --app "$POC_APPINSIGHTS" \
    --resource-group "$POC_RG" \
    --location "$POC_LOCATION" \
    --kind web \
    --application-type web \
    --workspace "$POC_LAW_ID" \
    --ingestion-access Enabled \
    --query-access Enabled \
    --output none
fi

# The Azure Monitor exporter uses a connection string. Fail instead of silently
# deploying a Collector that cannot export if organisation policy disables it.
LOCAL_AUTH_DISABLED="$(az monitor app-insights component show \
  --app "$POC_APPINSIGHTS" \
  --resource-group "$POC_RG" \
  --query disableLocalAuth \
  --output tsv)"
if [[ "$LOCAL_AUTH_DISABLED" == "true" ]]; then
  printf 'Application Insights local authentication is disabled; this PoC requires it enabled.\n' >&2
  exit 1
fi
APPLICATIONINSIGHTS_CONNECTION_STRING="$(az monitor app-insights component show \
  --app "$POC_APPINSIGHTS" \
  --resource-group "$POC_RG" \
  --query connectionString \
  --output tsv)"
if [[ -z "$APPLICATIONINSIGHTS_CONNECTION_STRING" ]]; then
  printf 'Could not retrieve the Application Insights connection string.\n' >&2
  exit 1
fi

if ! az containerapp env show \
  --name "$POC_ENV" --resource-group "$POC_RG" --output none 2>/dev/null; then
  az containerapp env create \
    --name "$POC_ENV" \
    --resource-group "$POC_RG" \
    --location "$POC_LOCATION" \
    --logs-destination log-analytics \
    --logs-workspace-id "$POC_LAW_CUSTOMER_ID" \
    --logs-workspace-key "$POC_LAW_KEY" \
    --output none
else
  # Correct an environment created by an earlier script version that let the
  # CLI create a second, automatically named workspace.
  az containerapp env update \
    --name "$POC_ENV" \
    --resource-group "$POC_RG" \
    --logs-destination log-analytics \
    --logs-workspace-id "$POC_LAW_CUSTOMER_ID" \
    --logs-workspace-key "$POC_LAW_KEY" \
    --output none
fi

# The Collector's env provider reads the complete multiline YAML value at start.
OTEL_CONFIG="$(<otel-config.yaml)"
if [[ "$APP_EXISTS" == "true" ]]; then
  az containerapp update \
    --name "$POC_APP" \
    --resource-group "$POC_RG" \
    --image "$OTEL_COLLECTOR_IMAGE" \
    --set-env-vars "OTEL_CONFIG=$OTEL_CONFIG" \
    --args=--config=env:OTEL_CONFIG \
    --output none
else
  az containerapp create \
    --name "$POC_APP" \
    --resource-group "$POC_RG" \
    --environment "$POC_ENV" \
    --image "$OTEL_COLLECTOR_IMAGE" \
    --ingress external \
    --target-port 4318 \
    --transport http \
    --cpu 0.25 \
    --memory 0.5Gi \
    --min-replicas 1 \
    --max-replicas 1 \
    --secrets \
      "ingest-token=$POC_TOKEN" \
      "ai-connection=$APPLICATIONINSIGHTS_CONNECTION_STRING" \
    --env-vars \
      "OTEL_CONFIG=$OTEL_CONFIG" \
      'OTEL_INGEST_TOKEN=secretref:ingest-token' \
      'APPLICATIONINSIGHTS_CONNECTION_STRING=secretref:ai-connection' \
    --args=--config=env:OTEL_CONFIG \
    --output none
fi

POC_FQDN="$(az containerapp show \
  --name "$POC_APP" \
  --resource-group "$POC_RG" \
  --query properties.configuration.ingress.fqdn \
  --output tsv)"

printf '\nCollector endpoint: https://%s\n' "$POC_FQDN"
printf 'Application Insights resource: %s (resource group: %s)\n' "$POC_APPINSIGHTS" "$POC_RG"
printf 'Keep this terminal open, then run:\n'
printf '  export POC_FQDN=%q\n' "$POC_FQDN"
printf '  export POC_TOKEN=%q\n' "$POC_TOKEN"
printf '  ./scripts/verify.sh\n'
printf '\nFor VS Code, export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $POC_TOKEN" before launching code.\n'
