#!/usr/bin/env bash
# router/40-mptcp-endpoints.sh — registra 1 subflow MPTCP por Starlink (idempotente).
# Depende do roteamento de 30-routing.sh (cada IP sai pela sua antena).
set -euo pipefail

# TROCAR pelos nomes reais (ver 00-discover.sh).
declare -A IFACE_TABLE=( [enp1s0]=101 [enp2s0]=102 [enp3s0]=103 )

ip mptcp endpoint flush 2>/dev/null || true
ip mptcp limits set subflow 3 add_addr_accepted 3

for iface in "${!IFACE_TABLE[@]}"; do
  ip4="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [ -z "$ip4" ]; then
    echo "SKIP $iface: sem IP"
    continue
  fi
  ip mptcp endpoint add "$ip4" dev "$iface" subflow fullmesh
  echo "endpoint $ip4 dev $iface (subflow fullmesh)"
done

echo "== limites =="; ip mptcp limits show
echo "== endpoints =="; ip mptcp endpoint show
