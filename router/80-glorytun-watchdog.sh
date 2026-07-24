#!/usr/bin/env bash
# router/80-glorytun-watchdog.sh — watchdog em 2 níveis:
#   (1) túnel INTEIRO morto  -> reinicia o glorytun-client
#   (2) path de UMA antena caído/ausente -> reabilita só aquele path (bonding volta ao 3/3)
# Rodado pelo timer a cada 30s.
set -euo pipefail

PEER="10.255.255.1"                       # outra ponta do túnel (VPS)
# TROCAR pelos nomes reais das 3 Starlink (ver 00-discover.sh).
IFACES=(enp1s0 enp2s0 enp3s0)
RATE_TX="30mbit"
RATE_RX="200mbit"

# (1) túnel inteiro morto? TOLERANTE À PERDA: 5 pings (basta 1 responder), e só reinicia
# se DUAS checagens seguidas falharem (evita reinício à toa quando a Starlink oscila/1 antena).
WD_STATE=/run/glorytun-wd-fail
if ping -c5 -W2 -I tun0 "$PEER" >/dev/null 2>&1; then
  rm -f "$WD_STATE"        # respondeu → zera o contador
else
  fails=$(( $(cat "$WD_STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$WD_STATE"
  if [ "$fails" -ge 2 ]; then
    rm -f "$WD_STATE"
    logger -t glorytun-watchdog "TUNEL MORTO (2 checagens seguidas sem resposta) — reiniciando glorytun-client"
    systemctl restart glorytun-client
  else
    logger -t glorytun-watchdog "ping falhou ($fails/2) — aguardando confirmar antes de reiniciar"
  fi
  exit 0
fi

# (2) túnel vivo: garante que CADA Starlink com IP tem um path 'running'
paths="$(glorytun path 2>/dev/null || true)"
for iface in "${IFACES[@]}"; do
  ip4="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [ -z "$ip4" ] && continue   # antena sem IP (cabo fora / dish reiniciando)

  # já existe e está 'running'? então ok
  if echo "$paths" | awk -v a="$ip4" '$2==a && $4=="running"{ok=1} END{exit !ok}'; then
    continue
  fi

  logger -t glorytun-watchdog "PATH DA ANTENA $iface ($ip4) caido/ausente — reabilitando"
  glorytun path addr "$ip4" set up 2>/dev/null || true
  glorytun path addr "$ip4" set rate fixed tx "$RATE_TX" rx "$RATE_RX" 2>/dev/null || true
done
