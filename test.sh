#!/bin/bash

rm -f test_audio.mp3

NOW="$(date '+%Y年%m月%d日 %H点%M分%S秒')"

curl -D - -X POST http://localhost:9980/tts \
	-H "Content-Type: application/ssml+xml" \
	-H "X-Proxy-Token: test-1234567890" \
	-d "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'><voice name='zh-CN-XiaoxiaoNeural'><prosody rate='1.3'>你好，这是来自 Caddy 代理的语音测试。当前时间是 ${NOW}。</prosody></voice></speak>" \
	--output test_audio.mp3
