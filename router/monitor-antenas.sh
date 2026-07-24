#!/usr/bin/env bash
# router/monitor-antenas.sh — saúde e banda POR ANTENA, sinalizando problemas (Ctrl-C sai).
# Mostra, a cada 1s: status do path de cada Starlink + throughput (↓/↑) + o agregado no tun0.
# Flags: ✅ path running | ❌ path caído/sem IP.
# TROCAR os nomes das interfaces se necessário (ver 00-discover.sh).
set -euo pipefail

IFACES=(enp1s0 enp2s0 enp3s0)

col_bytes() { # $1=iface $2=3(rx)|11(tx)
  awk -v i="$1" -v c="$2" -F'[: ]+' '$2==i{print $c; found=1} END{if(!found)print 0}' /proc/net/dev
}

while true; do
  # snapshot inicial
  declare -A RX0 TX0
  for i in "${IFACES[@]}" tun0; do
    RX0[$i]="$(col_bytes "$i" 3)"; TX0[$i]="$(col_bytes "$i" 11)"
  done
  sleep 1
  paths="$(glorytun path 2>/dev/null || true)"

  clear
  echo "===== ANTENAS (atualiza a cada 1s, Ctrl-C sai) ====="
  printf "%-9s %-4s %-9s %8s %8s  %s\n" "IFACE" "" "PATH" "DOWN" "UP" "IP/obs"
  up_total=0; running=0
  for i in "${IFACES[@]}"; do
    ip4="$(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    drx=$(( ($(col_bytes "$i" 3)  - ${RX0[$i]}) * 8 / 1000000 ))
    dtx=$(( ($(col_bytes "$i" 11) - ${TX0[$i]}) * 8 / 1000000 ))
    if [ -z "$ip4" ]; then
      printf "%-9s %-4s %-9s %8s %8s  %s\n" "$i" "❌" "SEM-IP" "-" "-" "cabo fora / dish reiniciando"
      continue
    fi
    st="$(echo "$paths" | awk -v a="$ip4" '$2==a{print $4}')"; [ -z "$st" ] && st="ausente"
    flag="✅"; [ "$st" != "running" ] && flag="❌"
    [ "$st" = "running" ] && running=$((running+1))
    printf "%-9s %-4s %-9s %6dMb %6dMb  %s\n" "$i" "$flag" "$st" "$drx" "$dtx" "$ip4"
  done

  # agregado no túnel
  arx=$(( ($(col_bytes tun0 3)  - ${RX0[tun0]}) * 8 / 1000000 ))
  atx=$(( ($(col_bytes tun0 11) - ${TX0[tun0]}) * 8 / 1000000 ))
  echo "-----------------------------------------------------"
  printf "%-9s %-4s %-9s %6dMb %6dMb  %s\n" "tun0" "Σ" "AGREGADO" "$arx" "$atx" "antenas ativas: $running/${#IFACES[@]}"
  [ "$running" -lt "${#IFACES[@]}" ] && echo ">> ATENÇÃO: nem todas as antenas estão ativas!"
done
