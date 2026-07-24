#!/usr/bin/env python3
# router/dashboard.py — painel web de status do bonding Starlink (LAN).
# Acesse em http://192.168.50.1 (rede da CCR). Só Python3 stdlib, sem dependências.
#
# Config por env (padrões = produção i5):
#   GLORY_LAN_IP  IP de bind (0.0.0.0 = todos)          [192.168.50.1]
#   GLORY_PORT    porta                                  [80]
#   GLORY_IFACES  interfaces Starlink, separadas por ,   [enp1s0,enp2s0,enp3s0]
#   GLORY_PEER    IP do outro lado do túnel              [10.255.255.1]
#   GLORY_VPS_IP  IP público da VPS (p/ latência/perda por antena)   [vazio]
#   GLORY_DISHES  IPs de status de cada prato p/ obstrução (grpcurl) [vazio]
import subprocess, time, html, os, threading, collections
from http.server import BaseHTTPRequestHandler, HTTPServer

LAN_IP = os.environ.get("GLORY_LAN_IP", "192.168.50.1")
PORT   = int(os.environ.get("GLORY_PORT", "80"))
IFACES = [x for x in os.environ.get("GLORY_IFACES", "enp1s0,enp2s0,enp3s0").split(",") if x]
PEER   = os.environ.get("GLORY_PEER", "10.255.255.1")
VPS_IP = os.environ.get("GLORY_VPS_IP", "")
DISHES = [x for x in os.environ.get("GLORY_DISHES", "").split(",") if x]

STATE = {"ifaces": {}, "hist": collections.deque(maxlen=72), "agg": (0, 0),
         "drops": [], "dish": {}, "updated": 0}
LOCK  = threading.Lock()

def sh(cmd, t=6):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t)
        return r.stdout.strip(), r.returncode
    except Exception:
        return "", 1
def out(cmd, t=6): return sh(cmd, t)[0]
def ok(cmd, t=6):  return sh(cmd, t)[1] == 0

def iface_ip(i):
    return out(f"ip -4 -o addr show dev {i} 2>/dev/null | awk '{{print $4}}' | cut -d/ -f1 | head -n1")

def ping_stats(src, target):
    o = out(f"ping -c3 -W1 -I {src} {target}", 8)
    rtt, loss = None, 100.0
    for line in o.splitlines():
        if "packet loss" in line:
            try: loss = float([w for w in line.split(",") if "loss" in w][0].split("%")[0].strip())
            except Exception: pass
        if line.startswith("rtt") or "min/avg/max" in line:
            try: rtt = float(line.split("=")[1].split("/")[1])
            except Exception: pass
    return rtt, loss

def netdev():
    s = {}
    try:
        for line in open("/proc/net/dev"):
            if ":" not in line: continue
            n, rest = line.split(":", 1); c = rest.split()
            s[n.strip()] = (int(c[0]), int(c[8]))
    except Exception: pass
    return s

def path_status():
    st = {}
    for line in out("glorytun path").splitlines():
        p = line.split()
        if len(p) >= 4 and p[0] == "path": st[p[1]] = p[3]
    return st

def drop_events():
    o = out('journalctl -u glorytun-client -o short-iso --no-pager --since "-24h" 2>/dev/null '
            '| grep "Starting glorytun-client" | tail -6', 6)
    ev = []
    for l in o.splitlines():
        parts = l.split()
        if parts: ev.append(parts[0].replace("T", " ")[5:16])  # MM-DD HH:MM
    return list(reversed(ev))

def dish_stats():
    # OBSTRUÇÃO DO PRATO — best-effort. Precisa do binário 'grpcurl'. Os pratos ficam em
    # 192.168.100.1:9200 (livre, pois a LAN é 192.168.50.x). Reachability por dish: ver OPERACAO.md.
    res = {}
    if not DISHES or not ok("command -v grpcurl"): return res
    for d in DISHES:
        o = out(f"grpcurl -plaintext -max-time 4 -d '{{\"get_status\":{{}}}}' "
                f"{d}:9200 SpaceX.API.Device.Device/Handle", 6)
        obstr = None
        for line in o.splitlines():
            if "fractionObstructed" in line:
                try: obstr = round(float(line.split(":")[1].strip().rstrip(","))*100, 1)
                except Exception: pass
        res[d] = obstr
    return res

def sampler():
    prev = netdev(); tick = 0
    while True:
        time.sleep(5); tick += 1
        cur = netdev(); pstat = path_status(); data = {}
        for i in IFACES:
            ip = iface_ip(i)
            rx = tx = 0.0
            if i in prev and i in cur:
                rx = (cur[i][0]-prev[i][0])*8/1e6/5; tx = (cur[i][1]-prev[i][1])*8/1e6/5
            data[i] = {"ip": ip, "status": pstat.get(ip, "sem-IP" if not ip else "ausente"), "rx": rx, "tx": tx}
        agg_rx = agg_tx = 0.0
        if "tun0" in prev and "tun0" in cur:
            agg_rx = (cur["tun0"][0]-prev["tun0"][0])*8/1e6/5; agg_tx = (cur["tun0"][1]-prev["tun0"][1])*8/1e6/5

        if VPS_IP and tick % 3 == 0:      # latência/perda a cada ~15s
            for i in IFACES:
                if data[i]["ip"]:
                    r, l = ping_stats(data[i]["ip"], VPS_IP)
                    data[i]["rtt"], data[i]["loss"] = r, l

        drops = STATE.get("drops"); dish = STATE.get("dish")
        if tick % 6 == 0:                 # quedas + prato a cada ~30s
            drops = drop_events(); dish = dish_stats()

        with LOCK:
            for i in IFACES:              # preserva rtt/loss quando não medidos neste tick
                if "rtt" not in data[i]:
                    old = STATE["ifaces"].get(i, {})
                    data[i]["rtt"], data[i]["loss"] = old.get("rtt"), old.get("loss")
            STATE.update(ifaces=data, agg=(agg_rx, agg_tx), drops=drops or [], dish=dish or {}, updated=time.time())
            STATE["hist"].append(agg_rx)
        prev = cur

def uptime_str():
    mono = out("systemctl show glorytun-client -p ActiveEnterTimestampMonotonic --value")
    try:
        active = int(mono)/1e6; up = float(open("/proc/uptime").read().split()[0]); d = int(up-active)
        if d < 0: return "—"
        h, r = divmod(d, 3600); m, s = divmod(r, 60)
        return f"{h}h {m}min" if h else (f"{m}min {s}s" if m else f"{s}s")
    except Exception: return "—"

def badge(good, txt):
    c = "#2ecc71" if good else "#e74c3c"
    return f'<span style="background:{c};color:#04121a;padding:2px 10px;border-radius:12px;font-weight:700">{html.escape(txt)}</span>'

def sparkline(vals, w=520, h=90):
    if not vals: return ""
    mx = max(max(vals), 1.0); n = len(vals); step = w/max(n-1, 1)
    pts = " ".join(f"{i*step:.1f},{h-(v/mx*(h-8))-4:.1f}" for i, v in enumerate(vals))
    return (f'<svg viewBox="0 0 {w} {h}" width="100%" height="{h}" preserveAspectRatio="none">'
            f'<polyline fill="none" stroke="#2ecc71" stroke-width="2" points="{pts}"/>'
            f'<text x="4" y="14" fill="#7d94a6" font-size="11">pico {mx:.0f} Mbit/s</text></svg>')

def page():
    with LOCK:
        ifs = dict(STATE["ifaces"]); hist = list(STATE["hist"]); agg = STATE["agg"]
        drops = list(STATE["drops"]); dish = dict(STATE["dish"])
    client_up = out("systemctl is-active glorytun-client") == "active"
    wd_up     = out("systemctl is-active glorytun-watchdog.timer") == "active"
    restarts  = out("systemctl show glorytun-client --property=NRestarts --value") or "0"
    tun_up    = ok(f"ping -c1 -W1 -I tun0 {PEER}")

    rows, ativas = [], 0
    for i in IFACES:
        d = ifs.get(i, {}); st = d.get("status", "?"); up = st == "running"; ativas += up
        rtt = d.get("rtt"); loss = d.get("loss")
        rtt_s  = f"{rtt:.0f} ms" if rtt is not None else "—"
        loss_s = "—" if loss is None else f"{loss:.0f}%"
        warn = "⚠️" if (loss is not None and loss >= 5) or (rtt is not None and rtt >= 150) else ""
        rows.append(f"""<tr><td>{html.escape(i)}</td><td>{badge(up, st)}</td><td>{html.escape(d.get('ip') or '—')}</td>
          <td style="text-align:right">{d.get('rx',0):.0f}/{d.get('tx',0):.0f} Mb</td>
          <td style="text-align:right">{rtt_s}</td><td style="text-align:right">{loss_s} {warn}</td></tr>""")

    dish_html = ""
    if DISHES:
        cells = "".join(f'<div class="card"><div class="lbl">Prato {ip}</div><div class="val">'
                        f'{("obstr " + str(v) + "%") if v is not None else "N/A"}</div></div>'
                        for ip, v in (dish.items() or [(d, None) for d in DISHES]))
        dish_html = f'<h3 style="color:#7d94a6;font-size:13px;margin:22px 0 10px">Pratos Starlink</h3><div class="grid">{cells}</div>'

    drops_html = ("<br>".join(html.escape(x) for x in drops[:6])) or "nenhuma nas últimas 24h"

    return f"""<!doctype html><html lang="pt-br"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="5"><title>Bonding Starlink — Status</title>
<style>
 body{{font-family:system-ui,sans-serif;background:#0b1620;color:#e8eef2;margin:0;padding:24px}}
 h1{{font-size:20px;margin:0 0 4px}} .sub{{color:#7d94a6;font-size:13px;margin-bottom:20px}}
 .grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin-bottom:22px}}
 .card{{background:#12212e;border:1px solid #1e3444;border-radius:12px;padding:16px}}
 .card .lbl{{color:#7d94a6;font-size:12px;text-transform:uppercase;letter-spacing:.5px}}
 .card .val{{font-size:22px;font-weight:800;margin-top:6px}}
 table{{width:100%;border-collapse:collapse;background:#12212e;border-radius:12px;overflow:hidden}}
 th,td{{padding:11px 14px;border-bottom:1px solid #1e3444;font-size:14px;text-align:left}}
 th{{color:#7d94a6;font-size:12px;text-transform:uppercase}}
 .panel{{background:#12212e;border:1px solid #1e3444;border-radius:12px;padding:16px;margin-bottom:22px}}
 .foot{{color:#54697a;font-size:12px;margin-top:14px}}
</style></head><body>
<h1>🛰️ Bonding Starlink — Status</h1><div class="sub">atualiza sozinho a cada 5s</div>
<div class="grid">
 <div class="card"><div class="lbl">Túnel</div><div class="val">{badge(tun_up,'ONLINE' if tun_up else 'OFFLINE')}</div></div>
 <div class="card"><div class="lbl">glorytun</div><div class="val">{badge(client_up,'ativo' if client_up else 'parado')}</div></div>
 <div class="card"><div class="lbl">Watchdog</div><div class="val">{badge(wd_up,'ativo' if wd_up else 'parado')}</div></div>
 <div class="card"><div class="lbl">Antenas ativas</div><div class="val">{ativas}/{len(IFACES)}</div></div>
 <div class="card"><div class="lbl">Uptime do túnel</div><div class="val">{html.escape(uptime_str())}</div></div>
 <div class="card"><div class="lbl">Quedas/reinícios</div><div class="val">{html.escape(restarts)}</div></div>
</div>
<div class="panel"><div class="lbl" style="color:#7d94a6;font-size:12px;text-transform:uppercase">Banda agregada (últimos ~6 min) — agora ↓{agg[0]:.0f} ↑{agg[1]:.0f} Mbit/s</div>{sparkline(hist)}</div>
<table>
 <tr><th>Antena</th><th>Path</th><th>IP</th><th style="text-align:right">↓/↑ agora</th><th style="text-align:right">Latência</th><th style="text-align:right">Perda</th></tr>
 {''.join(rows)}
</table>
{dish_html}
<div class="panel"><div class="lbl" style="color:#7d94a6;font-size:12px;text-transform:uppercase">Últimas quedas (24h)</div><div style="margin-top:8px;font-size:14px">{drops_html}</div></div>
<div class="foot">latência/perda medida contra a VPS a cada 15s · quedas contadas pelo systemd</div>
</body></html>"""

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        try: body = page().encode()
        except Exception as e: body = f"erro: {e}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

def main():
    threading.Thread(target=sampler, daemon=True).start()
    if LAN_IP != "0.0.0.0":
        for _ in range(30):
            if ok(f"ip -4 addr show | grep -q {LAN_IP}"): break
            time.sleep(2)
    print(f"painel em http://{LAN_IP}:{PORT}  (ifaces={IFACES} vps={VPS_IP or '-'})")
    HTTPServer((LAN_IP, PORT), H).serve_forever()

if __name__ == "__main__":
    main()
