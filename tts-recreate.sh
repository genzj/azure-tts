#!/bin/bash
set -euo pipefail

MAX_RETRIES=3
RETRY_DELAY=10

# Retry a command up to MAX_RETRIES times with exponential backoff.
# Usage: with_retry <description> <command...>
with_retry() {
	local desc="$1"
	shift
	local attempt
	for attempt in $(seq 1 "$MAX_RETRIES"); do
		if "$@"; then
			return 0
		fi
		if [[ $attempt -lt $MAX_RETRIES ]]; then
			local delay=$((RETRY_DELAY * attempt))
			echo "WARN: $desc failed (attempt $attempt/$MAX_RETRIES), retrying in ${delay}s..." >&2
			sleep "$delay"
		fi
	done
	echo "ERROR: $desc failed after $MAX_RETRIES attempts" >&2
	return 1
}

if [[ ${TTS_DEBUG:-0} -gt 0 ]]; then
	env | sort
fi

if [[ ${TTS_DEBUG:-0} -gt 1 ]]; then
	set -x
fi

if ! az login \
	--service-principal \
	--username "$AZURE_APPID" \
	--password "$AZURE_PASSWORD" \
	--tenant "$AZURE_TENANT"; then
	echo "cannot login with service-pricinpal"
	exit 1
fi

# --- Resolve defaults for optional env vars ---

# Auto-resolve subscription ID at runtime
if [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
	AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
	echo "Auto-detected AZURE_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID"
fi
export AZURE_SUBSCRIPTION_ID

# Make location configurable via .env (default: westus2)
export AZURE_LOCATION="${AZURE_LOCATION:-westus2}"
echo "Using AZURE_LOCATION=$AZURE_LOCATION"

# Make resource name configurable via .env (default: audio-book)
export AZURE_TTS_RESOURCE_NAME="${AZURE_TTS_RESOURCE_NAME:-audio-book}"
echo "Using AZURE_TTS_RESOURCE_NAME=$AZURE_TTS_RESOURCE_NAME"

# Generate a UUID for the uniqueId template parameter
export AZURE_UNIQUE_ID
AZURE_UNIQUE_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || uuidgen)"
echo "Generated AZURE_UNIQUE_ID=$AZURE_UNIQUE_ID"

# Generate deployment-input.json from template
_generate_deployment_input() {
	local template=""

	# Template resolution order: user-mounted > bundled default > local dev
	if [[ -f "/input/deployment-input.json.template" ]]; then
		template="/input/deployment-input.json.template"
	elif [[ -f "/app/data/deployment-input.json.template" ]]; then
		template="/app/data/deployment-input.json.template"
	elif [[ -f "data/deployment-input.json.template" ]]; then
		template="data/deployment-input.json.template"
	fi

	if [[ -z "$template" ]]; then
		echo "ERROR: No deployment-input.json.template found"
		exit 3
	fi

	echo "Generating deployment-input.json from template $template"
	# shellcheck disable=SC2016
	envsubst '${AZURE_SUBSCRIPTION_ID} ${AZURE_LOCATION} ${AZURE_TTS_RESOURCE_NAME} ${AZURE_UNIQUE_ID}' \
		<"$template" >/tmp/deployment-input.json
}

_generate_deployment_input

# shellcheck source=ensure-azure-resources.sh
source "$(dirname "$0")/ensure-azure-resources.sh"

ensure_resources() {
	# Check if resource group "TTS" exists, create if missing
	if ! az group show --name "TTS" >/dev/null 2>&1; then
		provision_resource_group
	else
		echo "Found resource group TTS"
	fi
	# Check if template spec "audio-book-tts" exists, create if missing
	if ! az ts show --name "audio-book-tts" --resource-group "TTS" --version "v1" >/dev/null 2>&1; then
		provision_template_spec
	else
		echo "Found template spec audio-book-tts"
		update_template_spec
	fi
}

delete_resources() {
	# Find all Speech Services with the configured resource name prefix in resource group "TTS"
	local prefix="${AZURE_TTS_RESOURCE_NAME}"
	local services
	services=$(az cognitiveservices account list \
		--resource-group "TTS" \
		--query "[?kind=='SpeechServices' && starts_with(name, '${prefix}')].name" \
		--output tsv)

	# If no services found, return
	if [ -z "$services" ]; then
		echo "No Speech Services with prefix '${prefix}' found"
		return
	fi

	# Delete each found service
	while IFS= read -r service_name; do
		echo "Deleting Speech Service: $service_name"
		with_retry "delete $service_name" \
			az cognitiveservices account delete \
			--resource-group "TTS" \
			--name "$service_name"
	done <<<"$services"
}

purge_resources() {
	local subscriptionId
	subscriptionId="$(az account show --query id -o tsv)"
	echo "Purging all cognitive services in $subscriptionId"
	local deleted_ids
	deleted_ids="$(with_retry "list deleted accounts" \
		az rest --method get \
		--uri "/subscriptions/$subscriptionId/providers/Microsoft.CognitiveServices/deletedAccounts?api-version=2023-05-01" \
		--query "value[].id" -o tsv)"
	if [[ -n "$deleted_ids" ]]; then
		local id
		while IFS= read -r id; do
			[[ -n "$id" ]] || continue
			echo "Purging deleted account: $id"
			with_retry "purge $id" az resource delete --ids "$id"
		done <<<"$deleted_ids"
	else
		echo "No deleted accounts to purge"
	fi
	sleep 5
}

create_resources() {
	local tsId
	tsId=$(az ts show \
		--name "audio-book-tts" \
		--resource-group "TTS" \
		--version "v1" \
		--query "id" -o tsv)
	echo "Deploying template 'audio-book-tts' ($tsId) with parameters from deployment-input.json"
	with_retry "deploy template" \
		az deployment group create \
		--resource-group "TTS" \
		--template-spec "${tsId}" \
		--parameters "@/tmp/deployment-input.json"
}

show_keys() {
	local keys
	local key1
	local key2
	local resource_name="${AZURE_TTS_RESOURCE_NAME}"
	echo "Listing API keys for Speech Service '${resource_name}' in resource group 'TTS'"
	keys="$(az cognitiveservices account keys list \
		--resource-group "TTS" \
		--name "${resource_name}")"
	echo "$keys"
	key1="$(echo "$keys" | jq -r '.key1')"
	key2="$(echo "$keys" | jq -r '.key2')"

	# Validate that we actually received non-empty, non-null keys
	if [[ -z "$key1" || "$key1" == "null" || -z "$key2" || "$key2" == "null" ]]; then
		echo "ERROR: Failed to retrieve valid API keys from Azure."
		echo "  key1=${key1:-<empty>}  key2=${key2:-<empty>}"
		echo "Refusing to write Caddy config with invalid credentials."
		exit 4
	fi

	mkdir -p /etc/caddy
	# shellcheck disable=SC2016
	AZURE_TTS_KEY="$key2" envsubst '${AZURE_TTS_KEY} ${AZURE_LOCATION}' <./Caddyfile.template >/etc/caddy/Caddyfile

	local NL=$'\n'

	if [[ -n ${NOTE_MANAGE_URL:-} ]]; then
		if ! curl -X PUT -Fc="${key1}${NL}${key2}${NL}" -Fe="300d" "$NOTE_MANAGE_URL"; then
			echo "WARN: update key notes failed"
		else
			echo ""
		fi
	fi

	if [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]]; then
		if ! curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
			-d "chat_id=${TELEGRAM_CHAT_ID}" \
			-d "parse_mode=HTML" \
			-d text="<pre>${key1}</pre>${NL}${NL}<pre>${key2}</pre>${NL}"; then
			echo "WARN: send Telegram notification failed"
		else
			echo ""
		fi
	fi
}

start_caddy() {
	# Token Length Verification
	TOKEN_LENGTH=${#TTS_PROXY_ACCESS_TOKEN}

	if [ "$TOKEN_LENGTH" -le 11 ]; then
		echo "----------------------------------------------------------------------"
		echo "ERROR: TTS_PROXY_ACCESS_TOKEN is too short ($TOKEN_LENGTH chars)."
		echo "Your token must be at least 12 characters to prevent brute-force attacks."
		echo "Otherwise the proxy server will not be started."
		echo ""
		echo "To generate a secure, random 32-character token, run this command:"
		echo "openssl rand -base64 32 | tr -d '/+=' | cut -c1-32"
		echo "----------------------------------------------------------------------"
		exit 1
	fi

	exec caddy "run" "--config" "/etc/caddy/Caddyfile" "--adapter" "caddyfile"
}

if [[ ${TTS_DEBUG:-0} -gt 2 ]]; then
	echo "DRY RUN mode: skip recreation."
else
	ensure_resources
	delete_resources
	purge_resources
	create_resources
fi

show_keys
start_caddy
