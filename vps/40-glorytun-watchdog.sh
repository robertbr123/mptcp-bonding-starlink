#!/usr/bin/env bash
# vps/40-glorytun-watchdog.sh — watchdog do LADO SERVIDOR (simétrico ao do router).
# Se o peer (router, 10.255.255.2) não responde pela tun0, reinicia o glorytun-server.
# Pega o caso do servidor "travar vivo" (processo up mas sem passar dados).
set -euo pipefail

PEER="10.255.255.2"   # tun0 do router (cliente)

if ping -c3 -W2 -I tun0 "$PEER" >/dev/null 2>&1; then
  exit 0   # túnel vivo
fi

logger -t glorytun-watchdog "peer $PEER sem resposta pela tun0 — reiniciando glorytun-server"
systemctl restart glorytun-server
