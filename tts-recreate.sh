#!/bin/bash

# shellcheck source=.env
source .env

if ! az login \
	--service-principal \
	--username "$AZURE_APPID" \
	--password "$AZURE_PASSWORD" \
	--tenant "$AZURE_TENANT"; then
	echo "cannot login with service-pricinpal"
	exit 1
fi

ensure_resources() {
	# Check if resource group "TTS" exists
	if ! az group show --name "TTS" >/dev/null; then
		echo "Resource group 'TTS' does not exist"
		exit 2
	else
		echo "Found resource group TTS"
	fi
	# Check if deployment "audio-book-tts" exists in resource group "TTS"
	if ! az resource list --query "[?name=='audio-book-tts' && type=='Microsoft.Resources/templateSpecs']" >/dev/null; then
		echo "Deployment 'audio-book-tts' does not exist in resource group 'TTS'"
		exit 3
	else
		echo "Found deployment audio-book-tts"
	fi
}

delete_resources() {
	# Find all Speech Services with prefix "audio-book-" in resource group "TTS"
	local services
	services=$(az cognitiveservices account list \
		--resource-group "TTS" \
		--query "[?kind=='SpeechServices' && starts_with(name, 'audio-book-')].name" \
		--output tsv)

	# If no services found, return
	if [ -z "$services" ]; then
		echo "No Speech Services with prefix 'audio-book-' found"
		return
	fi

	# Delete each found service
	while IFS= read -r service_name; do
		echo "Deleting Speech Service: $service_name"
		az cognitiveservices account delete \
			--resource-group "TTS" \
			--name "$service_name"
	done <<<"$services"
}

purge_resources() {
	local subscriptionId
	subscriptionId="$(az account show --query id -o tsv)"
	echo "Purging all cognitive services in $subscriptionId"
	az rest --method get \
		--uri "/subscriptions/$subscriptionId/providers/Microsoft.CognitiveServices/deletedAccounts?api-version=2023-05-01" \
		--query "value[].id" -o tsv | xargs az resource delete --ids
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
	az deployment group create \
		--resource-group "TTS" \
		--template-spec "${tsId}" \
		--parameters @deployment-input.json
}

show_keys() {
	local keys
	local key1
	local key2
	echo "Listing API keys for Speech Service 'audio-book-2' in resource group 'TTS'"
	keys="$(az cognitiveservices account keys list \
		--resource-group "TTS" \
		--name "audio-book-2")"
	echo "$keys"
	key1="$(echo "$keys" | jq -r '.key1')"
	key2="$(echo "$keys" | jq -r '.key2')"

	local NL=$'\n'

	if ! curl -X PUT -Fc="${key1}${NL}${key2}${NL}" -Fe="300d" "$NOTE_MANAGE_URL"; then
		echo "WARN: update key notes failed"
	fi

	if ! curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
		-d "chat_id=${TELEGRAM_CHAT_ID}" \
		-d "parse_mode=HTML" \
		-d text="<pre>${key1}</pre>${NL}${NL}<pre>${key2}</pre>${NL}"; then
		echo "WARN: send Telegram notification failed"
	fi
}

ensure_resources
delete_resources
purge_resources
create_resources
show_keys
