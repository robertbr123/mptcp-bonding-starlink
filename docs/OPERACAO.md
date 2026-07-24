# Operação e Runbook

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

## Comandos do dia a dia

```bash
systemctl status glorytun-client     # (router) / glorytun-server (VPS)
sudo systemctl restart glorytun-client
ip mptcp endpoint show               # 3/3 subflows?
journalctl -t mptcp-hook --since '1 hour ago'
```
