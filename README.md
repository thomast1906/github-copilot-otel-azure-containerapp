# GitHub Copilot OTel → Azure Container Apps → Application Insights

This repository deploys a deliberately small proof of concept:

```text
Copilot Chat / Copilot CLI ── OTLP/HTTP + Bearer token ──►
Azure Container App (OpenTelemetry Collector Contrib) ──►
Application Insights + Log Analytics workspace ──► KQL
```

The Container App runs one Collector replica and holds its batch queue in
memory. It is suitable for evaluating agent telemetry, not for a durable or
high-availability production telemetry pipeline.

## What is included

- [otel-config.yaml](otel-config.yaml) accepts authenticated OTLP/HTTP on port
  4318 and forwards traces, metrics, and logs with the Azure Monitor exporter.
- [scripts/deploy.sh](scripts/deploy.sh) creates a dedicated resource group,
  Log Analytics workspace, Application Insights component, Container Apps
  environment, and the collector.
- [scripts/verify.sh](scripts/verify.sh) verifies the protected endpoint.
- [queries](queries) contains starting KQL for Copilot and Codex.

Secrets never belong in this repository. Container Apps stores the ingestion
token and Application Insights connection string as secrets and injects them
as environment variables only at runtime.

## Prerequisites

- Azure CLI, logged into the subscription where the PoC resource group may be
  created.
- Permission to create a resource group, Container Apps environment, and
  Container App.
- Permission to create a Log Analytics workspace and Application Insights
  component, as well as Container Apps resources, in the PoC resource group.
- `openssl`, `curl`, and Bash.

The deployment defaults to UK South and these names:

```bash
POC_RG=rg-copilot-otel-poc
POC_ENV=cae-copilot-otel-poc
POC_APP=ca-copilot-otel-poc
POC_LAW=law-copilot-otel-poc
POC_APPINSIGHTS=appi-copilot-otel-poc
```

Copy `.env.example` to a local, ignored `.env` only if you want to change the
non-secret names. Source it before deployment; do not put secret values in it.

## Deploy

From either the repository root or the `scripts` directory:

```bash
./scripts/deploy.sh
```

The script creates a workspace-based Application Insights resource in the same
resource group, retrieves its connection string without displaying it, and
generates a 256-bit hexadecimal ingestion token unless `POC_TOKEN` is already
set. It verifies that Application Insights local authentication is enabled,
because this exporter route needs the connection string. It prints two `export`
commands at the end. Run those in the same terminal and then verify the endpoint:

```bash
./scripts/verify.sh
```

Expected results are `HTTP 401` without the token and `HTTP 200` with it. The
empty OTLP requests only validate the ingress and authentication; they do not
create useful telemetry. Inspect startup or export errors with:

```bash
./scripts/logs.sh
```

The Azure Monitor exporter retains Copilot CLI span events through
`spaneventsenabled: true`, which is useful for diagnostics. Exact skill names
from the tested Copilot CLI appear on `execute_tool` dependency records in
`customDimensions["gen_ai.skill.name"]`.

Run `./scripts/deploy.sh` again after changing `otel-config.yaml` or the pinned
Collector image. It detects the existing Container App, preserves its secrets,
and creates a new revision with the checked-in configuration.

`deploy.sh` pins a Collector Contrib tag for repeatability. Test and explicitly
change `OTEL_COLLECTOR_IMAGE` when upgrading it, for example:

```bash
OTEL_COLLECTOR_IMAGE=otel/opentelemetry-collector-contrib:<tested-version> ./scripts/deploy.sh
```

## Configure VS Code Copilot

Add the following to VS Code **user** settings, substituting the hostname
printed by deployment. Keep `captureContent` false unless you have made an
intentional data-handling decision to export prompts, source code, tool
arguments, and model responses.

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "https://<collector-fqdn>",
  "github.copilot.chat.otel.captureContent": false
}
```

Before starting VS Code, export the request header in the same terminal that
launches it:

```bash
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $POC_TOKEN"
code .
```

Fully quit VS Code first so its processes inherit the variable. Start a new
agent conversation, wait a few minutes after it completes, then use the KQL in
[queries/copilot.kql](queries/copilot.kql). Depending on whether the Application
Insights resource is classic or workspace-based, the portal may show table names
with the newer `App*`/`Custom*` casing; use the table name suggested by Logs.

## Configure the standalone GitHub Copilot CLI

The VS Code `settings.json` settings above configure the VS Code extension;
they do **not** configure a `copilot` process launched directly in a terminal.
Before starting a new Copilot CLI session, run the following in that terminal:

```bash
export COPILOT_OTEL_ENABLED=true
export COPILOT_OTEL_EXPORTER_TYPE=otlp-http
export OTEL_EXPORTER_OTLP_ENDPOINT="https://<collector-fqdn>"
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <ingest-token>"
export OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false
copilot
```

The endpoint is the collector base URL: the CLI appends the appropriate OTLP
signal path itself. `http/json` is the tested setting; `http/protobuf` also
works with a compatible CLI version. Set these variables before launching
`copilot`; an already running CLI process does not inherit later changes.
Copilot CLI reports under the `github-copilot` service name, which is already
included in the provided KQL queries.

## Security and PoC limits

- External ingress is intentional for desktop clients, and the bearer token is
  the only caller authentication in this PoC. Treat it as a secret and rotate
  it by updating the Container App secret and restarting/revising the app.
- The Application Insights connection string authenticates the exporter. Local
  authentication must remain enabled for this route.
- HTTPS is terminated by Container Apps. The Collector receives traffic on its
  internal HTTP listener.
- Do not enable content or identity capture without a retention, access-control,
  and privacy review.
- One replica and in-memory batching mean a restart can lose queued telemetry.
  Production should use private networking, secret rotation, observability for
  the collector itself, sizing/load tests, and a durable/HA design.