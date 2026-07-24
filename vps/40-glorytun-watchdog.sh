#!/usr/bin/env bash
# vps/40-glorytun-watchdog.sh — watchdog do LADO SERVIDOR (simétrico ao do router).
# Se o peer (router, 10.255.255.2) não responde pela tun0, reinicia o glorytun-server.
# Pega o caso do servidor "travar vivo" (processo up mas sem passar dados).
set -euo pipefail

PEER="10.255.255.2"   # tun0 do router (cliente)

# TOLERANTE À PERDA: 5 pings (basta 1 responder), e só reinicia se DUAS checagens seguidas
# falharem (evita reinício à toa quando a Starlink oscila / o router está com 1 antena).
WD_STATE=/run/glorytun-wd-fail
if ping -c5 -W2 -I tun0 "$PEER" >/dev/null 2>&1; then
  rm -f "$WD_STATE"; exit 0   # túnel vivo
fi

fails=$(( $(cat "$WD_STATE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$WD_STATE"
if [ "$fails" -ge 2 ]; then
  rm -f "$WD_STATE"
  logger -t glorytun-watchdog "peer $PEER morto (2 checagens seguidas) — reiniciando glorytun-server"
  systemctl restart glorytun-server
else
  logger -t glorytun-watchdog "ping falhou ($fails/2) — aguardando confirmar"
fi
