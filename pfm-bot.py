#!/usr/bin/env python3
"""
PFM Central Telegram Bot v1.2
Connects to multiple PFM servers via SSH
Features: traffic tracking, 6h auto-backup, edit servers
"""

import json, os, sys, time, signal, subprocess, threading
from urllib.request import Request, urlopen
from urllib.parse import urlencode
from urllib.error import URLError

CONFIG_DIR = "/etc/pfm-bot"
CONFIG_FILE = f"{CONFIG_DIR}/config.json"
LOG_FILE = "/var/log/pfm-bot.log"

# ─── Config ───
def load_config():
    if not os.path.exists(CONFIG_FILE):
        print(f"Error: {CONFIG_FILE} not found")
        sys.exit(1)
    with open(CONFIG_FILE) as f:
        return json.load(f)

CFG = load_config()
TOKEN = CFG.get("bot_token", "")
ADMIN_ID = str(CFG.get("admin_id", ""))
SERVERS = CFG.get("servers", [])
API = f"https://api.telegram.org/bot{TOKEN}"

def save_config():
    """Save config to file"""
    with open(CONFIG_FILE, 'w') as f:
        json.dump(CFG, f, indent=2)

def reload_servers():
    """Reload server list from config"""
    global CFG, SERVERS
    CFG = load_config()
    SERVERS = CFG.get("servers", [])

if not TOKEN:
    print("Error: bot_token not set"); sys.exit(1)

# ─── Telegram API ───
def tg(method, data=None):
    try:
        if data:
            body = json.dumps(data).encode()
            req = Request(f"{API}/{method}", body, {"Content-Type": "application/json"})
        else:
            req = Request(f"{API}/{method}")
        resp = urlopen(req, timeout=60)
        return json.loads(resp.read())
    except Exception as e:
        print(f"TG error: {e}")
        return None

def send(chat_id, text, buttons=None):
    data = {"chat_id": chat_id, "text": text, "parse_mode": "HTML"}
    if buttons:
        data["reply_markup"] = {"inline_keyboard": buttons}
    tg("sendMessage", data)

def edit(chat_id, msg_id, text, buttons=None):
    data = {"chat_id": chat_id, "message_id": msg_id, "text": text, "parse_mode": "HTML"}
    if buttons:
        data["reply_markup"] = {"inline_keyboard": buttons}
    tg("editMessageText", data)

def answer_cb(cb_id, text=""):
    tg("answerCallbackQuery", {"callback_query_id": cb_id, "text": text})

def btn(text, data):
    return {"text": text, "callback_data": data}

# ─── SSH ───
def ssh_cmd(server, cmd, timeout=10):
    """Execute command on remote server via SSH"""
    s = server
    ssh_args = []

    # Password auth via sshpass
    if s.get("password"):
        ssh_args = [
            "sshpass", "-p", s["password"],
            "ssh", "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=5",
        ]
    else:
        # Key auth
        ssh_args = [
            "ssh", "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=5",
            "-o", "BatchMode=yes",
        ]
        if s.get("key"):
            ssh_args += ["-i", s["key"]]

    if s.get("port", 22) != 22:
        ssh_args += ["-p", str(s["port"])]
    ssh_args.append(f"{s.get('user', 'root')}@{s['host']}")
    ssh_args.append(cmd)

    try:
        r = subprocess.run(ssh_args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "Timeout"
    except Exception as e:
        return -1, "", str(e)

def ssh_pfm_json(server):
    """Sync + get PFM data in ONE SSH call (works with any pfm.sh version)"""
    code, out, err = ssh_cmd(server, "pfm sync 2>/dev/null; pfm json", timeout=15)
    if code == 0 and out:
        try:
            idx = out.find('{')
            if idx >= 0:
                return json.loads(out[idx:])
        except:
            return None
    return None

def ssh_pfm_cmd(server, cmd):
    """Run pfm-cmd on server"""
    code, out, err = ssh_cmd(server, f"pfm-cmd {cmd}")
    return code == 0, out or err

def ssh_pfm_sync(server):
    """Sync traffic on server (only used by manual Sync All button)"""
    ssh_cmd(server, "pfm sync", timeout=15)

# ─── Helpers ───
def human_bytes(b):
    b = int(b)
    if b >= 1_000_000_000_000: return f"{b/1_000_000_000_000:.2f} TB"
    if b >= 1_000_000_000: return f"{b/1_000_000_000:.2f} GB"
    if b >= 1_000_000: return f"{b/1_000_000:.2f} MB"
    if b >= 1_000: return f"{b/1_000:.2f} KB"
    return f"{b} B"

def get_server_by_id(sid):
    for i, s in enumerate(SERVERS):
        if str(i) == str(sid) or s.get("name") == str(sid):
            return i, s
    return None, None

def is_admin(tg_id):
    return str(tg_id) == ADMIN_ID

def find_user_across_servers(tg_id):
    """Find user on all servers by TG ID"""
    results = []
    tg_id = str(tg_id)
    for i, srv in enumerate(SERVERS):
        data = ssh_pfm_json(srv)
        if not data: continue
        for user in data.get("users", []):
            if str(user.get("tg_id")) == tg_id:
                results.append({"server_idx": i, "server": srv, "user": user})
    return results

# ─── Pending Actions ───
pending = {}  # chat_id -> {"action": ..., "server_idx": ..., "port": ..., "msg_id": ...}

# ─── User View ───
def show_user_status(chat_id, msg_id, tg_id):
    """Show user their ports across all servers"""
    results = find_user_across_servers(tg_id)
    if not results:
        text = (f"⛔ No account linked to your Telegram ID.\n"
                f"\n🆔 Your ID: <code>{tg_id}</code>\n"
                f"\nAsk your admin to link this ID.")
        if msg_id: edit(chat_id, msg_id, text)
        else: send(chat_id, text)
        return

    text = "👤 <b>Your Ports</b>\n"
    buttons = []

    for r in results:
        srv = r["server"]
        user = r["user"]  # Already fresh from ssh_pfm_json (sync+json)
        srv_name = srv.get("name", srv["host"])

        text += f"\n🖥 <b>{srv_name}</b>\n"

        for port in user.get("ports", []):
            p_num = port["port"]
            used = port.get("dl_bytes", 0)
            limit = port.get("limit_bytes", 0)
            blocked = port.get("blocked", 0) == 1
            method = port.get("method", "iptables")

            status = "🔴" if blocked else "🟢"
            used_h = human_bytes(used)
            limit_h = human_bytes(limit) if limit > 0 else "Unlimited"

            text += f"  {status} Port <b>{p_num}</b> [{method}]\n"
            text += f"     📊 {used_h} / {limit_h}\n"

            if limit > 0:
                remain = max(0, limit - used)
                pct = min(100, int(used * 100 / limit)) if limit > 0 else 0
                bar = "█" * (pct // 10) + "░" * (10 - pct // 10)
                text += f"     [{bar}] {pct}% — Remain: {human_bytes(remain)}\n"

    buttons.append([btn("🔄 Refresh", "user_refresh")])
    if msg_id: edit(chat_id, msg_id, text, buttons)
    else: send(chat_id, text, buttons)

# ─── Admin: Home ───
def admin_home(chat_id, msg_id=None):
    buttons = []
    for i, srv in enumerate(SERVERS):
        name = srv.get("name", srv["host"])
        buttons.append([btn(f"🖥 {name}", f"srv_{i}")])
    buttons.append([btn("📊 Overview (All Servers)", "overview")])
    buttons.append([btn("🔄 Sync All", "sync_all")])
    buttons.append([btn("📦 Backup Now", "do_backup")])

    text = "🔧 <b>PFM Admin Panel</b>\n\n"
    text += f"📡 {len(SERVERS)} server(s) configured\n"
    text += "/me — Your own status\n"
    text += "/backup — Manual backup"

    if msg_id: edit(chat_id, msg_id, text, buttons)
    else: send(chat_id, text, buttons)

# ─── Admin: Overview ───
def admin_overview(chat_id, msg_id):
    text = "📊 <b>Overview — All Servers</b>\n\n"
    buttons = []

    for i, srv in enumerate(SERVERS):
        name = srv.get("name", srv["host"])
        data = ssh_pfm_json(srv)

        if not data:
            text += f"🖥 <b>{name}</b> — ❌ Offline\n\n"
            continue

        users = data.get("users", [])
        total_ports = sum(len(u.get("ports", [])) for u in users)
        total_used = sum(p.get("dl_bytes", 0) for u in users for p in u.get("ports", []))
        blocked = sum(1 for u in users for p in u.get("ports", []) if p.get("blocked") == 1)

        text += (f"🖥 <b>{name}</b>\n"
                f"   👥 {len(users)} users | 📡 {total_ports} ports\n"
                f"   📊 Total: {human_bytes(total_used)}\n"
                f"   🔴 Blocked: {blocked}\n\n")

        buttons.append([btn(f"🖥 {name}", f"srv_{i}")])

    buttons.append([btn("🔙 Home", "home")])
    edit(chat_id, msg_id, text, buttons)

# ─── Admin: Server Detail ───
def admin_server(chat_id, msg_id, srv_idx):
    idx, srv = get_server_by_id(srv_idx)
    if not srv:
        edit(chat_id, msg_id, "Server not found."); return

    name = srv.get("name", srv["host"])
    data = ssh_pfm_json(srv)

    if not data:
        edit(chat_id, msg_id, f"🖥 <b>{name}</b>\n\n❌ Cannot connect.",
             [[btn("🔄 Retry", f"srv_{idx}"), btn("🔙 Home", "home")]])
        return

    users = data.get("users", [])
    text = f"🖥 <b>{name}</b>  ({srv['host']})\n{'─'*30}\n\n"
    buttons = []

    for user in users:
        uname = user.get("name", "?")
        tg_id = user.get("tg_id", "?")
        enabled = user.get("enabled", 1)
        ports = user.get("ports", [])
        st = "🟢" if enabled else "🔴"

        total_used = sum(p.get("dl_bytes", 0) for p in ports)
        text += f"{st} <b>{uname}</b> (TG:{tg_id}) — {human_bytes(total_used)}\n"

        for port in ports:
            p_num = port["port"]
            used = port.get("dl_bytes", 0)
            limit = port.get("limit_bytes", 0)
            blocked = port.get("blocked", 0) == 1
            method = port.get("method", "iptables")
            pst = "🔴" if blocked else "🟢"
            limit_h = human_bytes(limit) if limit > 0 else "Unlim"
            text += f"   {pst} :{p_num} [{method}] {human_bytes(used)}/{limit_h}\n"
            buttons.append([btn(f"{pst} Port {p_num} — {uname}", f"sp_{idx}_{p_num}")])

        text += "\n"

    if not users:
        text += "No users/ports configured.\n"

    buttons.append([btn("⚙️ Edit Server", f"editsrv_{idx}"), btn("🔄 Refresh", f"srv_{idx}")])
    buttons.append([btn("🔙 Home", "home")])
    edit(chat_id, msg_id, text, buttons)

# ─── Admin: Edit Server ───
def admin_edit_server(chat_id, msg_id, srv_idx):
    idx, srv = get_server_by_id(srv_idx)
    if not srv:
        edit(chat_id, msg_id, "Server not found."); return

    name = srv.get("name", srv["host"])
    host = srv.get("host", "?")
    port = srv.get("port", 22)
    user = srv.get("user", "root")
    auth = "🔒 Password" if srv.get("password") else "🔑 SSH Key"

    text = (f"⚙️ <b>Edit Server — {name}</b>\n"
            f"{'─'*30}\n\n"
            f"📛 Name: <code>{name}</code>\n"
            f"🌐 Host: <code>{host}</code>\n"
            f"🔌 SSH Port: <code>{port}</code>\n"
            f"👤 User: <code>{user}</code>\n"
            f"🔐 Auth: {auth}\n")

    buttons = [
        [btn("📛 Name", f"esf_{idx}_name"), btn("🌐 Host/IP", f"esf_{idx}_host")],
        [btn("🔌 SSH Port", f"esf_{idx}_port"), btn("👤 User", f"esf_{idx}_user")],
        [btn("🔐 Password", f"esf_{idx}_password")],
        [btn("🔙 Server", f"srv_{idx}"), btn("🔙 Home", "home")],
    ]
    edit(chat_id, msg_id, text, buttons)

# ─── Admin: Port Detail ───
def admin_port_detail(chat_id, msg_id, srv_idx, port):
    idx, srv = get_server_by_id(srv_idx)
    if not srv: return

    name = srv.get("name", srv["host"])
    data = ssh_pfm_json(srv)
    if not data: return

    port_data = None
    owner = "?"
    for user in data.get("users", []):
        for p in user.get("ports", []):
            if str(p["port"]) == str(port):
                port_data = p
                owner = user.get("name", "?")
                break

    if not port_data:
        edit(chat_id, msg_id, f"Port {port} not found on {name}.")
        return

    used = port_data.get("dl_bytes", 0)
    limit = port_data.get("limit_bytes", 0)
    blocked = port_data.get("blocked", 0) == 1
    method = port_data.get("method", "iptables")
    dest = port_data.get("dest", "?")

    text = (f"🖥 <b>{name}</b> — Port <b>{port}</b>\n"
            f"{'─'*30}\n\n"
            f"   📍 Destination: {dest}\n"
            f"   ⚙️ Engine: {method}\n"
            f"   👤 Owner: {owner}\n"
            f"   📊 Used: <b>{human_bytes(used)}</b>\n"
            f"   📦 Limit: {human_bytes(limit) if limit > 0 else 'Unlimited'}\n")

    if limit > 0:
        remain = max(0, limit - used)
        pct = min(100, int(used * 100 / limit))
        bar = "█" * (pct // 10) + "░" * (10 - pct // 10)
        text += (f"   📉 Remain: <b>{human_bytes(remain)}</b>\n"
                f"   [{bar}] {pct}%\n")

    status = "🔴 Blocked" if blocked else "🟢 Active"
    text += f"   Status: {status}\n"

    tog = "Unblock" if blocked else "Block"
    tog_icon = "🟢" if blocked else "🔴"

    buttons = [
        [btn(f"{tog_icon} {tog}", f"act_{idx}_{port}_toggle")],
        [btn("📝 Set Limit", f"act_{idx}_{port}_limit"),
         btn("🔄 Reset Usage", f"act_{idx}_{port}_reset")],
        [btn("➕ Add Traffic", f"act_{idx}_{port}_add"),
         btn("➖ Sub Traffic", f"act_{idx}_{port}_sub")],
        [btn(f"🔙 {name}", f"srv_{idx}"), btn("🔙 Home", "home")],
    ]
    edit(chat_id, msg_id, text, buttons)

# ─── Admin: Actions ───
def admin_action(chat_id, msg_id, srv_idx, port, action):
    idx, srv = get_server_by_id(srv_idx)
    if not srv: return
    name = srv.get("name", srv["host"])

    if action == "toggle":
        # Check current state
        data = ssh_pfm_json(srv)
        blocked = False
        if data:
            for u in data.get("users", []):
                for p in u.get("ports", []):
                    if str(p["port"]) == str(port):
                        blocked = p.get("blocked", 0) == 1

        if blocked:
            ok, msg = ssh_pfm_cmd(srv, f"unblock {port}")
            answer_cb("", "🟢 Unblocked" if ok else f"❌ {msg}")
        else:
            ok, msg = ssh_pfm_cmd(srv, f"block {port}")
            answer_cb("", "🔴 Blocked" if ok else f"❌ {msg}")
        time.sleep(0.3)
        admin_port_detail(chat_id, msg_id, srv_idx, port)

    elif action == "reset":
        ok, msg = ssh_pfm_cmd(srv, f"reset {port}")
        admin_port_detail(chat_id, msg_id, srv_idx, port)

    elif action == "limit":
        pending[chat_id] = {"action": "limit", "server_idx": idx, "port": port, "msg_id": msg_id}
        edit(chat_id, msg_id,
             f"📝 <b>Set Limit</b> — {name} Port {port}\n\n"
             f"Enter limit in GB:\n"
             f"(e.g. <code>50</code> or <code>0</code> = unlimited)",
             [[btn("❌ Cancel", f"sp_{idx}_{port}")]])

    elif action == "add":
        pending[chat_id] = {"action": "add", "server_idx": idx, "port": port, "msg_id": msg_id}
        edit(chat_id, msg_id,
             f"➕ <b>Add Traffic</b> — {name} Port {port}\n\n"
             f"Enter GB to add to limit:\n"
             f"(e.g. <code>10</code>)",
             [[btn("❌ Cancel", f"sp_{idx}_{port}")]])

    elif action == "sub":
        pending[chat_id] = {"action": "sub", "server_idx": idx, "port": port, "msg_id": msg_id}
        edit(chat_id, msg_id,
             f"➖ <b>Subtract Traffic</b> — {name} Port {port}\n\n"
             f"Enter GB to subtract from limit:\n"
             f"(e.g. <code>5</code>)",
             [[btn("❌ Cancel", f"sp_{idx}_{port}")]])

# ─── Text Input Handler ───
def handle_text(chat_id, tg_id, text):
    if chat_id not in pending:
        return False

    p = pending[chat_id]
    del pending[chat_id]
    act = p["action"]
    idx = p["server_idx"]
    val = text.strip()

    # ─── Edit Server Fields ───
    if act == "edit_server":
        field = p["field"]
        srv = SERVERS[idx]
        name = srv.get("name", srv["host"])

        if field == "port":
            try:
                val = int(val)
            except ValueError:
                send(chat_id, "❌ Invalid port number.")
                return True

        # Update config
        CFG["servers"][idx][field] = val
        save_config()
        reload_servers()

        send(chat_id, f"✅ <b>{name}</b> — {field} updated to <code>{val}</code>")
        return True

    # ─── Port Actions ───
    try:
        gb = float(val)
    except ValueError:
        send(chat_id, "❌ Invalid number.")
        return True

    port = p["port"]
    srv = SERVERS[idx]
    name = srv.get("name", srv["host"])

    if act == "limit":
        ok, msg = ssh_pfm_cmd(srv, f"limit {port} {gb}")
        send(chat_id, f"✅ {name} Port {port} limit → <b>{gb} GB</b>" if ok else f"❌ {msg}")
    elif act == "add":
        ok, msg = ssh_pfm_cmd(srv, f"addlimit {port} {gb}")
        send(chat_id, f"✅ {name} Port {port} +{gb} GB" if ok else f"❌ {msg}")
    elif act == "sub":
        ok, msg = ssh_pfm_cmd(srv, f"sublimit {port} {gb}")
        send(chat_id, f"✅ {name} Port {port} -{gb} GB" if ok else f"❌ {msg}")

    return True

# ─── Callback Handler ───
def handle_callback(cb):
    data = cb.get("data", "")
    chat_id = cb["message"]["chat"]["id"]
    msg_id = cb["message"]["message_id"]
    tg_id = cb["from"]["id"]
    cb_id = cb["id"]

    answer_cb(cb_id)

    # ─── User callbacks ───
    if not is_admin(tg_id):
        if data == "user_refresh":
            show_user_status(chat_id, msg_id, tg_id)
        return

    # ─── Admin callbacks ───
    if data == "home":
        admin_home(chat_id, msg_id)

    elif data == "overview":
        edit(chat_id, msg_id, "⏳ Loading all servers...")
        admin_overview(chat_id, msg_id)

    elif data == "sync_all":
        edit(chat_id, msg_id, "⏳ Syncing all servers...")
        for srv in SERVERS:
            ssh_pfm_sync(srv)
        edit(chat_id, msg_id, "✅ All servers synced!",
             [[btn("🔙 Home", "home")]])

    elif data == "do_backup":
        edit(chat_id, msg_id, "⏳ Generating backup...")
        try:
            _do_backup()
        except Exception as e:
            edit(chat_id, msg_id, f"❌ Backup failed: {e}",
                 [[btn("🔙 Home", "home")]])

    elif data.startswith("srv_"):
        srv_idx = data[4:]
        edit(chat_id, msg_id, "⏳ Loading...")
        admin_server(chat_id, msg_id, srv_idx)

    elif data.startswith("editsrv_"):
        srv_idx = data[8:]
        admin_edit_server(chat_id, msg_id, srv_idx)

    elif data.startswith("esf_"):
        # esf_SRVID_FIELD
        parts = data[4:].split("_", 1)
        if len(parts) == 2:
            srv_idx, field = parts
            idx, srv = get_server_by_id(srv_idx)
            if not srv: return
            name = srv.get("name", srv["host"])
            cur = srv.get(field, "")
            if field == "port": cur = srv.get("port", 22)
            labels = {"name": "📛 Name", "host": "🌐 Host/IP", "port": "🔌 SSH Port",
                       "user": "👤 User", "password": "🔐 Password"}
            label = labels.get(field, field)
            pending[chat_id] = {"action": "edit_server", "server_idx": idx,
                               "field": field, "msg_id": msg_id}
            hint = f"\nCurrent: <code>{cur}</code>" if field != "password" else ""
            edit(chat_id, msg_id,
                 f"✏️ <b>Edit {label}</b> — {name}{hint}\n\n"
                 f"Enter new value:",
                 [[btn("❌ Cancel", f"editsrv_{idx}")]])

    elif data.startswith("sp_"):
        # sp_SRVID_PORT
        parts = data[3:].split("_", 1)
        if len(parts) == 2:
            admin_port_detail(chat_id, msg_id, parts[0], parts[1])

    elif data.startswith("act_"):
        # act_SRVID_PORT_ACTION
        parts = data[4:].split("_", 2)
        if len(parts) == 3:
            admin_action(chat_id, msg_id, parts[0], parts[1], parts[2])

    elif data == "user_refresh":
        show_user_status(chat_id, msg_id, tg_id)

# ─── Message Handler ───
def handle_message(msg):
    chat_id = msg.get("chat", {}).get("id")
    tg_id = msg.get("from", {}).get("id")
    text = msg.get("text", "").strip()
    if not chat_id or not text: return

    # Pending text input
    if handle_text(chat_id, tg_id, text):
        return

    cmd = text.split()[0].lower().split("@")[0]

    if cmd in ("/start", "/help"):
        if is_admin(tg_id):
            admin_home(chat_id)
        else:
            show_user_status(chat_id, None, tg_id)

    elif cmd in ("/me", "/status"):
        show_user_status(chat_id, None, tg_id)

    elif cmd == "/servers" and is_admin(tg_id):
        admin_home(chat_id)

    elif cmd == "/backup" and is_admin(tg_id):
        send(chat_id, "⏳ Generating backup...")
        try:
            _do_backup()
        except Exception as e:
            send(chat_id, f"❌ Backup failed: {e}")

    else:
        if is_admin(tg_id):
            admin_home(chat_id)
        else:
            show_user_status(chat_id, None, tg_id)

# ─── 6-Hour Backup Report ───
BACKUP_INTERVAL = 6 * 3600  # 6 hours

def send_backup_report():
    """Send traffic backup report to admin every 6 hours"""
    while True:
        time.sleep(BACKUP_INTERVAL)
        try:
            _do_backup()
        except Exception as e:
            print(f"Backup error: {e}")

def _do_backup():
    ts = time.strftime("%Y-%m-%d %H:%M")
    text = f"📦 <b>PFM Backup — {ts}</b>\n{'─'*30}\n\n"
    all_data = []

    for i, srv in enumerate(SERVERS):
        name = srv.get("name", srv["host"])
        data = ssh_pfm_json(srv)
        if not data:
            text += f"🖥 <b>{name}</b> — ❌ Offline\n\n"
            continue

        text += f"🖥 <b>{name}</b>\n"
        for user in data.get("users", []):
            uname = user.get("name", "?")
            tg_id = user.get("tg_id", "?")
            ports = user.get("ports", [])
            if not ports: continue

            for p in ports:
                port = p["port"]
                used = p.get("dl_bytes", 0)
                limit = p.get("limit_bytes", 0)
                blocked = p.get("blocked", 0)
                remain = max(0, limit - used) if limit > 0 else 0
                limit_h = human_bytes(limit) if limit > 0 else "Unlim"
                st = "🔴" if blocked else "🟢"

                text += (f"  {st} <code>{port}</code> {uname} "
                        f"TG:<code>{tg_id}</code>\n"
                        f"     📊 {human_bytes(used)} / {limit_h}")
                if limit > 0:
                    text += f" — 🔋 {human_bytes(remain)}"
                text += "\n"

                all_data.append({
                    "server": name, "port": port, "user": uname,
                    "tg_id": tg_id, "used": used, "limit": limit,
                    "remain": remain, "blocked": blocked
                })

        text += "\n"

    text += f"📊 Total ports: {len(all_data)}\n"
    text += f"⏰ Next backup: ~6h"

    # Send report text
    if ADMIN_ID:
        send(int(ADMIN_ID), text)

        # Send JSON backup file
        backup_json = json.dumps(all_data, indent=2, ensure_ascii=False)
        try:
            import io
            url = f"{API}/sendDocument"
            boundary = "---PFMBackup"
            fname = f"pfm-backup-{time.strftime('%Y%m%d-%H%M')}.json"
            body = (
                f"--{boundary}\r\n"
                f"Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n{ADMIN_ID}\r\n"
                f"--{boundary}\r\n"
                f"Content-Disposition: form-data; name=\"document\"; filename=\"{fname}\"\r\n"
                f"Content-Type: application/json\r\n\r\n{backup_json}\r\n"
                f"--{boundary}--\r\n"
            ).encode()
            req = Request(url, body, {"Content-Type": f"multipart/form-data; boundary={boundary}"})
            urlopen(req, timeout=30)
        except Exception as e:
            print(f"Backup file send error: {e}")

# ─── Main Loop ───
def main():
    print(f"PFM Bot started — {len(SERVERS)} server(s), admin: {ADMIN_ID}")

    # Start backup thread
    backup_thread = threading.Thread(target=send_backup_report, daemon=True)
    backup_thread.start()
    print("Backup report: every 6 hours")

    # Send startup message to admin
    if ADMIN_ID:
        srv_names = ", ".join(s.get("name", s["host"]) for s in SERVERS)
        send(int(ADMIN_ID),
             f"🟢 <b>PFM Bot Online</b>\n\n"
             f"📡 Servers: {len(SERVERS)}\n"
             f"🖥 {srv_names or 'No servers'}")

    offset = 0

    while True:
        try:
            r = tg("getUpdates", {"offset": offset, "timeout": 30})
            if r and r.get("ok"):
                for u in r.get("result", []):
                    offset = u["update_id"] + 1
                    try:
                        if "callback_query" in u:
                            handle_callback(u["callback_query"])
                        elif "message" in u:
                            handle_message(u["message"])
                    except Exception as e:
                        print(f"Handler error: {e}")
        except KeyboardInterrupt:
            print("Bot stopped"); break
        except Exception as e:
            print(f"Poll error: {e}")
            time.sleep(5)

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    main()
