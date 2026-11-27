import Foundation

/// 云服务器上的中转程序（Python 3，Ubuntu/Debian 自带，不用下载任何东西）和安装命令。
/// 客户端按每台电脑自己的口令、端口现场生成，复制到服务器控制台执行；不含任何写死的服务器信息
enum RelayServerScript {
    /// 中转程序本体：只转字节，看不到内容（浏览器到电脑是 HTTPS）
    static let relayPy = #"""
import asyncio, hmac, hashlib, os, secrets

TOKEN = os.environ["RELAY_TOKEN"].encode()
CTRL_PORT = int(os.environ.get("RELAY_CTRL_PORT", "21128"))
PUB_PORT = int(os.environ.get("RELAY_PUBLIC_PORT", "8443"))

ctrl = None            # 电脑那头的控制连接
pending = {}           # 访问编号 -> 等电脑接上的 future
per_ip = {}            # 每个来访 IP 同时开着几条连接

def mac(msg):
    return hmac.new(TOKEN, msg.encode(), hashlib.sha256).hexdigest()

async def pipe(r, w):
    try:
        while True:
            d = await r.read(65536)
            if not d:
                break
            w.write(d)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass

async def on_ctrl_port(reader, writer):
    global ctrl
    try:
        line = (await asyncio.wait_for(reader.readline(), 10)).decode(errors="ignore").strip()
    except Exception:
        writer.close(); return
    if line == "CTRL":
        nonce = secrets.token_hex(16)
        writer.write(f"NONCE {nonce}\n".encode()); await writer.drain()
        try:
            ans = (await asyncio.wait_for(reader.readline(), 10)).decode(errors="ignore").strip()
        except Exception:
            writer.close(); return
        if not hmac.compare_digest(ans, "AUTH " + mac(nonce)):
            writer.close(); return
        if ctrl is not None:
            try: ctrl.close()
            except Exception: pass
        ctrl = writer
        writer.write(b"OK\n"); await writer.drain()
        print("电脑已连上", flush=True)
        try:
            while await reader.readline():
                pass
        finally:
            if ctrl is writer:
                ctrl = None
                print("电脑断开", flush=True)
    elif line.startswith("DATA "):
        parts = line.split()
        if len(parts) == 3 and hmac.compare_digest(parts[2], mac(parts[1])) and parts[1] in pending:
            fut = pending.pop(parts[1])
            if not fut.done():
                fut.set_result((reader, writer)); return
        writer.close()
    else:
        writer.close()

async def on_public(reader, writer):
    ip = (writer.get_extra_info("peername") or ("?",))[0]
    if ctrl is None or len(pending) > 64 or per_ip.get(ip, 0) >= 32:
        writer.close(); return
    per_ip[ip] = per_ip.get(ip, 0) + 1
    cid = secrets.token_hex(8)
    fut = asyncio.get_running_loop().create_future()
    pending[cid] = fut
    try:
        ctrl.write(f"OPEN {cid}\n".encode()); await ctrl.drain()
        r2, w2 = await asyncio.wait_for(fut, 10)
        await asyncio.gather(pipe(reader, w2), pipe(r2, writer))
    except Exception:
        writer.close()
    finally:
        pending.pop(cid, None)
        per_ip[ip] -= 1
        if per_ip[ip] <= 0:
            per_ip.pop(ip, None)

async def ping():
    while True:
        await asyncio.sleep(20)
        if ctrl is not None:
            try:
                ctrl.write(b"PING\n"); await ctrl.drain()
            except Exception:
                pass

async def main():
    a = await asyncio.start_server(on_ctrl_port, "0.0.0.0", CTRL_PORT)
    b = await asyncio.start_server(on_public, "0.0.0.0", PUB_PORT)
    print(f"中转已启动：电脑连 {CTRL_PORT}，浏览器访问 {PUB_PORT}", flush=True)
    asyncio.create_task(ping())
    async with a, b:
        await asyncio.gather(a.serve_forever(), b.serve_forever())

asyncio.run(main())
"""#

    /// 一整段 shell：写入程序、口令，装成开机自启的服务，打开系统防火墙端口（有 ufw 时），最后打印状态
    static func make(token: String, ctrlPort: Int, publicPort: Int) -> String {
        """
        set -e
        # 端口被别的程序占着（常见是 RustDesk 服务端占 21114–21119）就先停下，说清楚
        systemctl stop cc-relay 2>/dev/null || true
        for p in \(ctrlPort) \(publicPort); do
          if ss -ltnH "sport = :$p" | grep -q .; then
            echo "端口 $p 已经被这个程序占用："; ss -ltnpH "sport = :$p"
            echo "请在客户端里把端口改成别的数字（比如 21128、8444），重新复制安装命令再执行。"; exit 1
          fi
        done
        mkdir -p /opt/cc-relay
        cat > /opt/cc-relay/relay.py <<'PYEOF'
        \(relayPy)
        PYEOF
        cat > /etc/cc-relay.env <<'ENVEOF'
        RELAY_TOKEN=\(token)
        RELAY_CTRL_PORT=\(ctrlPort)
        RELAY_PUBLIC_PORT=\(publicPort)
        ENVEOF
        chmod 600 /etc/cc-relay.env
        cat > /etc/systemd/system/cc-relay.service <<'SVCEOF'
        [Unit]
        Description=CC client relay
        After=network-online.target
        [Service]
        EnvironmentFile=/etc/cc-relay.env
        ExecStart=/usr/bin/python3 -u /opt/cc-relay/relay.py
        Restart=always
        RestartSec=3
        DynamicUser=yes
        [Install]
        WantedBy=multi-user.target
        SVCEOF
        systemctl daemon-reload
        systemctl enable --now cc-relay
        systemctl restart cc-relay
        if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow \(ctrlPort)/tcp; ufw allow \(publicPort)/tcp; fi
        sleep 2
        systemctl is-active cc-relay && journalctl -u cc-relay -n 3 --no-pager
        """
    }
}
