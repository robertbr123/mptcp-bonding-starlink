#!/usr/bin/env bash
# router/test-resilience.sh — PROVA que o túnel volta sozinho: mata o glorytun e cronometra a volta.
# Rodar depois do install-router.sh, com o túnel funcionando.
set -euo pipefail

PEER="10.255.255.1"

echo "== antes =="
if ping -c2 -W2 "$PEER" >/dev/null 2>&1; then echo "túnel OK (respondendo)"; else echo "AVISO: túnel já estava down antes do teste"; fi

echo ">> matando o glorytun-client de propósito..."
sudo systemctl kill glorytun-client
t0=$SECONDS

echo ">> aguardando recuperação AUTOMÁTICA (Restart=always + watchdog 15s)..."
for _ in $(seq 1 45); do
  if ping -c1 -W1 "$PEER" >/dev/null 2>&1; then
    echo ">> ✅ VOLTOU SOZINHO em ~$((SECONDS - t0))s"
    echo -n "   glorytun-client: "; systemctl is-active glorytun-client
    exit 0
  fi
  sleep 1
done

echo ">> ❌ não voltou em 45s — investigar:"
echo "   systemctl status glorytun-client --no-pager"
echo "   journalctl -u glorytun-client -u glorytun-watchdog --no-pager -n 30"
exit 1
