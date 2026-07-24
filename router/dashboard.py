#!/usr/bin/env python3
# router/dashboard.py — painel web simples de status do bonding (LAN).
# Acesse em http://192.168.100.1  (rede da CCR). Sem dependências: só Python3 stdlib.
# TROCAR os nomes das interfaces em IFACES (ver 00-discover.sh).
import subprocess, time, html, os
from http.server import BaseHTTPRequestHandler, HTTPServer

# Configurável por env (útil pra teste). Padrões = produção (i5).
LAN_IP = os.environ.get("GLORY_LAN_IP", "192.168.100.1")   # IP de LAN do router (0.0.0.0 = todos)
PORT   = int(os.environ.get("GLORY_PORT", "80"))
IFACES = os.environ.get("GLORY_IFACES", "enp1s0,enp2s0,enp3s0").split(",")  # Starlink 1/2/3
PEER   = os.environ.get("GLORY_PEER", "10.255.255.1")      # outra ponta do túnel (VPS)

def sh(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=6)
        return r.stdout.strip(), r.returncode
    except Exception:
        return "", 1

def out(cmd):  return sh(cmd)[0]
def ok(cmd):   return sh(cmd)[1] == 0

def iface_ip(i):
    return out(f"ip -4 -o addr show dev {i} | awk '{{print $4}}' | cut -d/ -f1 | head -n1")

def read_netdev():
    stats = {}
    try:
        for line in open("/proc/net/dev"):
            if ":" not in line: continue
            name, rest = line.split(":", 1)
            c = rest.split()
            stats[name.strip()] = (int(c[0]), int(c[8]))  # rx, tx bytes
    except Exception:
        pass
    return stats

def throughput():
    a = read_netdev(); time.sleep(1); b = read_netdev()
    res = {}
    for i in IFACES + ["tun0"]:
        if i in a and i in b:
            res[i] = ((b[i][0]-a[i][0])*8/1e6, (b[i][1]-a[i][1])*8/1e6)
        else:
            res[i] = (0.0, 0.0)
    return res

def path_status():
    st = {}
    for line in out("glorytun path").splitlines():
        p = line.split()
        if len(p) >= 4 and p[0] == "path":
            st[p[1]] = p[3]   # ip_local -> status
    return st

def badge(good, txt_ok, txt_bad):
    color = "#2ecc71" if good else "#e74c3c"
    return f'<span style="background:{color};color:#04121a;padding:2px 10px;border-radius:12px;font-weight:700">{html.escape(txt_ok if good else txt_bad)}</span>'

def page():
    client_up = out("systemctl is-active glorytun-client") == "active"
    wd_up     = out("systemctl is-active glorytun-watchdog.timer") == "active"
    restarts  = out("systemctl show glorytun-client --property=NRestarts --value") or "0"
    since     = out("systemctl show glorytun-client --property=ActiveEnterTimestamp --value")
    tun_up    = ok(f"ping -c1 -W1 -I tun0 {PEER}")
    thr       = throughput()
    st        = path_status()

    # linhas das antenas
    rows, ativas, agg_rx, agg_tx = [], 0, 0.0, 0.0
    for i in IFACES:
        ip = iface_ip(i)
        status = st.get(ip, "sem-IP" if not ip else "ausente")
        up = (status == "running")
        if up: ativas += 1
        rx, tx = thr.get(i, (0, 0))
        rows.append(f"""<tr>
          <td>{html.escape(i)}</td>
          <td>{badge(up, status, status)}</td>
          <td>{html.escape(ip or '—')}</td>
          <td style="text-align:right">{rx:6.1f} Mb</td>
          <td style="text-align:right">{tx:6.1f} Mb</td></tr>""")
    trx, ttx = thr.get("tun0", (0, 0))

    return f"""<!doctype html><html lang="pt-br"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>Bonding Starlink — Status</title>
<style>
 body{{font-family:system-ui,sans-serif;background:#0b1620;color:#e8eef2;margin:0;padding:24px}}
 h1{{font-size:20px;margin:0 0 4px}} .sub{{color:#7d94a6;font-size:13px;margin-bottom:20px}}
 .grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px;margin-bottom:22px}}
 .card{{background:#12212e;border:1px solid #1e3444;border-radius:12px;padding:16px}}
 .card .lbl{{color:#7d94a6;font-size:12px;text-transform:uppercase;letter-spacing:.5px}}
 .card .val{{font-size:22px;font-weight:800;margin-top:6px}}
 table{{width:100%;border-collapse:collapse;background:#12212e;border-radius:12px;overflow:hidden}}
 th,td{{padding:11px 14px;border-bottom:1px solid #1e3444;font-size:14px;text-align:left}}
 th{{color:#7d94a6;font-size:12px;text-transform:uppercase}}
 .foot{{color:#54697a;font-size:12px;margin-top:18px}}
</style></head><body>
<h1>🛰️ Bonding Starlink — Status</h1>
<div class="sub">atualiza sozinho a cada 5s</div>
<div class="grid">
 <div class="card"><div class="lbl">Túnel</div><div class="val">{badge(tun_up,'ONLINE','OFFLINE')}</div></div>
 <div class="card"><div class="lbl">Serviço glorytun</div><div class="val">{badge(client_up,'ativo','parado')}</div></div>
 <div class="card"><div class="lbl">Watchdog</div><div class="val">{badge(wd_up,'ativo','parado')}</div></div>
 <div class="card"><div class="lbl">Antenas ativas</div><div class="val">{ativas}/{len(IFACES)}</div></div>
 <div class="card"><div class="lbl">Quedas/reinícios</div><div class="val">{html.escape(restarts)}</div></div>
 <div class="card"><div class="lbl">Banda agregada (tun0)</div><div class="val">↓{trx:.0f} ↑{ttx:.0f} <span style="font-size:13px;color:#7d94a6">Mbit/s</span></div></div>
</div>
<table>
 <tr><th>Antena</th><th>Path</th><th>IP</th><th style="text-align:right">Download</th><th style="text-align:right">Upload</th></tr>
 {''.join(rows)}
</table>
<div class="foot">Túnel ativo desde: {html.escape(since or '—')} · reinícios contados pelo systemd (NRestarts)</div>
</body></html>"""

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        try: body = page().encode()
        except Exception as e: body = f"erro: {e}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass   # silencioso

def main():
    # espera o IP de LAN subir antes de fazer o bind (pula se for 0.0.0.0)
    if LAN_IP != "0.0.0.0":
        for _ in range(30):
            if ok(f"ip -4 addr show | grep -q {LAN_IP}"): break
            time.sleep(2)
    print(f"painel em http://{LAN_IP}:{PORT}  (interfaces: {IFACES})")
    HTTPServer((LAN_IP, PORT), H).serve_forever()

if __name__ == "__main__":
    main()
