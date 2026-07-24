#!/usr/bin/env bash
# router/70-tunnel-routing.sh — manda o tráfego dos clientes pro túnel, com "furo" pro VPS.
# O furo é anti-loop: o pacote destinado ao IP público da VPS NÃO pode entrar no túnel,
# senão o túnel tentaria trafegar dentro dele mesmo e tudo congela.
set -euo pipefail

VPS_IP="<IP_PUBLICO_VPS>"     # TROCAR pelo IP público da VPS
PEER="10.255.255.1"          # outra ponta do túnel (VPS)

# TROCAR pelos nomes reais das 3 Starlink (ver 00-discover.sh).
S1=enp1s0; S2=enp2s0; S3=enp3s0
GW="100.64.0.1"

# FURO anti-loop: o IP da VPS sai pelas Starlink (balanceado nas 3), nunca pelo túnel.
if ! ip route replace "$VPS_IP/32" \
      nexthop via "$GW" dev "$S1" weight 1 \
      nexthop via "$GW" dev "$S2" weight 1 \
      nexthop via "$GW" dev "$S3" weight 1 2>/dev/null; then
  # fallback: se alguma antena estiver fora, usa a primeira disponível
  ip route replace "$VPS_IP/32" via "$GW" dev "$S1"
fi

# default do tráfego dos clientes (vindo da CCR) vai pro túnel
ip route replace default via "$PEER" dev tun0

echo "rota VPS ($VPS_IP) pelas Starlink + default via tun0 OK"
echo "== teste de rota =="
ip route get "$VPS_IP" | head -1
ip route get 8.8.8.8 | head -1
