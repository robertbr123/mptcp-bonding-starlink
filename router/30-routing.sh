#!/usr/bin/env bash
# router/30-routing.sh — cria tabela de rota + regra por Starlink (idempotente).
# É a implementação do "100.64.0.1%ethX": cada antena sai fisicamente pela sua interface.
set -euo pipefail

# Mapa: interface -> tabela de roteamento. TROCAR pelos nomes reais (ver 00-discover.sh).
declare -A IFACE_TABLE=( [enp1s0]=101 [enp2s0]=102 [enp3s0]=103 )
GW="100.64.0.1"

setup_iface_routing() {
  local iface="$1" table="$2" ip
  ip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [ -z "$ip" ]; then
    echo "SKIP $iface: sem IP ainda"
    return 0
  fi

  # limpa rotas/regras antigas dessa tabela (idempotência)
  ip route flush table "$table" 2>/dev/null || true
  while ip rule del table "$table" 2>/dev/null; do :; done

  ip route add "$GW" dev "$iface" scope link table "$table"
  ip route add default via "$GW" dev "$iface" table "$table"
  ip rule add from "$ip" table "$table" priority "$table"
  echo "OK $iface ($ip) -> tabela $table"
}

for iface in "${!IFACE_TABLE[@]}"; do
  setup_iface_routing "$iface" "${IFACE_TABLE[$iface]}"
done
ip rule flush cache 2>/dev/null || true
