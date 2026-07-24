#!/usr/bin/env bash
# router/monitor.sh — status enxuto do bonding (Ctrl-C pra sair).
# TROCAR os nomes das interfaces se necessário (ver 00-discover.sh).
set -euo pipefail

watch -n2 '
echo "== Subflows MPTCP (endpoints) =="; ip mptcp endpoint show
echo
echo "== Conexão MPTCP (ss -M) =="; ss -M 2>/dev/null | head -20
echo
echo "== Banda acumulada por interface =="
for i in enp1s0 enp2s0 enp3s0 tun0; do
  awk -v i="$i" -F"[: ]+" "\$2==i{printf \"%-8s rx=%8.1fMB tx=%8.1fMB\n\", i, \$3/1e6, \$11/1e6}" /proc/net/dev
done'
