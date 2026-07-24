#!/usr/bin/env bash
# vps/install-vps.sh — aplica tudo na VPS na ordem correta.
# ANTES: rode common/build-glorytun.sh e crie /etc/glorytun/tunnel.key (Task 7).
set -euo pipefail
cd "$(dirname "$0")"

echo ">> [1/3] sysctl (forwarding)"
sudo cp 10-sysctl.conf /etc/sysctl.d/90-forward.conf
sudo sysctl --system >/dev/null

echo ">> [2/3] serviço glorytun server"
sudo cp 20-glorytun-server.service /etc/systemd/system/glorytun-server.service
sudo systemctl daemon-reload
sudo systemctl enable --now glorytun-server
sleep 3

echo ">> [3/3] NAT + forward + clamp MSS"
sudo bash 30-nat.sh

echo
echo "== VPS pronta. tun0: =="
ip -br addr show tun0 || echo "  (tun0 ainda não subiu — confira: systemctl status glorytun-server)"
echo "Porta 65001 (deve estar LISTEN):"; ss -ltn | grep 65001 || true
