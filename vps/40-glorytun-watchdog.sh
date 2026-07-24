#!/usr/bin/env bash
# vps/40-glorytun-watchdog.sh — watchdog do LADO SERVIDOR (simétrico ao do router).
# Se o peer (router, 10.255.255.2) não responde pela tun0, reinicia o glorytun-server.
# Pega o caso do servidor "travar vivo" (processo up mas sem passar dados).
#
# ATENÇÃO: reiniciar o glorytun-server derruba o túnel de TODOS os clientes. Como esse
# watchdog não consegue distinguir "servidor travado" de "Starlink do router piscou"
# (os dois somem o ping pro peer), ele é DELIBERADAMENTE conservador: só reinicia após
# uma perda longa e sustentada, e com carência pra não entrar em loop de restart.
set -euo pipefail

PEER="10.255.255.2"   # tun0 do router (cliente)

WD_STATE=/run/glorytun-wd-fail            # contador de falhas seguidas
WD_LAST=/run/glorytun-wd-last-restart     # timestamp do último restart (carência)
FAIL_THRESHOLD=4                          # falhas seguidas antes de reiniciar (era 2)
GRACE=120                                 # segundos de carência após um restart

now="$(date +%s)"

# CARÊNCIA: acabou de reiniciar? Não rejulga — o glorytun-server leva alguns segundos
# pra recriar tun0, setar IP/NAT e o path voltar de 'probing' pra 'running'. Sem isso o
# watchdog reinicia antes de recuperar e vira TEMPESTADE de restart (derruba todos os
# clientes em loop).
last="$(cat "$WD_LAST" 2>/dev/null || echo 0)"
if [ $(( now - last )) -lt "$GRACE" ]; then
  logger -t glorytun-watchdog "em carencia pos-restart ($(( now - last ))s/${GRACE}s) — deixando reestabelecer"
  exit 0
fi

# TOLERANTE À PERDA: 5 pings (basta 1 responder). Só reinicia se FAIL_THRESHOLD checagens
# SEGUIDAS falharem — evita punir todos os clientes quando é só o router com 1 antena oscilando.
if ping -c5 -W2 -I tun0 "$PEER" >/dev/null 2>&1; then
  rm -f "$WD_STATE"; exit 0   # túnel vivo
fi

fails=$(( $(cat "$WD_STATE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$WD_STATE"
if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
  rm -f "$WD_STATE"
  echo "$now" > "$WD_LAST"     # marca o restart → ativa a carência de $GRACE s
  logger -t glorytun-watchdog "peer $PEER morto ($FAIL_THRESHOLD checagens seguidas) — reiniciando glorytun-server (carencia ${GRACE}s)"
  systemctl restart glorytun-server
else
  logger -t glorytun-watchdog "ping falhou ($fails/$FAIL_THRESHOLD) — aguardando confirmar antes de reiniciar"
fi
