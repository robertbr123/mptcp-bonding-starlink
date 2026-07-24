#!/usr/bin/env bash
# vps/install-vps.sh — aplica tudo na VPS na ordem correta (systemd, nunca manual).
# ANTES: rode common/build-glorytun.sh e crie /etc/glorytun/tunnel.key (mesma chave do router).
set -euo pipefail
cd "$(dirname "$0")"

echo ">> [1/4] sysctl (forwarding)"
sudo cp 10-sysctl.conf /etc/sysctl.d/90-forward.conf
sudo sysctl --system >/dev/null

echo ">> [2/4] copiar scripts para /opt/mptcp/vps (usados pelo systemd)"
sudo rm -rf /opt/mptcp/vps          # limpa cópia antiga (evita aninhamento/arquivos velhos)
sudo mkdir -p /opt/mptcp
sudo cp -r . /opt/mptcp/vps

echo ">> [3/4] serviço glorytun server + watchdog"
sudo cp 20-glorytun-server.service /etc/systemd/system/glorytun-server.service
sudo cp 40-glorytun-watchdog.service /etc/systemd/system/glorytun-watchdog.service
sudo cp 40-glorytun-watchdog.timer /etc/systemd/system/glorytun-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl enable --now glorytun-server
sudo systemctl enable --now glorytun-watchdog.timer
sleep 3

echo ">> [4/4] NAT + forward + clamp MSS"
sudo bash 30-nat.sh

echo
echo "== VPS pronta. Verificações: =="
echo -n "servidor: "; systemctl is-active glorytun-server
echo -n "watchdog: "; systemctl is-active glorytun-watchdog.timer
echo "tun0:"; ip -br addr show tun0 || echo "  (tun0 ainda não subiu — veja: systemctl status glorytun-server)"
echo "porta UDP 65001 (deve estar LISTEN):"; sudo ss -lun | grep 65001 || echo "  (nada escutando?)"
echo "CIFRA (tem que ser IGUAL à do router):"; sudo glorytun show 2>/dev/null | grep -i cipher || true
