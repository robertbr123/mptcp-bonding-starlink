#!/usr/bin/env bash
# router/80-glorytun-watchdog.sh — verifica o túnel; se o peer não responde, reinicia o cliente.
# Pega o caso do túnel "travar vivo" (processo rodando mas sem passar tráfego).
set -euo pipefail

PEER="10.255.255.1"   # outra ponta do túnel (VPS)

# 3 pings pela tun0; se TODOS falharem, o túnel está morto
if ping -c3 -W2 -I tun0 "$PEER" >/dev/null 2>&1; then
  exit 0   # túnel vivo, nada a fazer
fi

logger -t glorytun-watchdog "peer $PEER sem resposta pela tun0 — reiniciando glorytun-client"
systemctl restart glorytun-client
