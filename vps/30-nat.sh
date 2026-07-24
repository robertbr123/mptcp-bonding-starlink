#!/usr/bin/env bash
# vps/30-nat.sh — NAT + forward + clamp de MSS na VPS (idempotente).
# O clamp de MSS é o que faz streaming/vídeo 4K não travar por causa do overhead do túnel.
set -euo pipefail

WAN="$(ip route show default | awk '{print $5; exit}')"   # interface pública
[ -z "$WAN" ] && { echo "ERRO: não achei a interface default (WAN)"; exit 1; }

add()  { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
tadd() { iptables -t "$1" -C "${@:2}" 2>/dev/null || iptables -t "$1" -A "${@:2}"; }

tadd nat POSTROUTING -o "$WAN" -j MASQUERADE
add FORWARD -i tun0 -o "$WAN" -j ACCEPT
add FORWARD -i "$WAN" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
tadd mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "NAT configurado na WAN=$WAN"

# persistir entre reboots (só instala o iptables-persistent se ainda não tiver —
# assim é leve pra rodar no ExecStartPost do glorytun-server a cada start)
if ! command -v netfilter-persistent >/dev/null 2>&1; then
  sudo apt install -y iptables-persistent >/dev/null 2>&1 || true
fi
command -v netfilter-persistent >/dev/null 2>&1 && sudo netfilter-persistent save || true
