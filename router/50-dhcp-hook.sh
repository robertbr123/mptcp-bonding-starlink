#!/usr/bin/env bash
# router/50-dhcp-hook.sh -> /etc/networkd-dispatcher/routable.d/50-mptcp
# networkd-dispatcher chama este hook quando uma interface fica "routable".
# Ele refaz rota + regra + endpoint MPTCP da interface que mudou de IP.
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

# refaz o endpoint MPTCP dessa interface: remove os que apontam pra ela e adiciona o atual
while read -r eid; do
  [ -n "$eid" ] && ip mptcp endpoint delete id "$eid" 2>/dev/null || true
done < <(ip mptcp endpoint show | awk -v d="$IFACE" '$0 ~ ("dev "d) {for(i=1;i<=NF;i++) if($i=="id"){print $(i+1)}}')
ip mptcp endpoint add "$ip4" dev "$IFACE" subflow fullmesh 2>/dev/null || true

logger -t mptcp-hook "reconfig $IFACE ip=$ip4 tabela=$tbl"
