# Send Copilot telemetry to Azure

This project deploys an OpenTelemetry Collector to Azure Container Apps. The
collector receives telemetry from Visual Studio Code Copilot and the standalone
GitHub Copilot CLI. It sends traces, metrics, and logs to Application Insights.

```text
VS Code Copilot ─┐
                 ├─ OTLP/HTTP ─> Azure Container Apps ─> Application Insights
Copilot CLI ─────┘                OpenTelemetry Collector
```

Use this project to evaluate Copilot telemetry. It is a proof of concept (PoC),
not a durable production service.

## What the project creates

The deployment script creates these Azure resources:

- A resource group.
- A Log Analytics workspace.
- A workspace-based Application Insights resource.
- A Container Apps environment.
- One Container App.

The collector accepts authenticated OTLP/HTTP requests on port `4318`. Azure
Container Apps terminates HTTPS at the public endpoint. The collector receives
HTTP traffic inside the app.

The collector sends traces, metrics, and logs to Application Insights. The
configuration also retains span events. Copilot CLI span data can include tool
activity and skill names.

## Requirements

Install these tools:

- Azure CLI. Sign in with `az login` before deployment.
- Bash, `curl`, and `openssl`.
- Permission to create resource groups, workspaces, Application Insights
  resources, and Container Apps resources in your subscription.

The deployment uses the `uksouth` location by default.

## Deploy

1. Optional: copy `.env.example` to `.env` to change the resource names or
   location. Git ignores `.env`. Do not store secrets in it.
2. If you use `.env`, load its values in your terminal:

   ```bash
   set -a
   source .env
   set +a
   ```

3. Run the deployment script:

   ```bash
   ./scripts/deploy.sh
   ```

The script creates an ingestion token if `POC_TOKEN` is not set. It stores the
token and the Application Insights connection string as Container Apps secrets.
The script prints commands that set `POC_FQDN` and `POC_TOKEN` in your terminal.
Run those commands in the same terminal.

The script also prints the collector URL. Use that URL in the client settings
below.

To select a tested Collector Contrib image, set `OTEL_COLLECTOR_IMAGE` before
you run the script:

```bash
OTEL_COLLECTOR_IMAGE=otel/opentelemetry-collector-contrib:<tested-version> \
  ./scripts/deploy.sh
```

The default image tag is pinned. Test a new tag before you use it.

## Verify the endpoint

Run the verification script in the terminal where `POC_FQDN` and `POC_TOKEN`
are set:

```bash
./scripts/verify.sh
```

The script sends an empty OTLP trace request. It expects `HTTP 401` without the
token and `HTTP 200` with the token. These results verify ingress and
authentication. They do not create useful telemetry.

## Configure Visual Studio Code Copilot

Add these settings to your Visual Studio Code **user settings**. Replace
`<collector-fqdn>` with the hostname from the deployment output.

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "https://<collector-fqdn>",
  "github.copilot.chat.otel.captureContent": false
}
```

Keep `captureContent` set to `false` unless you approved the export of
prompts, source code, tool arguments, and model responses.

Before you start Visual Studio Code, export the request header in the same
terminal:

```bash
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $POC_TOKEN"
code .
```

Fully quit Visual Studio Code before you start it from this terminal. Processes
that already run do not receive new environment variables. Start a new Copilot
chat and allow a few minutes for telemetry to arrive.

## Configure the standalone GitHub Copilot CLI

VS Code settings do not configure the standalone `copilot` process. Set these
environment variables in the terminal before you start a new CLI session:

```bash
export COPILOT_OTEL_ENABLED=true
export COPILOT_OTEL_EXPORTER_TYPE=otlp-http
export OTEL_EXPORTER_OTLP_ENDPOINT="https://<collector-fqdn>"
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $POC_TOKEN"
export OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false
copilot
```

Replace `<collector-fqdn>` with the hostname from deployment. The CLI adds the
OTLP signal path to the endpoint. The tested protocol is `http/json`.
`http/protobuf` also works with a compatible CLI version.

The CLI uses the `github-copilot` service name. The provided Copilot query
filters on this name.

## View telemetry

Open the Logs view for the Application Insights resource. Run the queries in
[kql queries/copilot.kql](<kql queries/copilot.kql>) for Copilot metrics, tool
calls, dependency spans, and skill names.

The portal can show different table names for classic and workspace-based
Application Insights resources. Use the table name that the Logs view suggests.

The dependency query shows Copilot CLI skill names from the
`customDimensions["gen_ai.skill.name"]` field.

## Update the collector

Run `./scripts/deploy.sh` again after you change `otel-config.yaml` or the
Collector image. The script updates the app and keeps its current ingestion
token.

To rotate the token, update the `ingest-token` secret in Container Apps and
create a new app revision. Update `POC_TOKEN` in each client terminal to match.

View collector logs with:

```bash
./scripts/logs.sh
```

## Security

- The app has public ingress. A bearer token provides the only caller
  authentication in this PoC. Keep the token secret.
- The collector uses the Application Insights connection string to export
  telemetry. This deployment requires Application Insights local authentication.
- Do not enable content or identity capture without a review of data access,
  privacy, and retention.

## PoC limits

- The app runs one replica. Its batch queue is in memory, so an app restart can
  lose telemetry that has not reached Application Insights.
- A production service needs a private network, token rotation, collector
  health checks, capacity tests, and a durable high-availability design.
