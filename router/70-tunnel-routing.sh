#!/usr/bin/env bash
# router/70-tunnel-routing.sh — default via tun0 + "furo" pro VPS (anti-loop).
# ROBUSTO: usa APENAS as Starlink que têm IP no momento (funciona com 1, 2 ou 3 antenas).
# O `onlink` dispensa o gateway 100.64.0.1 estar no subnet da interface (Starlink dá IP fora dele).
set -euo pipefail

VPS_IP="<IP_PUBLICO_VPS>"     # TROCAR pelo IP público da VPS
PEER="10.255.255.1"          # outra ponta do túnel (VPS)
# TROCAR pelos nomes reais das 3 Starlink (ver 00-discover.sh).
IFACES=(enp1s0 enp2s0 enp3s0)
GW="100.64.0.1"

# monta os nexthops só das antenas COM IP agora
nexthops=""
for i in "${IFACES[@]}"; do
  if ip -4 -o addr show dev "$i" 2>/dev/null | grep -q 'inet '; then
    nexthops="$nexthops nexthop via $GW dev $i weight 1 onlink"
  fi
done

# FURO anti-loop: o IP da VPS sai pelas Starlink (as que estiverem ativas), nunca pelo túnel.
if [ -n "$nexthops" ]; then
  ip route replace "$VPS_IP/32" $nexthops
  echo "furo VPS ($VPS_IP) via:$nexthops"
else
  echo "AVISO: nenhuma Starlink com IP — furo pro VPS não setado (túnel não vai subir)"
fi

# default do tráfego dos clientes vai pro túnel
ip route replace default via "$PEER" dev tun0
echo "default via tun0 OK"

# NAT: mascara o tráfego dos clientes pro túnel. ESSENCIAL — sem isso a VPS não sabe
# devolver a resposta pro IP do cliente (só conhece 10.255.255.2). Idempotente.
iptables -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
echo "NAT (masquerade) para tun0 OK"
