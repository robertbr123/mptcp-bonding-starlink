# MPTCP Bonding Starlink — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produzir todos os scripts e configs prontos para agregar 3 Starlink em bonding via MPTCP + glorytun-tcp, servindo ~70 clientes PPPoE atrás de uma CCR MikroTik.

**Architecture:** Duas pontas — o **router** (PC i5, Ubuntu 24.04) que recebe o tráfego da CCR e agrega as 3 Starlink num túnel MPTCP; e a **VPS** (Ubuntu 24.04, IP público) que termina o túnel e faz NAT pra internet. O bonding é feito pelo MPTCP nativo do kernel 6.8 + glorytun-tcp standalone.

**Tech Stack:** Ubuntu Server 24.04 (kernel 6.8), MPTCP (`ip mptcp`), iproute2 (policy routing), netplan, glorytun-tcp, systemd, iptables, isc-dhcp-client hooks.

## Global Constraints

- **SO:** Ubuntu Server 24.04 LTS nas duas pontas (kernel >= 6.8).
- **Interfaces do router:** `eth1/eth2/eth3` = Starlink (DHCP), `eth4` = CCR (fixo `192.168.50.1/24`). Nomes reais podem variar (`enp1s0`...) — mapear no início.
- **Tabelas de roteamento:** 101/102/103 = Starlink 1/2/3.
- **Túnel:** `tun0` = `10.255.255.2/30` (router) / `10.255.255.1/30` (VPS). Porta glorytun `65001`.
- **Segredos:** a chave do glorytun (`/etc/glorytun/tunnel.key`) NUNCA entra no git (`.gitignore` já cobre `*.key`).
- **NAT:** CCR faz NAT dos clientes; VPS faz MASQUERADE na saída. NAT duplo é intencional.
- **Verificação:** cada tarefa é verificada rodando comando na máquina real; commits são dos scripts neste repo.

---

## Estrutura de arquivos

```
router/
  install-router.sh          # orquestrador: roda tudo na ordem
  10-netplan.yaml            # 4 interfaces (3 Starlink DHCP + LAN fixa)
  20-sysctl-mptcp.conf       # rp_filter/arp/ip_forward
  30-routing.sh              # tabelas 101/102/103 + ip rules (o %ethX)
  40-mptcp-endpoints.sh      # registra os 3 subflows
  50-dhcp-hook.sh            # auto-conserto quando Starlink troca IP
  60-glorytun-client.service # systemd do túnel (cliente)
  70-tunnel-routing.sh       # default via tun + "furo" pro IP da VPS
  monitor.sh                 # status enxuto do bonding
vps/
  install-vps.sh             # orquestrador da VPS
  10-sysctl.conf             # ip_forward
  20-glorytun-server.service # systemd do túnel (servidor)
  30-nat.sh                  # MASQUERADE + FORWARD + clamp MSS
common/
  build-glorytun.sh          # compila e instala o glorytun (as duas pontas)
```

---

## Task 0: Levantamento das interfaces reais e IP da VPS

**Files:**
- Create: `router/00-discover.sh`

**Interfaces:**
- Produces: mapeamento `ethX -> nome real` e `<IP_PUBLICO_VPS>` usados por todas as tarefas seguintes.

- [ ] **Step 1: Criar script de descoberta**

```bash
#!/usr/bin/env bash
# router/00-discover.sh — mostra as interfaces e ajuda a mapear as 3 Starlink + LAN
set -euo pipefail
echo "== Interfaces físicas =="
ip -br link show | grep -v -E '^(lo|tun|docker|veth)' 
echo
echo "== Leases DHCP ativos (Starlink dá 100.64.0.0/10) =="
ip -4 -br addr show | grep -E '100\.64\.' || echo "  (nenhuma Starlink pegou IP ainda)"
echo
echo "Anote: qual nome (ex enp1s0) é Starlink 1, 2, 3 e qual é a CCR."
```

- [ ] **Step 2: Rodar na máquina e anotar**

Run (no router): `sudo bash router/00-discover.sh`
Expected: lista das 4 interfaces; identificar quais 3 têm/terão IP `100.64.x.x` (Starlink) e qual será a LAN da CCR.

- [ ] **Step 3: Commit**

```bash
git add router/00-discover.sh
git commit -m "feat(router): script de descoberta de interfaces"
```

---

## Task 1: Configuração das 4 interfaces (netplan)

**Files:**
- Create: `router/10-netplan.yaml`

**Interfaces:**
- Consumes: mapeamento de nomes da Task 0.
- Produces: 3 interfaces Starlink com DHCP (SEM rota default global) + LAN fixa `192.168.50.1/24`.

- [ ] **Step 1: Criar o netplan**

```yaml
# router/10-netplan.yaml -> copiar para /etc/netplan/10-mptcp.yaml
# IMPORTANTE: trocar enp1s0/enp2s0/... pelos nomes reais da Task 0.
network:
  version: 2
  renderer: networkd
  ethernets:
    enp1s0:            # Starlink 1
      dhcp4: true
      dhcp4-overrides: { use-routes: false, use-dns: false }  # NAO instala default global
    enp2s0:            # Starlink 2
      dhcp4: true
      dhcp4-overrides: { use-routes: false, use-dns: false }
    enp3s0:            # Starlink 3
      dhcp4: true
      dhcp4-overrides: { use-routes: false, use-dns: false }
    enp4s0:            # LAN para a CCR
      dhcp4: false
      addresses: [192.168.50.1/24]
```

> `use-routes: false` é essencial: impede que as 3 Starlink briguem pela rota default global. A rota de cada uma vai só na sua tabela (Task 3).

- [ ] **Step 2: Aplicar e verificar**

Run (no router):
```bash
sudo cp router/10-netplan.yaml /etc/netplan/10-mptcp.yaml
sudo chmod 600 /etc/netplan/10-mptcp.yaml
sudo netplan apply
ip -4 -br addr show
```
Expected: as 3 Starlink com IP `100.64.x.x`, a LAN com `192.168.50.1`. `ip route show` (tabela main) NÃO deve ter default pelas Starlink.

- [ ] **Step 3: Commit**

```bash
git add router/10-netplan.yaml
git commit -m "feat(router): netplan das 4 interfaces (3 Starlink DHCP + LAN)"
```

---

## Task 2: Ajustes de kernel (sysctl)

**Files:**
- Create: `router/20-sysctl-mptcp.conf`

**Interfaces:**
- Produces: kernel preparado para mesmo-subnet-em-várias-placas + forwarding + MPTCP ligado.

- [ ] **Step 1: Criar o sysctl**

```conf
# router/20-sysctl-mptcp.conf -> /etc/sysctl.d/90-mptcp.conf
net.mptcp.enabled = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.arp_filter = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
```

- [ ] **Step 2: Aplicar e verificar**

Run (no router):
```bash
sudo cp router/20-sysctl-mptcp.conf /etc/sysctl.d/90-mptcp.conf
sudo sysctl --system >/dev/null
sysctl net.mptcp.enabled net.ipv4.ip_forward net.ipv4.conf.all.rp_filter
```
Expected: `net.mptcp.enabled = 1`, `net.ipv4.ip_forward = 1`, `net.ipv4.conf.all.rp_filter = 2`.

- [ ] **Step 3: Commit**

```bash
git add router/20-sysctl-mptcp.conf
git commit -m "feat(router): sysctl para MPTCP e mesmo-subnet multi-NIC"
```

---

## Task 3: Roteamento por interface das Starlink (o `100.64.0.1%ethX`)

**Files:**
- Create: `router/30-routing.sh`

**Interfaces:**
- Consumes: nomes das interfaces (Task 0), IPs DHCP atuais das Starlink.
- Produces: função `setup_iface_routing <iface> <table>` reutilizável; tabelas 101/102/103 com default via `100.64.0.1 dev <iface>` e `ip rule from <ip_starlink> table N`.

- [ ] **Step 1: Criar o script de roteamento**

```bash
#!/usr/bin/env bash
# router/30-routing.sh — cria tabela + regra por Starlink (idempotente)
set -euo pipefail

# Mapa: interface -> tabela. TROCAR pelos nomes reais.
declare -A IFACE_TABLE=( [enp1s0]=101 [enp2s0]=102 [enp3s0]=103 )
GW="100.64.0.1"

setup_iface_routing() {
  local iface="$1" table="$2"
  local ip
  ip="$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [ -z "$ip" ] && { echo "SKIP $iface: sem IP ainda"; return 0; }

  # limpa rotas/regras antigas dessa tabela (idempotência)
  ip route flush table "$table" 2>/dev/null || true
  ip rule del table "$table" 2>/dev/null || true

  ip route add "$GW" dev "$iface" scope link table "$table"
  ip route add default via "$GW" dev "$iface" table "$table"
  ip rule add from "$ip" table "$table" priority "$table"
  echo "OK $iface ($ip) -> tabela $table"
}

for iface in "${!IFACE_TABLE[@]}"; do
  setup_iface_routing "$iface" "${IFACE_TABLE[$iface]}"
done
ip rule flush cache 2>/dev/null || true
```

- [ ] **Step 2: Rodar e verificar que cada Starlink sai pela sua interface**

Run (no router):
```bash
sudo bash router/30-routing.sh
ip rule show | grep -E '10[123]'
for t in 101 102 103; do echo "== tabela $t =="; ip route show table $t; done
# testa saída por cada interface (deve responder pelas 3 antenas)
for ip in $(ip -o -4 addr show | awk '/100\.64\./{print $4}' | cut -d/ -f1); do
  echo "ping saindo de $ip:"; ping -c1 -W2 -I "$ip" 1.1.1.1 | tail -2
done
```
Expected: 3 regras (`from <ip_starlinkN> lookup 10N`), cada tabela com default via `100.64.0.1 dev ethN`, e os 3 pings respondendo (prova que as 3 antenas roteiam).

- [ ] **Step 3: Commit**

```bash
git add router/30-routing.sh
git commit -m "feat(router): policy routing por interface das Starlink"
```

---

## Task 4: Registrar os 3 subflows MPTCP

**Files:**
- Create: `router/40-mptcp-endpoints.sh`

**Interfaces:**
- Consumes: IPs atuais das Starlink; roteamento da Task 3.
- Produces: 3 endpoints MPTCP `subflow fullmesh`, um por Starlink; limites configurados.

- [ ] **Step 1: Criar o script de endpoints**

```bash
#!/usr/bin/env bash
# router/40-mptcp-endpoints.sh — registra 1 subflow por Starlink (idempotente)
set -euo pipefail
declare -A IFACE_TABLE=( [enp1s0]=101 [enp2s0]=102 [enp3s0]=103 )

ip mptcp endpoint flush 2>/dev/null || true
ip mptcp limits set subflow 3 add_addr_accepted 3

for iface in "${!IFACE_TABLE[@]}"; do
  ip="$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [ -z "$ip" ] && { echo "SKIP $iface: sem IP"; continue; }
  ip mptcp endpoint add "$ip" dev "$iface" subflow fullmesh
  echo "endpoint $ip dev $iface (subflow fullmesh)"
done
ip mptcp endpoint show
```

- [ ] **Step 2: Rodar e verificar**

Run (no router):
```bash
sudo bash router/40-mptcp-endpoints.sh
ip mptcp limits show
ip mptcp endpoint show
```
Expected: `subflow 3`, `add_addr_accepted 3`; 3 endpoints listados, cada um com `subflow fullmesh` e o IP da respectiva Starlink.

- [ ] **Step 3: Commit**

```bash
git add router/40-mptcp-endpoints.sh
git commit -m "feat(router): registra 3 subflows MPTCP (fullmesh)"
```

---

## Task 5: Hook de DHCP (auto-conserto)

**Files:**
- Create: `router/50-dhcp-hook.sh`

**Interfaces:**
- Consumes: `router/30-routing.sh` e `router/40-mptcp-endpoints.sh` (reaproveitados quando um IP muda).
- Produces: hook em `/etc/networkd-dispatcher/routable.d/` que refaz rota+rule+endpoint da interface que mudou.

- [ ] **Step 1: Criar o hook**

```bash
#!/usr/bin/env bash
# router/50-dhcp-hook.sh -> /etc/networkd-dispatcher/routable.d/50-mptcp
# networkd-dispatcher chama com IFACE no $2; refaz roteamento+endpoint dessa iface.
set -euo pipefail
IFACE="${2:-$IFACE}"
declare -A IFACE_TABLE=( [enp1s0]=101 [enp2s0]=102 [enp3s0]=103 )
GW="100.64.0.1"
tbl="${IFACE_TABLE[$IFACE]:-}"
[ -z "$tbl" ] && exit 0   # ignora interfaces que não são Starlink

ip="$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[ -z "$ip" ] && exit 0

# refaz rota/regra
ip route flush table "$tbl" 2>/dev/null || true
ip rule del table "$tbl" 2>/dev/null || true
ip route add "$GW" dev "$IFACE" scope link table "$tbl"
ip route add default via "$GW" dev "$IFACE" table "$tbl"
ip rule add from "$ip" table "$tbl" priority "$tbl"
ip rule flush cache 2>/dev/null || true

# refaz endpoint MPTCP (remove antigos dessa iface, adiciona o atual)
for old in $(ip mptcp endpoint show | awk -v d="$IFACE" '$0 ~ d {print $1}'); do
  ip mptcp endpoint delete id "$(ip mptcp endpoint show | awk -v a="$old" '$1==a{print $NF}')" 2>/dev/null || true
done
ip mptcp endpoint add "$ip" dev "$IFACE" subflow fullmesh 2>/dev/null || true
logger -t mptcp-hook "reconfig $IFACE ip=$ip tabela=$tbl"
```

- [ ] **Step 2: Instalar e testar simulando queda/volta de uma Starlink**

Run (no router):
```bash
sudo apt install -y networkd-dispatcher
sudo cp router/50-dhcp-hook.sh /etc/networkd-dispatcher/routable.d/50-mptcp
sudo chmod +x /etc/networkd-dispatcher/routable.d/50-mptcp
# simula: derruba e sobe uma Starlink
sudo ip link set enp1s0 down && sleep 3 && sudo ip link set enp1s0 up
sleep 8
journalctl -t mptcp-hook --no-pager | tail -3
ip mptcp endpoint show
```
Expected: log `reconfig enp1s0 ...` e os 3 endpoints presentes de novo após a interface voltar.

- [ ] **Step 3: Commit**

```bash
git add router/50-dhcp-hook.sh
git commit -m "feat(router): hook networkd para auto-conserto de rota+endpoint"
```

---

## Task 6: Compilar e instalar o glorytun (as duas pontas)

**Files:**
- Create: `common/build-glorytun.sh`

**Interfaces:**
- Produces: binário `glorytun`/`glorytun-tcp` em `/usr/local/bin`; diretório `/etc/glorytun/`.

- [ ] **Step 1: Criar o script de build**

```bash
#!/usr/bin/env bash
# common/build-glorytun.sh — compila e instala o glorytun (router e VPS)
set -euo pipefail
sudo apt update
sudo apt install -y build-essential git autoconf automake pkg-config libsodium-dev
tmp="$(mktemp -d)"; cd "$tmp"
git clone https://github.com/angt/glorytun
cd glorytun
git submodule update --init --recursive
./autogen.sh
./configure
make -j"$(nproc)"
sudo make install
sudo mkdir -p /etc/glorytun
echo "glorytun instalado:"; command -v glorytun-tcp || command -v glorytun
```

- [ ] **Step 2: Rodar nas duas pontas e verificar**

Run (router E VPS): `sudo bash common/build-glorytun.sh`
Expected: binário instalado; `glorytun-tcp --help` (ou `glorytun`) responde sem erro.

- [ ] **Step 3: Commit**

```bash
git add common/build-glorytun.sh
git commit -m "feat(common): script de build/instalação do glorytun"
```

---

## Task 7: Chave compartilhada do túnel

**Files:**
- (Nenhum no git — a chave NÃO é versionada)

**Interfaces:**
- Produces: `/etc/glorytun/tunnel.key` idêntico nas duas pontas.

- [ ] **Step 1: Gerar na VPS e copiar pro router**

Run (na VPS):
```bash
glorytun keygen | sudo tee /etc/glorytun/tunnel.key >/dev/null
sudo chmod 600 /etc/glorytun/tunnel.key
sudo cat /etc/glorytun/tunnel.key   # copie esse valor
```
Run (no router):
```bash
echo 'COLE_A_MESMA_CHAVE_AQUI' | sudo tee /etc/glorytun/tunnel.key >/dev/null
sudo chmod 600 /etc/glorytun/tunnel.key
```
Expected: `md5sum /etc/glorytun/tunnel.key` igual nas duas máquinas.

- [ ] **Step 2: (sem commit — chave é segredo, coberta pelo `.gitignore`)**

---

## Task 8: Serviço glorytun na VPS (servidor)

**Files:**
- Create: `vps/20-glorytun-server.service`

**Interfaces:**
- Consumes: chave (Task 7), binário (Task 6).
- Produces: `tun0 = 10.255.255.1/30` escutando na porta 65001 com MPTCP.

- [ ] **Step 1: Criar o unit**

```ini
# vps/20-glorytun-server.service -> /etc/systemd/system/glorytun-server.service
[Unit]
Description=glorytun MPTCP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/glorytun-tcp server \
  keyfile /etc/glorytun/tunnel.key \
  listen 0.0.0.0:65001 \
  mptcp
ExecStartPost=/bin/sh -c 'sleep 2; ip addr add 10.255.255.1/30 dev tun0 2>/dev/null; ip link set tun0 up; ip link set tun0 mtu 1400'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

> Nota: dependendo da versão do glorytun, `tun0`/IP podem ser setados via opções `dev tun0` e `ip 10.255.255.1`. O `ExecStartPost` garante IP+MTU caso a versão não faça sozinha. Ajustar na execução conforme o `--help`.

- [ ] **Step 2: Habilitar e verificar**

Run (na VPS):
```bash
sudo cp vps/20-glorytun-server.service /etc/systemd/system/glorytun-server.service
sudo systemctl daemon-reload
sudo systemctl enable --now glorytun-server
sleep 3
systemctl status glorytun-server --no-pager | head -5
ip -br addr show tun0
ss -ltnp | grep 65001
```
Expected: serviço `active (running)`, `tun0` com `10.255.255.1/30`, porta `65001` escutando.

- [ ] **Step 3: Commit**

```bash
git add vps/20-glorytun-server.service
git commit -m "feat(vps): systemd do glorytun server (MPTCP)"
```

---

## Task 9: Serviço glorytun no router (cliente)

**Files:**
- Create: `router/60-glorytun-client.service`

**Interfaces:**
- Consumes: chave (Task 7), IP público da VPS, endpoints MPTCP (Task 4).
- Produces: `tun0 = 10.255.255.2/30` conectado à VPS; os 3 subflows sobem sobre essa conexão.

- [ ] **Step 1: Criar o unit**

```ini
# router/60-glorytun-client.service -> /etc/systemd/system/glorytun-client.service
# TROCAR <IP_PUBLICO_VPS>.
[Unit]
Description=glorytun MPTCP client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'bash /opt/mptcp/router/30-routing.sh; bash /opt/mptcp/router/40-mptcp-endpoints.sh'
ExecStart=/usr/local/bin/glorytun-tcp client \
  keyfile /etc/glorytun/tunnel.key \
  host <IP_PUBLICO_VPS> port 65001 \
  mptcp
ExecStartPost=/bin/sh -c 'sleep 2; ip addr add 10.255.255.2/30 dev tun0 2>/dev/null; ip link set tun0 up; ip link set tun0 mtu 1400'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Colocar os scripts em /opt/mptcp, habilitar e verificar o bonding**

Run (no router):
```bash
sudo mkdir -p /opt/mptcp && sudo cp -r router /opt/mptcp/
sudo cp router/60-glorytun-client.service /etc/systemd/system/glorytun-client.service
sudo systemctl daemon-reload
sudo systemctl enable --now glorytun-client
sleep 5
ip -br addr show tun0
ping -c3 10.255.255.1                 # ping a outra ponta do túnel
ss -M                                 # deve mostrar a conexão MPTCP
ip mptcp endpoint show                # confirma os subflows
```
Expected: `tun0` com `10.255.255.2/30`, ping à `10.255.255.1` respondendo, `ss -M` mostrando a conexão MPTCP com múltiplos subflows.

- [ ] **Step 3: Commit**

```bash
git add router/60-glorytun-client.service
git commit -m "feat(router): systemd do glorytun client (MPTCP)"
```

---

## Task 10: NAT e forwarding na VPS

**Files:**
- Create: `vps/10-sysctl.conf`, `vps/30-nat.sh`

**Interfaces:**
- Consumes: `tun0` (Task 8), interface pública `eth0`.
- Produces: internet liberada pra tudo que sai do túnel, com clamp de MSS.

- [ ] **Step 1: Criar sysctl e NAT**

```conf
# vps/10-sysctl.conf -> /etc/sysctl.d/90-forward.conf
net.ipv4.ip_forward = 1
```

```bash
#!/usr/bin/env bash
# vps/30-nat.sh — NAT + forward + clamp MSS (idempotente via -C/-A)
set -euo pipefail
WAN="$(ip route show default | awk '{print $5; exit}')"   # interface pública
add() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
tadd() { iptables -t "$1" -C "${@:2}" 2>/dev/null || iptables -t "$1" -A "${@:2}"; }

tadd nat POSTROUTING -o "$WAN" -j MASQUERADE
add FORWARD -i tun0 -o "$WAN" -j ACCEPT
add FORWARD -i "$WAN" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
tadd mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
echo "NAT configurado na WAN=$WAN"
# persistir
sudo apt install -y iptables-persistent >/dev/null 2>&1 || true
sudo netfilter-persistent save
```

- [ ] **Step 2: Aplicar e verificar**

Run (na VPS):
```bash
sudo cp vps/10-sysctl.conf /etc/sysctl.d/90-forward.conf && sudo sysctl --system >/dev/null
sudo bash vps/30-nat.sh
sudo iptables -t nat -S POSTROUTING | grep MASQUERADE
sudo iptables -t mangle -S FORWARD | grep TCPMSS
```
Expected: regra MASQUERADE presente e regra TCPMSS presente.

- [ ] **Step 3: Commit**

```bash
git add vps/10-sysctl.conf vps/30-nat.sh
git commit -m "feat(vps): NAT, forwarding e clamp de MSS"
```

---

## Task 11: Roteamento do tráfego dos clientes no router (default via tun + furo pro VPS)

**Files:**
- Create: `router/70-tunnel-routing.sh`

**Interfaces:**
- Consumes: `tun0` (Task 9), tabelas Starlink (Task 3), IP público da VPS.
- Produces: default do tráfego dos clientes via `tun0`; rota específica pro IP da VPS pelas Starlink (anti-loop).

- [ ] **Step 1: Criar o script**

```bash
#!/usr/bin/env bash
# router/70-tunnel-routing.sh — manda tráfego dos clientes pro túnel, com furo pro VPS
set -euo pipefail
VPS_IP="<IP_PUBLICO_VPS>"     # TROCAR
PEER="10.255.255.1"          # outra ponta do túnel

# FURO anti-loop: o IP da VPS tem que sair pelas Starlink, não pelo túnel.
# Usa a tabela main com uma rota específica balanceada pelas 3 antenas.
ip route replace "$VPS_IP/32" \
  nexthop via 100.64.0.1 dev enp1s0 weight 1 \
  nexthop via 100.64.0.1 dev enp2s0 weight 1 \
  nexthop via 100.64.0.1 dev enp3s0 weight 1 2>/dev/null \
  || ip route replace "$VPS_IP/32" via 100.64.0.1 dev enp1s0

# default do tráfego (clientes vindos da CCR) vai pro túnel
ip route replace default via "$PEER" dev tun0

echo "rota VPS ($VPS_IP) pelas Starlink + default via tun0 OK"
ip route get "$VPS_IP" | head -1
ip route get 8.8.8.8 | head -1
```

- [ ] **Step 2: Aplicar e verificar que a internet sai pela VPS**

Run (no router):
```bash
sudo bash router/70-tunnel-routing.sh
ip route get 8.8.8.8      # deve ir via tun0
ip route get <IP_PUBLICO_VPS>   # deve ir via 100.64.0.1 (Starlink), NÃO tun0
curl -s ifconfig.me       # deve retornar o IP PÚBLICO DA VPS
```
Expected: `ip route get 8.8.8.8` via `tun0`; `ip route get <VPS>` via Starlink; `curl ifconfig.me` = IP público da VPS (prova que todo o tráfego sai agregado pela VPS).

- [ ] **Step 3: Commit**

```bash
git add router/70-tunnel-routing.sh
git commit -m "feat(router): default via tun0 + furo anti-loop pro IP da VPS"
```

---

## Task 12: Monitoramento enxuto

**Files:**
- Create: `router/monitor.sh`

**Interfaces:**
- Consumes: estado do MPTCP e das interfaces.
- Produces: visão rápida de subflows ativos e banda por antena.

- [ ] **Step 1: Criar o monitor**

```bash
#!/usr/bin/env bash
# router/monitor.sh — status enxuto do bonding (Ctrl-C pra sair)
set -euo pipefail
watch -n2 '
echo "== Subflows MPTCP =="; ip mptcp endpoint show
echo; echo "== Conexão MPTCP (ss -M) =="; ss -M 2>/dev/null | head -20
echo; echo "== Banda por interface =="; 
for i in enp1s0 enp2s0 enp3s0 tun0; do
  awk -v i="$i" -F"[: ]+" "\$2==i{printf \"%-8s rx=%.1fMB tx=%.1fMB\n\", i, \$3/1e6, \$11/1e6}" /proc/net/dev
done'
```

- [ ] **Step 2: Rodar e verificar**

Run (no router): `bash router/monitor.sh`
Expected: atualiza a cada 2s mostrando os 3 endpoints, a conexão MPTCP e a banda subindo nas 3 antenas quando há tráfego.

- [ ] **Step 3: Commit**

```bash
git add router/monitor.sh
git commit -m "feat(router): monitor enxuto do bonding"
```

---

## Task 13: Orquestradores e teste final de bonding

**Files:**
- Create: `router/install-router.sh`, `vps/install-vps.sh`

**Interfaces:**
- Consumes: todas as tarefas anteriores.
- Produces: um comando por ponta que aplica tudo na ordem; teste de agregação real.

- [ ] **Step 1: Criar orquestrador do router**

```bash
#!/usr/bin/env bash
# router/install-router.sh — aplica tudo no router, na ordem (revisar os <PLACEHOLDERS> antes!)
set -euo pipefail
cd "$(dirname "$0")"
sudo cp 10-netplan.yaml /etc/netplan/10-mptcp.yaml && sudo chmod 600 /etc/netplan/10-mptcp.yaml && sudo netplan apply
sudo cp 20-sysctl-mptcp.conf /etc/sysctl.d/90-mptcp.conf && sudo sysctl --system >/dev/null
sudo bash 30-routing.sh
sudo bash 40-mptcp-endpoints.sh
sudo apt install -y networkd-dispatcher
sudo cp 50-dhcp-hook.sh /etc/networkd-dispatcher/routable.d/50-mptcp && sudo chmod +x /etc/networkd-dispatcher/routable.d/50-mptcp
sudo mkdir -p /opt/mptcp && sudo cp -r . /opt/mptcp/router
sudo cp 60-glorytun-client.service /etc/systemd/system/glorytun-client.service
sudo systemctl daemon-reload && sudo systemctl enable --now glorytun-client
sleep 5
sudo bash 70-tunnel-routing.sh
echo "== Router pronto. Verifique: =="; ip mptcp endpoint show; curl -s ifconfig.me; echo
```

- [ ] **Step 2: Criar orquestrador da VPS**

```bash
#!/usr/bin/env bash
# vps/install-vps.sh — aplica tudo na VPS, na ordem
set -euo pipefail
cd "$(dirname "$0")"
sudo cp 10-sysctl.conf /etc/sysctl.d/90-forward.conf && sudo sysctl --system >/dev/null
sudo cp 20-glorytun-server.service /etc/systemd/system/glorytun-server.service
sudo systemctl daemon-reload && sudo systemctl enable --now glorytun-server
sleep 3
sudo bash 30-nat.sh
echo "== VPS pronta. tun0: =="; ip -br addr show tun0
```

- [ ] **Step 3: Teste final — provar a agregação (soma de banda)**

Run (na VPS): `iperf3 -s`
Run (no router):
```bash
# baixa via túnel; a soma deve superar a banda de UMA antena só
iperf3 -c 10.255.255.1 -t 20 -P 4
# em outro terminal, observar as 3 antenas subindo juntas:
bash router/monitor.sh
```
Expected: throughput agregado maior que o de uma Starlink isolada; `monitor.sh` mostra tráfego simultâneo nas 3 interfaces = bonding real funcionando.

- [ ] **Step 4: Teste de failover**

Run (no router): derrube 1 Starlink e confirme que a conexão continua.
```bash
sudo ip link set enp1s0 down     # derruba 1 antena
ping -c5 8.8.8.8                  # deve continuar respondendo (via as outras 2)
sudo ip link set enp1s0 up       # volta; hook reabre o 3º subflow
sleep 8; ip mptcp endpoint show  # 3 subflows de novo
```
Expected: internet não cai com 1 (ou 2) antenas fora; ao voltar, o subflow reaparece sozinho.

- [ ] **Step 5: Commit**

```bash
git add router/install-router.sh vps/install-vps.sh
git commit -m "feat: orquestradores de instalação router+vps e testes de bonding"
```

---

## Task 14: Documentação de operação (CCR + runbook)

**Files:**
- Create: `docs/OPERACAO.md`

**Interfaces:**
- Produces: passo da CCR (apontar gateway) + runbook de problemas comuns.

- [ ] **Step 1: Escrever o runbook**

Conteúdo: (1) na CCR MikroTik, trocar a rota default / gateway de saída para `192.168.50.1` e garantir que o NAT dos clientes continua ativo; (2) checklist de troubleshooting (túnel não sobe → checar chave/porta/firewall da VPS; só 1 subflow ativo → checar `ip rule`/rp_filter; vídeo trava → checar MTU/MSS); (3) comandos de status do dia a dia.

- [ ] **Step 2: Commit**

```bash
git add docs/OPERACAO.md
git commit -m "docs: runbook de operação e passo da CCR"
```

---

## Self-Review (cobertura do spec)

- §5.1 policy routing → Task 3 ✓
- §5.1 sysctl → Task 2 ✓
- §5.1 hook DHCP → Task 5 ✓
- §5.2 endpoints MPTCP → Task 4 ✓
- §5.3 glorytun (build/chave/systemd/MTU/MSS) → Tasks 6,7,8,9 ✓
- §5.4 rota default via tun + furo VPS → Task 11; NAT VPS → Task 10 ✓
- §5.5 failover → Task 13 (teste); monitor → Task 12 ✓
- §2 CCR aponta gateway → Task 14 ✓
- Interfaces/netplan → Tasks 0,1 ✓

Sem placeholders de plano (os `<IP_PUBLICO_VPS>` e nomes `enpXsY` são valores reais do ambiente, marcados para troca).
