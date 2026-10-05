# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Docker image that does two things in sequence on container start:

1. **Recreate** the Azure Speech Services (F0 free-tier) resource to reset its monthly TTS quota — delete, purge soft-deleted accounts, redeploy from an ARM template spec, fetch new keys.
2. **Proxy** — render `nginx.conf.template` with the fresh subscription key and `exec nginx`, so clients keep using one stable endpoint (`POST /tts`) and one static token (`X-Proxy-Token`) forever.

There is no application code — the project is Bash + an nginx config template + ARM JSON.

## Commands

```bash
# Build and run locally (host :9980 -> container :80)
docker compose -f docker-compose-dev.yml up --build

# Smoke-test the running proxy (writes test_audio.mp3; expects token "test-1234567890")
./test.sh

# Lint shell (external-sources enabled via .shellcheckrc, needed for the source of ensure-azure-resources.sh)
shellcheck *.sh

# Toolchain + secret-scanning pre-commit hook
mise install && ggshield install -m local -t pre-commit
```

`mise.toml` loads `.env` into the shell env (`_.file = '.env'`), so `az` commands typed locally see the same credentials the container uses.

### Iterating without touching Azure

Set `TTS_DEBUG=3` in `.env`. The script skips delete/purge/create entirely but still fetches keys from the existing resource and starts nginx — this is the way to test nginx config changes. `TTS_DEBUG=1` prints env; `2` adds `set -x`.

## Architecture

### Control flow

`Dockerfile` → `ENTRYPOINT bash` + `CMD /app/tts-recreate.sh`. That one script is the whole runtime:

- `tts-recreate.sh` — orchestrator. Logs in via service principal, resolves optional env defaults, generates `/tmp/deployment-input.json` from a template via `envsubst`, then runs `ensure_resources → delete_resources → purge_resources → create_resources → show_keys → start_nginx`.
- `ensure-azure-resources.sh` — **sourced**, not executed. Provides `provision_resource_group`, `provision_template_spec`, `update_template_spec`. It depends on `with_retry()` being already defined by the caller, so it cannot run standalone.
- `nginx.conf.template` — rendered to `/etc/nginx/nginx.conf` by `show_keys`, then `exec nginx -g "daemon off;"` replaces the script as PID 1.

The container is single-shot by design: the proxy is down during recreation, and a new key requires a container restart (a known limitation tracked in the README TODO).

### Hardcoded Azure names

Resource group `TTS`, template spec `audio-book-tts` version `v1`. These are string literals repeated across both scripts — not env vars. Only the Speech resource name (`AZURE_TTS_RESOURCE_NAME`, default `audio-book`) and region (`AZURE_LOCATION`, default `westus2`) are configurable.

`delete_resources` deletes by *prefix* match on `AZURE_TTS_RESOURCE_NAME` within kind `SpeechServices`; `purge_resources` purges **every** soft-deleted Cognitive Services account in the whole subscription. Both are destructive and subscription-wide in effect — be careful when changing their scope or when running against a subscription that holds other Cognitive Services resources.

`update_template_spec` compares `jq -cS` normalizations of the local and remote templates and re-uploads `v1` in place when they differ, so edits to `data/audio-book-tts.json` propagate automatically without a version bump.

### Template layering

Two distinct JSON files, easy to confuse:

- `data/audio-book-tts.json` — the ARM **deployment template** (uploaded as the template spec). Derived from the Azure Portal export, which is why it carries unused vnet/private-endpoint/commitment-plan machinery.
- `data/deployment-input.json.template` — the ARM **parameters** file, `envsubst`-expanded with `${AZURE_SUBSCRIPTION_ID} ${AZURE_LOCATION} ${AZURE_TTS_RESOURCE_NAME} ${AZURE_UNIQUE_ID}`. Resolution order: `/input/...` (user-mounted via the `/input` volume) → `/app/data/...` → `data/...` (local dev, cwd-relative).

Only these four placeholders are substituted — `envsubst` is given an explicit allowlist, so any other `${...}` in a template is left literal.

### Keys

`show_keys` writes **key2** into the nginx config and publishes both keys to the optional Telegram bot and pastebin-worker note. It exits 4 rather than render a config if either key is empty or `null`. `start_nginx` refuses to start if `TTS_PROXY_ACCESS_TOKEN` is under 12 chars.

Exit codes are a documented contract (README "Error Codes"): 1 login/token, 2 resource group, 3 template spec or missing template, 4 bad keys. Keep them stable.

### nginx specifics worth knowing

- Rate limit is a **single global zone** keyed on the constant string `"azure-global"` (not per-IP), `17r/m` with `burst=8`, sized to Azure's free-tier 20 req/min.
- Auth is an `if ($http_x_proxy_token != ...)` → `return 444` (connection dropped, no response body) — that is why bad tokens look like an aborted connection to clients.
- `proxy_http_version 1.1` plus `proxy_set_header Connection ""` is required: the Azure TTS API rejects HTTP/1.0 (see commit `8f2179d`).
- `X-Microsoft-OutputFormat` is passed through, defaulting to `audio-16khz-32kbitrate-mono-mp3`; `Content-Type`, `User-Agent`, `Host`, and `Ocp-Apim-Subscription-Key` are all set by the proxy and client values are ignored.

## Conventions

- Tabs for indentation in shell scripts; `set -euo pipefail`; wrap every `az` mutation in `with_retry` (3 attempts, linear backoff 10s/20s).
- Commit messages are Conventional Commits with an optional gitmoji: `feat: :sparkles: ...`, `fix: ...`, `docs: :memo: ...`.
- Images publish to `ghcr.io/genzj/azure-tts` only on `v*` tags; pushes and PRs build `linux/amd64,linux/arm64` without pushing. GitGuardian scans every push and PR, and a `ggshield` pre-commit hook guards locally — never let a real key reach a tracked file.
- `.env` is gitignored and holds live credentials; `deployment-input.json` at the repo root is a stray generated artifact, not an input.
