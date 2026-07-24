# MPTCP Bonding — 3x Starlink

Agregação (bonding) de 3 links Starlink em uma banda somada para ~70 clientes PPPoE,
usando **MPTCP nativo do kernel Linux + glorytun-tcp** — enxuto, sem o peso do OpenMPTCProuter.

## Arquitetura

```
70 clientes PPPoE ──► CCR MikroTik ──► [LAN] ──► COMPUTADOR MPTCP ──┬─ Starlink 1 (%eth1)
                     (PPPoE + NAT)              (agregador puro)      ├─ Starlink 2 (%eth2)
                                                     │                └─ Starlink 3 (%eth3)
                                                     └── túnel MPTCP (glorytun) ──► VPS ──► Internet
```

- **CCR MikroTik:** continua fazendo PPPoE + auth + NAT dos clientes (sem mudança além do gateway).
- **Computador Linux (i5, 16GB, Ubuntu 24.04):** só o agregador MPTCP das 3 Starlink.
- **VPS (Ubuntu 24.04, IP público):** termina o túnel e faz NAT pra internet.

## Documentação

- [Design completo](docs/superpowers/specs/2026-07-23-mptcp-bonding-starlink-design.md)

Referência MPTCP: https://www.mptcp.dev
