#!/usr/bin/env bash
# router/80-glorytun-watchdog.sh — watchdog em 2 níveis:
#   (1) túnel INTEIRO morto  -> reinicia o glorytun-client (COM carência anti-storm)
#   (2) path de UMA antena caído/ausente -> reabilita só aquele path (bonding volta ao 3/3)
# Rodado pelo timer a cada ~30s.
set -euo pipefail

PEER="10.255.255.1"                       # outra ponta do túnel (VPS)
# TROCAR pelos nomes reais das 3 Starlink (ver 00-discover.sh).
IFACES=(enp5s0 enp7s0 enp8s0)

WD_STATE=/run/glorytun-wd-fail            # contador de falhas seguidas
WD_LAST=/run/glorytun-wd-last-restart     # timestamp do último restart (carência)
FAIL_THRESHOLD=3                          # falhas seguidas antes de reiniciar (era 2)
GRACE=90                                  # segundos de carência após um restart

now="$(date +%s)"

# CARÊNCIA: se acabamos de reiniciar, NÃO julga de novo — o glorytun leva alguns
# segundos pra subir tun0, setar rate e reestablecer os paths. Sem isso, o watchdog
# reinicia antes de ele se recuperar e vira uma TEMPESTADE de restart (o bug que
# derrubava o túnel por minutos com 1 antena instável).
last="$(cat "$WD_LAST" 2>/dev/null || echo 0)"
if [ $(( now - last )) -lt "$GRACE" ]; then
  logger -t glorytun-watchdog "em carencia pos-restart ($(( now - last ))s/${GRACE}s) — deixando reestabelecer"
  exit 0
fi

# (1) túnel inteiro morto? TOLERANTE À PERDA: 5 pings (basta 1 responder), e só reinicia
# se FAIL_THRESHOLD checagens SEGUIDAS falharem (evita reinício à toa quando a Starlink
# oscila / com 1 antena só).
if ping -c5 -W2 -I tun0 "$PEER" >/dev/null 2>&1; then
  rm -f "$WD_STATE"        # respondeu → zera o contador
else
  fails=$(( $(cat "$WD_STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$WD_STATE"
  if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
    rm -f "$WD_STATE"
    echo "$now" > "$WD_LAST"     # marca o restart → ativa a carência de $GRACE s
    logger -t glorytun-watchdog "TUNEL MORTO ($FAIL_THRESHOLD checagens seguidas) — reiniciando glorytun-client (carencia ${GRACE}s)"
    systemctl restart glorytun-client
  else
    logger -t glorytun-watchdog "ping falhou ($fails/$FAIL_THRESHOLD) — aguardando confirmar antes de reiniciar"
  fi
  exit 0
fi

# (2) túnel vivo: garante que CADA Starlink com IP tem um path 'running'.
# Delega ao 45-glorytun-paths.sh (fonte única do 'up' + rate calibrado) em vez de
# duplicar valores de rate aqui — evita divergência de banda entre os dois scripts.
paths="$(glorytun path 2>/dev/null || true)"
need_fix=0
for iface in "${IFACES[@]}"; do
  ip4="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [ -z "$ip4" ] && continue   # antena sem IP (cabo fora / dish reiniciando)
  if echo "$paths" | awk -v a="$ip4" '$2==a && $4=="running"{ok=1} END{exit !ok}'; then
    continue                  # já 'running' → ok
  fi
  logger -t glorytun-watchdog "PATH DA ANTENA $iface ($ip4) caido/ausente — reabilitando via 45-glorytun-paths.sh"
  need_fix=1
done
[ "$need_fix" = 1 ] && bash /opt/mptcp/router/45-glorytun-paths.sh >/dev/null 2>&1 || true
