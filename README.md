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

- Azure CLI installed and configured (included in the Docker image)
- Azure service principal with appropriate permissions (see [Create an Azure Service Principal](#create-an-azure-service-principal))

The resource group `TTS` and the template spec `audio-book-tts` are created automatically on first run if they do not already exist. An existing template spec is also updated when the bundled ARM template has changed.

## Quick Start (Docker)

1. Download [docker-compose.yml](docker-compose.yml), [.env.sample](.env.sample), and [deployment-input-sample.json](data/deployment-input-sample.json).

2. Prepare configuration files:

   ```bash
   cp .env.sample .env
   # Edit .env with your Azure credentials and proxy token

   cp deployment-input-sample.json deployment-input.json
   # Replace <SUBSCRIPTION_ID> with your Azure subscription id
   ```

3. Run with Docker Compose:

   ```bash
   docker compose up
   ```

   Or run directly:

   ```bash
   docker run --rm --env-file .env --volume '.:/input' -p 80:80 ghcr.io/genzj/azure-tts:latest
   ```

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

| Variable                 | Required | Description                                                                                           |
| ------------------------ | -------- | ----------------------------------------------------------------------------------------------------- |
| `AZURE_APPID`            | Yes      | Service principal application ID                                                                      |
| `AZURE_PASSWORD`         | Yes      | Service principal password / secret                                                                   |
| `AZURE_TENANT`           | Yes      | Azure AD tenant ID                                                                                    |
| `TTS_PROXY_ACCESS_TOKEN` | Yes      | Static token clients use to authenticate with the proxy (min 12 characters)                           |
| `TELEGRAM_BOT_TOKEN`     | No       | Telegram bot token for key-change notifications                                                       |
| `TELEGRAM_CHAT_ID`       | No       | Telegram chat ID for notifications                                                                    |
| `NOTE_MANAGE_URL`        | No       | Manage URL of a [pastebin-worker](https://github.com/SharzyL/pastebin-worker) note for key publishing |
| `TTS_DEBUG`              | No       | Debug level: 0 = off, 1 = print env, 2 = print env + trace, 3 = dry run (see [Debugging](#debugging)) |

### Deployment Parameters

Edit `deployment-input.json` to customise the Azure resource deployment. Key parameters:

| Parameter  | Default        | Description                             |
| ---------- | -------------- | --------------------------------------- |
| `name`     | `audio-book-2` | Name of the Cognitive Services resource |
| `location` | `westus2`      | Azure region                            |
| `sku`      | `F0`           | Pricing tier (F0 = free)                |

Replace `<SUBSCRIPTION_ID>` in the file with your actual Azure subscription ID.

### Create an Azure Service Principal

Create a service principal scoped to your subscription:

```bash
# https://learn.microsoft.com/en-us/cli/azure/azure-cli-sp-tutorial-1
az ad sp create-for-rbac --name "tts-recreator" --role Owner --scopes /subscriptions/<SUBSCRIPTION_ID>
```

Ideally, use least-privilege roles instead of `Owner`:

- `Cognitive Services Contributor` on the TTS resource group
- `Template Spec Contributor` for template spec creation and updates
- `Resource Group Contributor` for auto-creating the resource group (or `Resource Group Reader` if the group already exists)

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

| Code | Description                                                               |
| ---- | ------------------------------------------------------------------------- |
| 1    | Azure login failed, or `TTS_PROXY_ACCESS_TOKEN` is too short (< 12 chars) |
| 2    | Resource group `TTS` could not be found or created                        |
| 3    | Template spec `audio-book-tts` could not be found or created              |
| 4    | Failed to retrieve valid API keys from Azure                              |

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
   cp data/deployment-input-sample.json deployment-input.json
   # Edit both files with your values
   ```

5. Build and run locally:

   ```bash
   docker build -t azure-tts:latest .
   docker compose -f docker-compose-dev.yml up
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

- Validate `deployment-input.json` parameters.
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

### Simplify Provisioning

Goal: a user should only need to set `AZURE_APPID`, `AZURE_PASSWORD`, `AZURE_TENANT`, and `TTS_PROXY_ACCESS_TOKEN` in `.env`, then `docker compose up`. Everything else is derived or defaulted.

1. **Create `deployment-input.json.template`** — A template using `envsubst` placeholders (`${AZURE_SUBSCRIPTION_ID}`, `${AZURE_LOCATION}`, `${AZURE_TTS_RESOURCE_NAME}`, etc.). Bundled in the image at `/app/data/` but overridable by mounting a custom template into `/input/`.

2. **Auto-resolve subscription ID at runtime** — If `AZURE_SUBSCRIPTION_ID` is not set in `.env`, auto-detect it after `az login` via `az account show --query id -o tsv` and export it for `envsubst`. If the service principal has access to multiple subscriptions, auto-detection may pick the wrong one; in that case the user must set `AZURE_SUBSCRIPTION_ID` explicitly in `.env`.

3. **Generate `deployment-input.json` from template** — In `tts-recreate.sh`, before `create_resources`, run `envsubst` on the template to produce `/input/deployment-input.json`. Template resolution order: `/input/deployment-input.json.template` (user-mounted) → `/app/data/deployment-input.json.template` (bundled default). If a pre-built `/input/deployment-input.json` already exists (backward compat), use it as-is and skip generation.

4. **Make location configurable via `.env`** — Add optional `AZURE_LOCATION` env var (default `westus2`). Used in the deployment template and for the Caddy upstream URL.

5. **Make resource name configurable via `.env`** — Add optional `AZURE_TTS_RESOURCE_NAME` env var (default `audio-book`). Used in the deployment template and in `show_keys`/`delete_resources` (replacing the currently hardcoded name).

6. **Inject region into Caddyfile dynamically** — Replace the hardcoded `westus2` in `Caddyfile.template` with `${AZURE_LOCATION}`, and add it to the `envsubst` call that already handles `${AZURE_TTS_KEY}`.

7. **Update `.env.sample`** — Show the 4 required fields (`AZURE_APPID`, `AZURE_PASSWORD`, `AZURE_TENANT`, `TTS_PROXY_ACCESS_TOKEN`) and the new optional ones (`AZURE_LOCATION`, `AZURE_TTS_RESOURCE_NAME`) with defaults documented in comments.

8. **Document how to find the Azure tenant ID** — Add a README section (near the service principal instructions) explaining how to find it: from `az ad sp create-for-rbac` output, `az account show --query tenantId`, or Azure Portal (Microsoft Entra ID → Overview → Tenant ID).

9. **Update README Quick Start** — Simplify to: copy `.env.sample` → `.env`, fill in 4 required values, `docker compose up`. Mention `deployment-input.json.template` only in an advanced configuration section.

10. **Handle `uniqueId` in template** — Generate a UUID at runtime and export it for `envsubst`.

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
