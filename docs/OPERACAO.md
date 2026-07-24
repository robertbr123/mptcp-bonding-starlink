# Operação e Runbook

> **ATUALIZAÇÃO IMPORTANTE (arquitetura):** a versão atual do glorytun faz **multipath UDP nativo**
> (subcomando `path`) — **não usa o MPTCP do kernel**. O bonding das 3 Starlink é feito pelo próprio
> glorytun. Sintaxe confirmada:
> - Servidor: `glorytun bind dev tun0 keyfile <chave> from addr 0.0.0.0 port 65001 persist`
> - Cliente:  `glorytun bind dev tun0 keyfile <chave> to addr <IP_VPS> port 65001 persist`
> - Path (bonding): `glorytun path up <IP_LOCAL_STARLINK> rate tx <X> rx <Y>` (1 por antena)
> - O glorytun **não** configura o IP do `tun0` — a gente sobe com `ip addr add ... peer ... dev tun0`.
>
> **FIREWALL:** a porta **UDP 65001** precisa estar liberada de entrada na VPS (no firewall do
> provedor / security group **e** no ufw/iptables local, se houver).
>
> **CIFRA (pegadinha importante):** o glorytun escolhe a cifra pelo hardware — `aegis256` se a CPU
> tem AES-NI, senão `chacha20`. **As duas pontas TÊM que usar a mesma cifra**, senão o túnel conecta
> (handshake OK, ping falha) mas os DADOS não passam. O i5 e a VPS de produção têm AES → usam
> `aegis256` e batem. Mas **máquina sem AES** (algumas VPS baratas) cai no `chacha20` e dá mismatch.
> Solução nesses casos: adicionar a palavra **`chacha`** no comando `bind` das **DUAS** pontas.
>
> **Sequência que faz o path (bonding) funcionar** — validada em campo:
> ```
> glorytun path addr <IP_LOCAL> set up
> glorytun path addr <IP_LOCAL> set rate fixed tx 30mbit rx 200mbit
> ```
> Sem a linha do `rate`, a banda fica `0bit` e nada trafega (o túnel fica "running" mas sem dados).
>
> **MTU:** a Starlink em bypass não gosta de pacote grande. Em testes, MTU 1400 rendeu bem menos
> que 1300 (ex: 52 → 76 Mbit numa antena). Usar **`tun0` MTU 1300** nas duas pontas. Ajuste fino
> abaixo disso tem retorno baixo (a variação natural da Starlink é maior que o efeito do MTU).
>
> **Rate = capacidade REAL:** o `rate` do path é um marca-passo — deve bater com a banda real do link
> (ex: Starlink ~tx 30mbit / rx 150mbit). Setar alto demais (ex: 1000mbit num link de 40) faz o
> glorytun afogar o link e causar perda/retransmissão. `set rate auto` piorou nos testes; usar `fixed`.
>
> **Eficiência esperada:** 1 Starlink por túnel rende ~40-45% do nativo (perda/overhead são inerentes
> a passar Starlink por túnel UDP). O ganho real vem de somar as 3 antenas + muitos fluxos de clientes.



## Ordem de instalação (resumo)

### VPS
```bash
sudo bash common/build-glorytun.sh          # compila glorytun
glorytun keygen | sudo tee /etc/glorytun/tunnel.key >/dev/null && sudo chmod 600 /etc/glorytun/tunnel.key
sudo cat /etc/glorytun/tunnel.key           # copie essa chave para o router
sudo bash vps/install-vps.sh
```

### Router (PC i5)
1. Rode `sudo bash router/00-discover.sh` e **anote os nomes reais** das interfaces.
2. Edite os nomes (`enp1s0`...) e `<IP_PUBLICO_VPS>` em: `10-netplan.yaml`, `30/40/50/70-*.sh`, `60-glorytun-client.service`.
3. Instale o glorytun e cole a MESMA chave da VPS:
   ```bash
   sudo bash common/build-glorytun.sh
   echo 'COLE_A_MESMA_CHAVE_DA_VPS' | sudo tee /etc/glorytun/tunnel.key >/dev/null && sudo chmod 600 /etc/glorytun/tunnel.key
   ```
4. Rode o orquestrador:
   ```bash
   sudo bash router/install-router.sh
   ```

## Passo na CCR MikroTik (o que muda lá)

A CCR continua fazendo **PPPoE + autenticação + NAT dos clientes** — só muda para onde ela manda o tráfego de saída:

1. Ligar a interface LAN da CCR na `enp4s0` do router Linux (mesma rede `192.168.100.0/24`).
2. Dar um IP nessa interface da CCR, ex `192.168.100.2`.
3. Trocar a rota default da CCR para apontar o gateway `192.168.100.1` (o router Linux):
   ```
   /ip route add dst-address=0.0.0.0/0 gateway=192.168.100.1
   ```
   (remover/desativar as rotas default antigas que iam direto pras Starlink)
4. Garantir que o `masquerade`/NAT dos clientes na CCR continua ativo (não muda).

## Checar se está funcionando

```bash
ip mptcp endpoint show      # deve listar 3 endpoints (as 3 Starlink)
ss -M                       # deve mostrar a conexão MPTCP com múltiplos subflows
curl -s ifconfig.me         # deve retornar o IP PÚBLICO DA VPS
bash router/monitor.sh      # ver as 3 antenas trafegando juntas
```

Teste de agregação real:
```bash
# na VPS:
iperf3 -s
# no router:
iperf3 -c 10.255.255.1 -t 20 -P 4     # throughput deve superar 1 antena sozinha
```

## Troubleshooting

| Sintoma | Causa provável | O que checar |
|---|---|---|
| Túnel não sobe | chave diferente / porta bloqueada | `md5sum /etc/glorytun/tunnel.key` igual nas 2 pontas; firewall da VPS liberando 65001/tcp; `systemctl status glorytun-server` |
| Só 1 subflow ativo (sem bonding) | policy routing errado | `ip rule show` (3 regras from), `ip route show table 101/102/103`, `sysctl net.ipv4.conf.all.rp_filter` = 2 |
| Vídeo/sites grandes travam | MTU/MSS | `ip link show tun0` (mtu 1400); regra `TCPMSS --clamp-mss-to-pmtu` na VPS (`iptables -t mangle -S FORWARD`) |
| Tudo congela ao subir túnel | falta o "furo" anti-loop | `ip route get <IP_VPS>` deve sair pelas Starlink, NÃO por tun0 (rodar `70-tunnel-routing.sh`) |
| Starlink trocou IP e caiu subflow | hook não rodou | `journalctl -t mptcp-hook`; conferir `/etc/networkd-dispatcher/routable.d/50-mptcp` executável |
| Clientes sem internet | rota da CCR / NAT | CCR apontando gateway `192.168.100.1`; NAT da CCR ativo; `net.ipv4.ip_forward=1` nas duas pontas |

## Bufferbloat (latência sob carga)

Em teste (1 Starlink), ping ocioso ~53ms subiu a ~82ms (máx 110ms) sob download saturado —
bufferbloat **leve-moderado**, ok pra streaming. Dois controles aplicados/recomendados:

1. **`fq_codel`** (fila inteligente) — ligado por padrão via `net.core.default_qdisc=fq_codel` e
   explicitamente na `tun0` (nos `.service`). Segura a latência sob carga.
2. **Rate abaixo da capacidade (alavanca principal):** setar o `rate rx` de cada path um pouco
   ABAIXO da banda real da antena (ex: antena de 150 → `rx 130mbit`) impede a fila da Starlink de
   encher → latência baixa sob carga. **Calibrar no i5** medindo cada Starlink. Ajustar em
   `45-glorytun-paths.sh` (RATE_TX/RATE_RX).

## Resiliência (auto-recuperação)

Três camadas garantem que o túnel volta sozinho se cair:

**Vale para as DUAS pontas** (router E VPS) — a VPS também roda como serviço systemd com watchdog
próprio (`vps/40-glorytun-watchdog.*`, a cada 30s, pinga o router `10.255.255.2`). O servidor
morreu no teste só porque estava manual; via `install-vps.sh` ele é systemd e não cai assim.

1. **`Restart=always` + `RestartSec=3`** nos serviços — se o processo glorytun morrer, o systemd sobe de novo em 3s.
2. **`StartLimitIntervalSec=0`** — o systemd **nunca desiste** de reiniciar (sem o limite padrão de 5 tentativas).
3. **Watchdog em 2 níveis (`glorytun-watchdog.timer`, a cada 30s):**
   - **Nível 1 — túnel inteiro:** se o peer (`10.255.255.1`) não responde pela `tun0`, reinicia o `glorytun-client`.
   - **Nível 2 — por antena:** se o path de UMA Starlink caiu/sumiu (mas o túnel está vivo pelas outras), reabilita só aquele path — o bonding volta pra 3/3 sozinho.

### Monitor por antena
`bash router/monitor-antenas.sh` mostra, a cada 1s: status do path de cada Starlink (✅/❌),
throughput ↓/↑ por antena, o agregado no `tun0`, e avisa se alguma antena não está ativa.
Use pra flagrar rápido uma Starlink rendendo menos ou caída.

Testar a resiliência (script pronto):
```bash
sudo bash /opt/mptcp/router/test-resilience.sh   # mata o glorytun e cronometra a volta automática
```

> **⚠️ LIÇÃO DE CAMPO (importante):** em produção **NUNCA** rode o glorytun na mão (`glorytun bind ... &`).
> Rodado manual, ele **não se recupera** — se a Starlink trocar de IP (CGNAT) ou a sessão esfriar
> ficando ociosa, o túnel morre e fica morto (foi o que vimos no teste). **Sempre via systemd**
> (`install-router.sh`), que traz Restart=always + StartLimitIntervalSec=0 + watchdog. Aí ele volta
> sozinho em ≤15s. Em produção o túnel também quase nunca fica ocioso (70 clientes = tráfego constante),
> o que já reduz muito esse tipo de queda.

## Comandos do dia a dia

```bash
systemctl status glorytun-client     # (router) / glorytun-server (VPS)
sudo systemctl restart glorytun-client
ip mptcp endpoint show               # 3/3 subflows?
journalctl -t mptcp-hook --since '1 hour ago'
```
