#!/usr/bin/env bash
# router/45-glorytun-paths.sh — adiciona 1 path do glorytun por Starlink (o bonding).
# Roda DEPOIS que o glorytun client subiu (é ele que faz o multipath UDP).
# ATENÇÃO: a sintaxe exata do subcomando `glorytun path` será confirmada no router
# (variou entre versões). A forma abaixo segue o wiki oficial: `path up <IP_LOCAL>`.
set -euo pipefail

# TROCAR pelos nomes reais das 3 Starlink (ver 00-discover.sh).
IFACES=(enp1s0 enp2s0 enp3s0)

# Banda estimada por antena (ajuste conforme seus testes de velocidade).
# Ajuda o escalonador do glorytun a repartir o tráfego entre as 3.
RATE_TX="20mbit"
RATE_RX="150mbit"

for iface in "${IFACES[@]}"; do
  ip4="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [ -z "$ip4" ]; then
    echo "SKIP $iface: sem IP"
    continue
  fi
  # habilita o path saindo pela origem dessa Starlink
  glorytun path up "$ip4" rate tx "$RATE_TX" rx "$RATE_RX" || \
    echo "AVISO: 'glorytun path up $ip4' falhou — conferir sintaxe com 'glorytun path'"
  echo "path $ip4 (via $iface) habilitado"
done

echo "== paths atuais =="
glorytun path || true
