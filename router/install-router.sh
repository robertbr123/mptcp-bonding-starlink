#!/usr/bin/env bash
# router/install-router.sh — aplica tudo no router na ordem correta.
# ANTES DE RODAR: edite os <PLACEHOLDERS> e os nomes de interface em todos os scripts:
#   - 10-netplan.yaml       (nomes das interfaces)
#   - 30/40/50/70-*.sh      (mapa IFACE_TABLE e nomes S1/S2/S3)
#   - 60-glorytun-client.service e 70-tunnel-routing.sh  (<IP_PUBLICO_VPS>)
# E gere a chave: veja README/OPERACAO (Task 7) — /etc/glorytun/tunnel.key
set -euo pipefail
cd "$(dirname "$0")"

echo ">> [1/8] netplan (4 interfaces)"
sudo cp 10-netplan.yaml /etc/netplan/10-mptcp.yaml
sudo chmod 600 /etc/netplan/10-mptcp.yaml
sudo netplan apply

echo ">> [2/8] sysctl (MPTCP + multi-NIC)"
sudo cp 20-sysctl-mptcp.conf /etc/sysctl.d/90-mptcp.conf
sudo sysctl --system >/dev/null

echo ">> [3/8] roteamento por interface"
sudo bash 30-routing.sh

echo ">> [4/8] endpoints MPTCP"
sudo bash 40-mptcp-endpoints.sh

echo ">> [5/8] hook de auto-conserto (networkd-dispatcher)"
sudo apt install -y networkd-dispatcher
sudo cp 50-dhcp-hook.sh /etc/networkd-dispatcher/routable.d/50-mptcp
sudo chmod +x /etc/networkd-dispatcher/routable.d/50-mptcp

echo ">> [6/8] copiar scripts para /opt/mptcp/router (usados pelo systemd)"
sudo mkdir -p /opt/mptcp
sudo cp -r . /opt/mptcp/router

echo ">> [7/8] serviço glorytun client"
sudo cp 60-glorytun-client.service /etc/systemd/system/glorytun-client.service
sudo systemctl daemon-reload
sudo systemctl enable --now glorytun-client
sleep 5

echo ">> [8/8] roteamento do tráfego (default via tun + furo pro VPS)"
sudo bash 70-tunnel-routing.sh

echo
echo "== Router pronto. Verificações rápidas: =="
ip mptcp endpoint show
echo -n "IP público visto pela internet (deve ser o da VPS): "; curl -s ifconfig.me || true; echo
