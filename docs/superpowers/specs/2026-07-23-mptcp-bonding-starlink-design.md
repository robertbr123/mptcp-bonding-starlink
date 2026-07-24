# Design — Bonding de 3 Starlink com MPTCP + glorytun-tcp

**Data:** 2026-07-23
**Objetivo:** Agregar (bond) 3 links Starlink em uma única banda somada e entregar para ~70 clientes PPPoE, usando MPTCP nativo do kernel Linux + glorytun-tcp — de forma enxuta, sem o peso do OpenMPTCProuter que falhou acima de ~30 clientes.

---

## 1. Contexto e motivação

O usuário tentou OpenMPTCProuter (OMR) mas o serviço parava de funcionar ao passar de ~30 clientes PPPoE. Diagnóstico: o OMR empilha Shadowsocks + glorytun + OMR-VPN + LuCI + ubus + monitoramento pesado, saturando CPU/conntrack. A proposta é usar **apenas o núcleo** que faz o bonding (MPTCP no kernel + glorytun-tcp), removendo todas as camadas desnecessárias.

**Separação de responsabilidades (chave do design):**
- **A CCR MikroTik continua fazendo PPPoE + autenticação + NAT dos 70 clientes.** Não muda nada nela além do gateway de saída. O gargalo de PPPoE que derrubou o OMR não existe aqui — quem faz PPPoE é a CCR, hardware feito pra isso.
- **O computador Linux é SÓ o agregador MPTCP.** Recebe o tráfego da CCR de um lado e empurra tudo pelo túnel MPTCP através das 3 Starlink do outro.

---

## 2. Topologia

```
70 clientes PPPoE ──► CCR MikroTik ──► [LAN] ──► COMPUTADOR MPTCP ──┬─ Starlink 1 (100.64.0.1 %eth1)
                     (auth PPPoE + NAT)         (agregador puro)     ├─ Starlink 2 (100.64.0.1 %eth2)
                                                       │             └─ Starlink 3 (100.64.0.1 %eth3)
                                                       │
                                                       └──── túnel MPTCP (glorytun) ────► VPS ────► Internet
```

**Fluxo do pacote (ida):** cliente → CCR (PPPoE + NAT) → `192.168.100.1` (router) → `tun0` → MPTCP pelas 3 Starlink → `tun0` na VPS → NAT na VPS → Internet. Volta é o caminho inverso.

---

## 3. Hardware e sistema

| Ponta | Hardware | SO |
|---|---|---|
| **Router** | PC Core i5, 16GB RAM, SSD 258GB, **4 portas de rede** | **Ubuntu Server 24.04 LTS** (kernel 6.8) |
| **VPS** | VPS com IP público (10Gb) | **Ubuntu Server 24.04 LTS** |

**Por que Ubuntu 24.04:** kernel 6.8 traz a versão mais madura do MPTCP no Linux — melhor path manager, melhores schedulers e `ip mptcp` completo. Kernel novo lida melhor com links assimétricos e instáveis, e Starlink oscila muito. Server (sem GUI) para ficar leve.

**Decisão de arquitetura do túnel:** glorytun-tcp (é o mesmo túnel que o OMR usa por baixo, rodado standalone sem o peso). Alternativa considerada e descartada: shadowsocks-rust + tun2socks (mais peças pra amarrar, UDP menos natural).

---

## 4. Plano de endereços

```
ROUTER LINUX — 4 portas:
  eth1  →  Starlink 1   (DHCP: 100.64.0.x, gw 100.64.0.1)  → tabela de rota 101
  eth2  →  Starlink 2   (DHCP: 100.64.0.y, gw 100.64.0.1)  → tabela de rota 102
  eth3  →  Starlink 3   (DHCP: 100.64.0.z, gw 100.64.0.1)  → tabela de rota 103
  eth4  →  CCR (LAN)     IP fixo 192.168.100.1/24

TÚNEL (glorytun):
  tun0 no router  = 10.255.255.2/30
  tun0 na VPS     = 10.255.255.1/30

VPS:
  eth0 = IP público
```

Na CCR: trocar o gateway/upstream de saída para `192.168.100.1` (o IP de LAN do router Linux).

---

## 5. Componentes

### 5.1 Roteamento por interface das Starlink (o `100.64.0.1%ethX`)

**Problema:** as 3 Starlink em bypass entregam o mesmo gateway `100.64.0.1`. Sem tratamento, o Linux escolhe uma só e ignora as outras — o bonding morre.

**Solução:** uma tabela de roteamento e uma `ip rule` por interface. Exemplo eth1/tabela 101:

```bash
ip route add 100.64.0.1 dev eth1 scope link table 101
ip route add default via 100.64.0.1 dev eth1 table 101
ip rule add from <IP_da_Starlink_1> table 101
```

(idem eth2→102, eth3→103)

**Ajustes de kernel obrigatórios** (`/etc/sysctl.d/`) por causa do mesmo subnet em várias placas:

```
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.arp_filter = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.ip_forward = 1
```

**IPs dinâmicos:** cada dish dá IP por DHCP que pode mudar no reboot da antena. Por isso NÃO se chumba IP estático. Um **hook de DHCP** roda a cada lease/renovação e refaz rota + regra + endpoint MPTCP daquela interface automaticamente. Isso dá o auto-conserto essencial pra Starlink.

### 5.2 MPTCP — 3 subflows

O glorytun abre 1 conexão TCP; com MPTCP o kernel cria 3 subflows (um por Starlink).

```bash
ip mptcp limits set subflow 3 add_addr_accepted 3
ip mptcp endpoint add <IP_Starlink_1> dev eth1 subflow fullmesh
ip mptcp endpoint add <IP_Starlink_2> dev eth2 subflow fullmesh
ip mptcp endpoint add <IP_Starlink_3> dev eth3 subflow fullmesh
```

- `subflow` = abre caminho extra usando esse IP/interface
- `fullmesh` = usa todos os caminhos ao mesmo tempo (bonding real, soma de banda)

Scheduler: padrão do kernel 6.8 (menor latência primeiro), que se auto-ajusta quando uma antena piora. Só mexer se necessário.

**Dependência:** os endpoints usam os IPs das Starlink como origem; são as `ip rule from <IP_Starlink>` (5.1) que garantem que cada subflow saia pela antena física certa. 5.1 e 5.2 trabalham juntos e o mesmo hook de DHCP atualiza os dois.

### 5.3 glorytun-tcp (túnel)

Compila do fonte (`libsodium`, `build-essential`). Chave compartilhada única gerada uma vez (`glorytun keygen`), mesma nas duas pontas.

- **VPS (server):** escuta `0.0.0.0:65001`, `mptcp`, sobe `tun0=10.255.255.1/30`.
- **Router (client):** conecta `<IP_PUBLICO_VPS>:65001`, `mptcp`, sobe `tun0=10.255.255.2/30`.

O parâmetro `mptcp` transforma o socket TCP em MPTCP, ativando os subflows de 5.2.

**MTU/MSS (crítico p/ streaming):** `tun0` com MTU ~1400 + clamp de MSS (`TCPMSS --clamp-mss-to-pmtu`). Sem isso, vídeo 4K e sites grandes travam por fragmentação.

Ambas as pontas rodam como **serviço systemd** com reconexão automática e start no boot.

### 5.4 Roteamento do tráfego dos clientes + NAT

**No router:**
```bash
ip route add default dev tun0 table main
# FURO crítico: tráfego pro IP público da VPS sai pelas Starlink, NÃO pelo túnel (senão loop)
ip route add <IP_PUBLICO_VPS> ... (via tabelas das Starlink)
```

**Na VPS:**
```bash
net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

**NAT duplo (CCR + VPS):** de propósito. É o mais simples e streaming/redes sociais funcionam liso. Ajustável no futuro se precisar de IP público por cliente.

### 5.5 Failover e monitoramento

**Failover (automático):**
- Starlink cai → MPTCP detecta o subflow morto em segundos e para de usá-lo. A conexão NÃO cai; segue nas outras 2 com menos banda.
- Starlink volta → hook DHCP recria rota + endpoint → MPTCP reabre o 3º subflow sozinho.
- Com 1 antena só: lento mas online.

**Monitoramento (minúsculo, de propósito):** script simples mostrando `ip mptcp endpoint show`, `ss -M` e banda por interface (`vnstat` ou `/proc/net/dev`). Sem web pesada, sem LuCI, sem ubus. Grafana é opcional no futuro.

**Boot seguro:** serviços systemd na ordem correta (rotas → endpoints → glorytun). Reinicia o PC e volta sozinho.

---

## 6. Tráfego alvo

Clientes usam majoritariamente streaming/redes sociais (TikTok, Kwai, YouTube), que usam bastante **QUIC (UDP 443)**. Por isso o túnel carrega TCP **e** UDP (túnel completo via `tun`), não só TCP.

---

## 7. O que fica de fora (YAGNI)

- Sem Shadowsocks, LuCI, ubus, OMR-VPN.
- Sem múltiplos VPS como endpoint (1 VPS basta; os outros ficam de reserva).
- Sem NAT-1:1 / IP público por cliente na v1.
- Sem dashboard web na v1 (monitoramento por terminal).

---

## 8. Ordem de implementação (visão macro)

1. Instalar Ubuntu 24.04 nas duas pontas + habilitar MPTCP.
2. Configurar as 4 interfaces do router (3 Starlink DHCP + LAN fixa).
3. Roteamento por interface (tabelas + rules) + sysctl.
4. Hook de DHCP (auto-conserto).
5. Endpoints MPTCP.
6. glorytun nas duas pontas (compilar, chave, systemd, MTU/MSS).
7. Rota default → tun + furo pro IP da VPS + NAT na VPS.
8. Apontar gateway da CCR pro router.
9. Script de monitoramento + testes de failover.
