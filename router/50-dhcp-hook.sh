#!/usr/bin/env bash
# router/50-dhcp-hook.sh -> /etc/networkd-dispatcher/routable.d/50-mptcp
# networkd-dispatcher chama este hook quando uma interface fica "routable".
# Refaz rota + regra da interface que mudou de IP e reabilita o path do glorytun.
# É o auto-conserto: se uma Starlink cai e volta com IP novo, o bonding se refaz sozinho.
set -euo pipefail

IFACE="${IFACE:-${2:-}}"
[ -z "$IFACE" ] && exit 0

# TROCAR pelos nomes reais (ver 00-discover.sh).
declare -A IFACE_TABLE=( [enp1s0]=101 [enp2s0]=102 [enp3s0]=103 )
GW="100.64.0.1"

tbl="${IFACE_TABLE[$IFACE]:-}"
[ -z "$tbl" ] && exit 0   # ignora interfaces que não são Starlink (ex a LAN da CCR)

ip4="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[ -z "$ip4" ] && exit 0

# refaz rota/regra dessa antena
ip route flush table "$tbl" 2>/dev/null || true
while ip rule del table "$tbl" 2>/dev/null; do :; done
ip route add "$GW" dev "$IFACE" scope link table "$tbl"
ip route add default via "$GW" dev "$IFACE" table "$tbl"
ip rule add from "$ip4" table "$tbl" priority "$tbl"
ip rule flush cache 2>/dev/null || true

# reabilita o path do glorytun para o novo IP dessa Starlink (bonding)
# sintaxe validada: 'set up' + 'set rate fixed tx X rx Y'
glorytun path addr "$ip4" set up 2>/dev/null || true
glorytun path addr "$ip4" set rate fixed tx 30mbit rx 200mbit 2>/dev/null || true

logger -t mptcp-hook "reconfig $IFACE ip=$ip4 tabela=$tbl (path glorytun reabilitado)"
