#!/bin/bash
# Self-provisioning of Azure resources.
# Sourced by tts-recreate.sh — expects with_retry() to be defined.
#
# Functions:
#   provision_resource_group  — create resource group "TTS" if missing
#   provision_template_spec   — create or update template spec "audio-book-tts" v1

# Resolve the deployment-input.json location (same logic as create_resources).
_resolve_input_file() {
	if [[ -f "/input/deployment-input.json" ]]; then
		echo "/input/deployment-input.json"
	elif [[ -f "deployment-input.json" ]]; then
		echo "deployment-input.json"
	else
		echo ""
	fi
}

# Read the "location" parameter from deployment-input.json, default to westus2.
_resolve_location() {
	local inputfile
	inputfile="$(_resolve_input_file)"
	if [[ -n "$inputfile" ]]; then
		local loc
		loc="$(jq -r '.parameters.location.value // empty' "$inputfile" 2>/dev/null)"
		if [[ -n "$loc" ]]; then
			echo "$loc"
			return
		fi
	fi
	echo "westus2"
}

# Resolve the path to the ARM template bundled in the image.
_resolve_template_file() {
	if [[ -f "/app/data/audio-book-tts.json" ]]; then
		echo "/app/data/audio-book-tts.json"
	elif [[ -f "data/audio-book-tts.json" ]]; then
		echo "data/audio-book-tts.json"
	else
		echo ""
	fi
}

provision_resource_group() {
	local location
	location="$(_resolve_location)"
	echo "Resource group 'TTS' does not exist, creating in '$location'..."
	if ! with_retry "create resource group TTS" \
		az group create --name "TTS" --location "$location"; then
		echo "ERROR: Failed to create resource group 'TTS'"
		exit 2
	fi
	echo "Resource group 'TTS' created"
}

provision_template_spec() {
	local template_file
	template_file="$(_resolve_template_file)"
	if [[ -z "$template_file" ]]; then
		echo "ERROR: ARM template file 'data/audio-book-tts.json' not found"
		exit 3
	fi

	echo "Template spec 'audio-book-tts' v1 not found, creating..."
	if ! with_retry "create template spec audio-book-tts" \
		az ts create \
		--name "audio-book-tts" \
		--resource-group "TTS" \
		--version "v1" \
		--template-file "$template_file" \
		--yes; then
		echo "ERROR: Failed to create template spec 'audio-book-tts'"
		exit 3
	fi
	echo "Template spec 'audio-book-tts' v1 created"
}

update_template_spec() {
	local template_file
	template_file="$(_resolve_template_file)"
	if [[ -z "$template_file" ]]; then
		echo "WARN: $template_file does not exist; skip update check"
		return
	fi

	echo "Checking if template spec 'audio-book-tts' v1 is up to date..."
	local remote_template
	remote_template="$(az ts show \
		--name "audio-book-tts" \
		--resource-group "TTS" \
		--version "v1" \
		--query "mainTemplate" -o json 2>/dev/null)" || true

	if [[ -z "$remote_template" ]]; then
		echo "WARN: could not fetch remote template $remote_template; skip comparison"
		return
	fi

	local local_normalized remote_normalized
	local_normalized="$(jq -cS '.' "$template_file")"
	remote_normalized="$(echo "$remote_template" | jq -cS '.')"

	if [[ "$local_normalized" != "$remote_normalized" ]]; then
		echo "Template spec 'audio-book-tts' v1 is outdated, updating..."
		if ! with_retry "update template spec audio-book-tts" \
			az ts create \
			--name "audio-book-tts" \
			--resource-group "TTS" \
			--version "v1" \
			--template-file "$template_file" \
			--yes; then
			echo "WARN: Failed to update template spec, continuing with existing version"
		else
			echo "Template spec 'audio-book-tts' v1 updated"
		fi
	else
		echo "Template spec 'audio-book-tts' v1 is up to date"
	fi
}
