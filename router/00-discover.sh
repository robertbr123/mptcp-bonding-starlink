#!/usr/bin/env bash
# router/00-discover.sh — mostra as interfaces e ajuda a mapear as 3 Starlink + LAN
set -euo pipefail

echo "== Interfaces físicas =="
ip -br link show | grep -v -E '^(lo|tun|docker|veth)'
echo
echo "== IPs atuais (Starlink em bypass dá 100.64.0.0/10) =="
ip -4 -br addr show | grep -E '100\.64\.' || echo "  (nenhuma Starlink pegou IP ainda)"
echo
echo "Anote qual nome (ex enp1s0) é Starlink 1, 2, 3 e qual será a LAN da CCR."
echo "Depois edite esses valores em 30-routing.sh, 40-mptcp-endpoints.sh,"
echo "50-dhcp-hook.sh, 70-tunnel-routing.sh e 10-netplan.yaml."
