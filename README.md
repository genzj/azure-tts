# Azure TTS Proxy & Service Recreation

Automates the recreation of Azure Text-to-Speech (TTS) free-tier services to bypass monthly quota limitations, and provides a reverse proxy so that clients never need to update their credentials after each recreation cycle.

## Overview

Azure's free TTS service (F0 SKU) has usage quotas that, once exceeded, prevent further text-to-speech operations. This project solves the problem by combining two components:

1. **Service Recreation** — a script that automatically deletes, purges, and recreates Azure TTS service instances, then retrieves fresh API keys.
2. **TTS Proxy** — a [Caddy](https://caddyserver.com/)-based reverse proxy that transparently injects the latest Azure credentials into every request, so clients only need a single, stable proxy endpoint and a static access token.

After each recreation cycle the proxy picks up the new key automatically. From the client's perspective, the Azure TTS API is always available with virtually no monthly quota limitation.

### How It Works

```
Client --> POST /tts --> TTS Proxy (Caddy :80) --> Azure TTS API
                          │
                          ├─ Authenticates client via X-Proxy-Token header
                          ├─ Injects current Azure subscription key
                          └─ Forwards SSML payload to Azure
```

1. The recreation script (`tts-recreate.sh`) logs in with an Azure service principal, tears down the old TTS resource, purges it, deploys a fresh one from an ARM template spec, and writes the new key into the Caddy configuration.
2. Caddy starts immediately after and serves as the proxy until the container is restarted for the next recreation cycle.
3. Clients authenticate with a static `X-Proxy-Token` header and POST SSML to `/tts`. The proxy handles all Azure-specific headers and credential injection.

## Prerequisites

- Azure service principal with appropriate permissions (see [Create an Azure Service Principal](#create-an-azure-service-principal))
- Azure CLI installed and configured (local run only, not needed for running with the Docker image)

The resource group `TTS` and the template spec `audio-book-tts` are created automatically on first run if they do not already exist. An existing template spec is also updated when the bundled ARM template has changed.

## Quick Start (Docker)

1. Download [docker-compose.yml](docker-compose.yml) and [.env.sample](.env.sample).

2. Prepare your `.env` file:

   ```bash
   cp .env.sample .env
   # Edit .env — fill in the 4 required values (see below)
   ```

3. Run with Docker Compose:

   ```bash
   docker compose up
   ```

   Or run directly:

   ```bash
   docker run --rm --env-file .env -p 80:80 ghcr.io/genzj/azure-tts:latest
   ```

   The container will automatically detect your subscription ID, generate the deployment parameters, create the Azure resources, and start the proxy.

4. Send a TTS request through the proxy:

   ```bash
   curl -X POST http://localhost/tts \
     -H "X-Proxy-Token: <your-TTS_PROXY_ACCESS_TOKEN>" \
     -H "X-Microsoft-OutputFormat: audio-48khz-192kbitrate-mono-mp3" \
     -d "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>\
          <voice name='en-US-JennyNeural'>Hello from the TTS proxy.</voice>\
         </speak>" \
     --output speech.mp3
   ```

## Configuration

### Environment Variables

Configure these in your `.env` file:

| Variable                  | Required | Default           | Description                                                                                                                              |
| ------------------------- | -------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `AZURE_APPID`             | Yes      |                   | Service principal application ID                                                                                                         |
| `AZURE_PASSWORD`          | Yes      |                   | Service principal password / secret                                                                                                      |
| `AZURE_TENANT`            | Yes      |                   | Azure AD tenant ID (see [Finding Your Tenant ID](#finding-your-tenant-id))                                                               |
| `TTS_PROXY_ACCESS_TOKEN`  | Yes      |                   | Static token clients use to authenticate with the proxy (min 12 characters)                                                              |
| `AZURE_SUBSCRIPTION_ID`   | No       | _(auto-detected)_ | Azure subscription ID. Auto-detected after login; must be set explicitly when the service principal has access to multiple subscriptions |
| `AZURE_LOCATION`          | No       | `westus2`         | Azure region for the TTS resource and Caddy upstream URL                                                                                 |
| `AZURE_TTS_RESOURCE_NAME` | No       | `audio-book`      | Name of the Cognitive Services resource                                                                                                  |
| `TELEGRAM_BOT_TOKEN`      | No       |                   | Telegram bot token for key-change notifications                                                                                          |
| `TELEGRAM_CHAT_ID`        | No       |                   | Telegram chat ID for notifications                                                                                                       |
| `NOTE_MANAGE_URL`         | No       |                   | Manage URL of a [pastebin-worker](https://github.com/SharzyL/pastebin-worker) note for key publishing                                    |
| `TTS_DEBUG`               | No       | `0`               | Debug level: 0 = off, 1 = print env, 2 = print env + trace, 3 = dry run (see [Debugging](#debugging))                                    |

### Advanced: Custom Deployment Parameters

For most users, the built-in `deployment-input.json.template` generates the correct deployment parameters automatically from environment variables. No manual file editing is needed.

If you need full control over the ARM deployment parameters, mount a modified `deployment-input.json.template` into `/input/`. Available placeholders: `${AZURE_SUBSCRIPTION_ID}`, `${AZURE_LOCATION}`, `${AZURE_TTS_RESOURCE_NAME}`, `${AZURE_UNIQUE_ID}`.

Template resolution order:

1. `/input/deployment-input.json.template` (user-mounted custom template)
2. `/app/data/deployment-input.json.template` (bundled default)

### Create an Azure Service Principal

You need a service principal so the container can log in to Azure and manage TTS resources. All built-in roles used below are available on every Azure account tier, including free.

1. Find and export your subscription ID:

   ```bash
   az account list --query "[].{Name:name, Id:id}" -o table

   export SUBSCRIPTION_ID="<copy your subscription ID from the table above>"
   ```

2. Create the resource group (so role assignments can be scoped to it):

   ```bash
   az group create --name TTS --location westus2
   ```

3. Create the service principal:

   ```bash
   # ⚠ The output contains appId, password, and tenant — save them
   #   somewhere secure immediately. The password is shown only once
   #   and cannot be retrieved later.
   az ad sp create-for-rbac --name "tts-recreator"
   ```

   Export the `appId` from the output for the next step:

   ```bash
   export SP_APPID="<copy appId from the output above>"
   ```

4. Assign the recommended least-privilege roles:

   ```bash
   az role assignment create --assignee "$SP_APPID" \
     --role "Cognitive Services Contributor" \
     --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/TTS"

   az role assignment create --assignee "$SP_APPID" \
     --role "Template Spec Contributor" \
     --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/TTS"

   az role assignment create --assignee "$SP_APPID" \
     --role "Reader" \
     --scope "/subscriptions/$SUBSCRIPTION_ID"
   ```

   > If you skipped step 2 and want the container to create the resource group automatically on first run, replace `Reader` with `Contributor` at the subscription scope. You can downgrade it to `Reader` afterwards.

5. Copy `appId`, `password`, and `tenant` from the step 3 output into your `.env` as `AZURE_APPID`, `AZURE_PASSWORD`, and `AZURE_TENANT`.

> **Quick alternative:** If you just want to get started and will tighten permissions later, a single command does everything:
>
> ```bash
> az ad sp create-for-rbac --name "tts-recreator" \
>   --role Owner --scopes "/subscriptions/$SUBSCRIPTION_ID"
> ```
>
> This grants full control over the subscription — not recommended for production use. See the [Azure CLI documentation](https://learn.microsoft.com/en-us/cli/azure/azure-cli-sp-tutorial-1) for details.

### Finding Your Tenant ID

Your Azure AD tenant ID is required in `.env` as `AZURE_TENANT`. You can find it in several ways:

- **From `az ad sp create-for-rbac` output** — The `tenant` field in the JSON output when you created the service principal.
- **Azure CLI** — Run `az account show --query tenantId -o tsv`.
- **Azure Portal** — Navigate to **Microsoft Entra ID** → **Overview** → **Tenant ID**.

## Proxy API Reference

### `GET /healthz`

Returns `200 OK` when the proxy is running. No authentication required. Intended for use by orchestrators (Docker, Kubernetes) and load balancers.

```bash
curl http://localhost/healthz
# OK
```

### `POST /tts`

Proxies a TTS synthesis request to Azure Cognitive Services.

**Headers:**

| Header                     | Required | Description                                                                                                      |
| -------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------- |
| `X-Proxy-Token`            | Yes      | Must match `TTS_PROXY_ACCESS_TOKEN`                                                                              |
| `X-Microsoft-OutputFormat` | No       | Azure TTS output format (e.g. `audio-48khz-192kbitrate-mono-mp3`). Defaults to `audio-16khz-32kbitrate-mono-mp3` |

**Body:** SSML payload (the proxy sets `Content-Type: application/ssml+xml` upstream).

**Response:**

The proxy itself may return the following:

| Status                   | Condition                          |
| ------------------------ | ---------------------------------- |
| _(connection aborted)_   | Missing or invalid `X-Proxy-Token` |
| `404 Not Found`          | Path is not `/tts`                 |
| `405 Method Not Allowed` | Non-POST method on `/tts`          |

When the request passes proxy validation, it is forwarded to Azure TTS. The Azure response (status codes, headers, and body — an audio stream in the format specified by `X-Microsoft-OutputFormat`, or `audio-16khz-32kbitrate-mono-mp3` by default) is returned to the client transparently.

## Client Migration Guide

If you were previously calling the Azure TTS API directly:

1. Replace the Azure endpoint (`https://<region>.tts.speech.microsoft.com/cognitiveservices/v1`) with your proxy URL (`http://<proxy-host>/tts`).
2. Replace the `Ocp-Apim-Subscription-Key` header with `X-Proxy-Token: <your-TTS_PROXY_ACCESS_TOKEN>`.
3. Remove any `Content-Type` and `User-Agent` headers — the proxy injects these automatically.
4. `X-Microsoft-OutputFormat` is now transparently forwarded to Azure. If omitted, the proxy defaults to `audio-16khz-32kbitrate-mono-mp3`.
5. Keep sending the same SSML body as before.

That's it. No further changes are needed when credentials rotate.

## Error Codes

| Code | Description                                                                                   |
| ---- | --------------------------------------------------------------------------------------------- |
| 1    | Azure login failed, or `TTS_PROXY_ACCESS_TOKEN` is too short (< 12 chars)                     |
| 2    | Resource group `TTS` could not be found or created                                            |
| 3    | Template spec `audio-book-tts` could not be found or created, or no deployment template found |
| 4    | Failed to retrieve valid API keys from Azure                                                  |

## Development

### Setup

1. Install [mise](https://mise.jdx.dev/getting-started.html).

2. Clone the repository:

   ```bash
   git clone https://github.com/genzj/azure-tts.git
   cd azure-tts
   ```

3. Install the toolchain:

   ```bash
   mise trust
   mise install
   ggshield install -m local -t pre-commit
   ggshield auth login
   ```

4. Prepare configuration:

   ```bash
   cp .env.sample .env
   # Edit .env with your 4 required values
   ```

5. Build and run locally:

   ```bash
   docker compose -f docker-compose-dev.yml up --build
   ```

   The dev compose file maps port `9980` → `80` inside the container.

### Testing the Proxy

```bash
./test.sh
# Sends a sample SSML request to localhost:9980 and saves test_audio.mp3
```

### CI/CD

The GitHub Actions workflow (`.github/workflows/publish-image.yml`) builds multi-arch images (`linux/amd64`, `linux/arm64`) on every push and PR. Pushing a version tag (e.g. `v1.0.0`) publishes the image to `ghcr.io/genzj/azure-tts` and creates a draft GitHub release.

[GitGuardian](https://www.gitguardian.com/) scans run on every push and PR to detect leaked secrets.

## Debugging

Set `TTS_DEBUG` in `.env` to control debug output:

| Level | Behaviour                                                                                                                                                                                                                                       |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0`   | Debug disabled (default).                                                                                                                                                                                                                       |
| `1`   | Print all environment variables (sorted), then continue normally.                                                                                                                                                                               |
| `2`   | Print all environment variables and enable shell tracing (`set -x`) so every executed command is logged.                                                                                                                                        |
| `3`   | Dry run — print environment variables, skip the entire recreation cycle (delete / purge / create), but still fetch keys from the existing Azure TTS service and start the proxy. Useful for testing the proxy without touching Azure resources. |

## Troubleshooting

**Login Failures**

- Verify service principal credentials in `.env`.
- Ensure the service principal has not expired.
- Check the tenant ID is correct.

**Resource Not Found**

- Check your service principal has the required permissions to create resource groups and template specs.
- If auto-provisioning fails, you can manually create the resource group and upload the template spec (see error codes 2 and 3).

**Deployment Failures**

- Check the environment variables (`AZURE_LOCATION`, `AZURE_TTS_RESOURCE_NAME`) or your custom `deployment-input.json.template` if mounted.
- Ensure template spec version `v1` is accessible.
- Check resource quotas in your subscription.

**Proxy Not Starting**

- `TTS_PROXY_ACCESS_TOKEN` must be at least 12 characters. Generate one with: `openssl rand -base64 32 | tr -d '/+=' | cut -c1-32`
- Check Caddy logs in the container output for configuration errors.

**Clients Getting Connection Aborted**

- Ensure the `X-Proxy-Token` header value matches `TTS_PROXY_ACCESS_TOKEN` exactly.

## Security

- Never commit `.env` files containing credentials.
- Use a strong, random `TTS_PROXY_ACCESS_TOKEN` (at least 12 characters, 32+ recommended).
- Place the proxy behind an API gateway or load balancer that terminates TLS — Caddy listens on plain HTTP by design.
- Regularly rotate service principal secrets.
- Follow the principle of least privilege for Azure permissions.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## TODO

### Separate recreator and proxy into independent services

Currently the recreation script and the Caddy proxy run sequentially in a single container — the proxy is unavailable during recreation and cannot scale independently.

- Split into two containers: a short-lived recreator job and a long-running proxy service.
- After recreating the Azure resource, the recreator pushes the new key to Caddy via its [admin API](https://caddyserver.com/docs/api) (`POST /load`) instead of writing a static config file.
- Enable the Caddy admin API listener (currently unused) and secure it for internal-only access.
- Allow horizontal scaling of the proxy behind a load balancer while a single recreator instance manages the lifecycle.
- Achieve zero-downtime credential rotation — clients experience no interruption during recreation.

### Production docker-compose with port mapping and restart policy

The shipped `docker-compose.yml` has the port mapping commented out and uses `restart: "no"`.

- Provide a production-ready compose example with port exposure, a restart policy (e.g. `unless-stopped`), and optional scheduling (cron or external trigger) for periodic recreation.

## Acknowledgments

- [Caddy](https://caddyserver.com/) for the lightweight, config-driven reverse proxy
- Azure CLI team for comprehensive tooling
- Azure Cognitive Services documentation
