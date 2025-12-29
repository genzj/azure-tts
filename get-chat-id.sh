#!/bin/bash
echo "fetching updates from telegram"
curl -L "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" |
	jq '.result[]|.message.chat|{"chat_id": .id, "first_name": .first_name, "username": .username }'
