#!/usr/bin/env bash
# router/45-glorytun-paths.sh — adiciona 1 path do glorytun por Starlink (o bonding).
# Roda DEPOIS que o glorytun client subiu. SINTAXE VALIDADA EM CAMPO:
#   glorytun path addr <IP_LOCAL> set up
#   glorytun path addr <IP_LOCAL> set rate fixed tx <X> rx <Y>
# (o 'up' sozinho NÃO existe; é 'set up'. E 'rate' vem depois de 'set'.)
set -euo pipefail

# TROCAR pelos nomes reais das 3 Starlink (ver 00-discover.sh).
IFACES=(enp1s0 enp2s0 enp3s0)

# Banda por antena — CALIBRE conforme a banda REAL de cada Starlink (~85-90% dela).
# tx = upload, rx = download. Valor ALTO demais AFOGA o link e desincroniza a sessão
# (o túnel fica "running" mas não passa dados). Conservador é mais seguro que alto.
RATE_TX="20mbit"
RATE_RX="50mbit"

for iface in "${IFACES[@]}"; do
  ip4="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [ -z "$ip4" ]; then
    echo "SKIP $iface: sem IP"
    continue
  fi
  # 1) sobe o caminho saindo pela origem dessa Starlink
  glorytun path addr "$ip4" set up || \
    echo "AVISO: 'glorytun path addr $ip4 set up' falhou"
  # 2) define a taxa (sem isso a banda fica 0bit e nada trafega!).
  # ${VAR:-default} blinda contra RATE_TX/RATE_RX indefinido: mesmo se as linhas de cima
  # forem removidas/corrompidas, o rate NUNCA fica 0 (era o bug que travava o túnel).
  glorytun path addr "$ip4" set rate fixed tx "${RATE_TX:-20mbit}" rx "${RATE_RX:-50mbit}" || \
    echo "AVISO: definir rate de $ip4 falhou"
  echo "path $ip4 (via $iface): up + rate tx $RATE_TX rx $RATE_RX"
done

echo "== paths atuais =="
glorytun path || true
