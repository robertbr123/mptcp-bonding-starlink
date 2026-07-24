#!/usr/bin/env bash
# router/install-router.sh — aplica tudo no router na ordem correta.
# ANTES DE RODAR: edite os <PLACEHOLDERS> e os nomes de interface em todos os scripts:
#   - 10-netplan.yaml       (nomes das interfaces)
#   - 30/40/50/70-*.sh      (mapa IFACE_TABLE e nomes S1/S2/S3)
#   - 60-glorytun-client.service e 70-tunnel-routing.sh  (<IP_PUBLICO_VPS>)
# E gere a chave: veja README/OPERACAO (Task 7) — /etc/glorytun/tunnel.key
set -euo pipefail
cd "$(dirname "$0")"

echo ">> [1/9] netplan (4 interfaces)"
sudo cp 10-netplan.yaml /etc/netplan/10-mptcp.yaml
sudo chmod 600 /etc/netplan/10-mptcp.yaml
sudo netplan apply

echo ">> [2/9] sysctl (MPTCP + multi-NIC) + DNS público"
sudo cp 20-sysctl-mptcp.conf /etc/sysctl.d/90-mptcp.conf
sudo sysctl --system >/dev/null
# DNS fixo no systemd-resolved: NÃO depender do DNS da Starlink (que pode ficar
# inalcançável pelo túnel e derrubar a resolução de nomes — foi o que vimos no teste).
sudo sed -i 's/^#\?DNS=.*/DNS=1.1.1.1 8.8.8.8/' /etc/systemd/resolved.conf 2>/dev/null || true
sudo sed -i 's/^#\?FallbackDNS=.*/FallbackDNS=1.0.0.1 8.8.4.4/' /etc/systemd/resolved.conf 2>/dev/null || true
sudo systemctl restart systemd-resolved 2>/dev/null || true

echo ">> [3/9] roteamento por interface"
sudo bash 30-routing.sh

echo ">> [4/9] hook de auto-conserto (networkd-dispatcher)"
sudo apt install -y networkd-dispatcher
sudo cp 50-dhcp-hook.sh /etc/networkd-dispatcher/routable.d/50-mptcp
sudo chmod +x /etc/networkd-dispatcher/routable.d/50-mptcp

echo ">> [5/9] copiar scripts para /opt/mptcp/router (usados pelo systemd)"
sudo rm -rf /opt/mptcp/router          # limpa cópia antiga (evita aninhamento/arquivos velhos)
sudo mkdir -p /opt/mptcp
sudo cp -r . /opt/mptcp/router

echo ">> [6/9] serviço glorytun client (bind + paths por Starlink)"
sudo cp 60-glorytun-client.service /etc/systemd/system/glorytun-client.service
sudo systemctl daemon-reload
sudo systemctl enable --now glorytun-client
sleep 5

echo ">> [7/9] roteamento do tráfego (default via tun + furo pro VPS)"
sudo bash 70-tunnel-routing.sh

echo ">> [8/9] watchdog (reinicia o túnel sozinho se cair)"
sudo cp 80-glorytun-watchdog.service /etc/systemd/system/glorytun-watchdog.service
sudo cp 80-glorytun-watchdog.timer /etc/systemd/system/glorytun-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl enable --now glorytun-watchdog.timer

echo ">> [9/9] painel web de status (http://192.168.100.1)"
sudo cp dashboard.service /etc/systemd/system/dashboard.service
sudo systemctl daemon-reload
sudo systemctl enable --now dashboard

echo
echo "== Router pronto. Verificações rápidas: =="
echo "paths glorytun (deve listar as 3 Starlink):"; glorytun path || true
echo "CIFRA desta ponta (tem que ser IGUAL à da VPS — senão conecta mas não passa dados):"
glorytun show 2>/dev/null | grep -i cipher || true
echo -n "IP público visto pela internet (deve ser o da VPS): "; curl -s --max-time 8 ifconfig.me || true; echo
echo
echo "PAINEL: abra http://192.168.100.1 no navegador (pela rede da CCR) pra ver o status."
echo "DICA: rode 'sudo bash /opt/mptcp/router/test-resilience.sh' pra provar que o túnel volta sozinho."
