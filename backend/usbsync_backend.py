#!/usr/bin/env python3
"""USB Sync backend — sincroniza carpetas del equipo con una SSD USB (rsync).

Servicio systemd user que:
  - Detecta la SSD USB montada en /run/media/$USER/<label>
  - Mantiene la config de pares (origen local -> subcarpeta en la SSD)
  - Ejecuta rsync unidireccional (backup equipo -> SSD)
  - Expone API HTTP en 127.0.0.1:8135 para el plasmoid
"""

import http.server
import getpass
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

PORT = 8135
PENDING_TTL = 30   # caché del cálculo de cambios pendientes (segundos)
USER = os.environ.get("USER") or os.environ.get("LOGNAME") or getpass.getuser()
MEDIA_DIR = Path("/run/media") / USER
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "usbsync"
CONFIG_FILE = CONFIG_DIR / "config.json"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "usbsync"
LOG_FILE = STATE_DIR / "usbsync.log"

DEFAULT_CONFIG = {
    "ssd_uuid": "",             # UUID de la partición de la SSD objetivo ("" = auto)
    "ssd_label": "",            # label de la SSD (legacy; se guarda junto al uuid)
    "autosync_on_connect": True,  # sincronizar automáticamente al conectar la SSD
    "default_delete": False,    # espejo exacto (--delete) por defecto en pares nuevos
    "pairs": [],                # [{id, source, dest_rel, delete}]
}

state = {
    "config": dict(DEFAULT_CONFIG),
    "prev_connected": False,
    "sync": {
        "running": False,
        "proc": None,
        "pair_id": None,
        "pair_label": "",
        "started": None,
        "pct": None,
        "pct_global": None,
        "pair_index": 0,
        "pairs_total": 0,
        "last_line": "",
    },
    "last_sync": None,  # {"ts": iso, "ok": bool, "msg": str, "files": int, "trigger": str}
    "pending": {        # cambios no sincronizados por par (caché de rsync --dry-run)
        "pairs": {},    # pair_id -> {"pending": bool|None, "n": int, "error": str|None}
        "computed_at": 0.0,
        "computing": False,
    },
    "lock": threading.Lock(),
}

# ---------------------------------------------------------------- logging

def log(msg: str):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass

# ---------------------------------------------------------------- config

def load_config():
    try:
        if CONFIG_FILE.exists():
            data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            for k, v in DEFAULT_CONFIG.items():
                if k not in data:
                    data[k] = v
            if not isinstance(data.get("pairs"), list):
                data["pairs"] = []
            state["config"] = data
    except Exception as e:
        log(f"config corrupta ({e}) — usando defaults")

def save_config():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(state["config"], indent=2, ensure_ascii=False), encoding="utf-8")

# ---------------------------------------------------------------- SSD detection

def scan_removable() -> list:
    """Lista dispositivos extraíbles montados vía lsblk: [{label, uuid, mount, size, fs}]."""
    try:
        out = subprocess.run(
            ["lsblk", "-o", "NAME,LABEL,UUID,FSTYPE,SIZE,MOUNTPOINT,TRAN", "-J"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        data = json.loads(out)
        devs = []
        def walk(items):
            for b in items:
                mp = b.get("mountpoint")
                if mp and str(mp).startswith(f"/run/media/{USER}/"):
                    devs.append({
                        "label": b.get("label") or b.get("name", ""),
                        "uuid": b.get("uuid") or "",
                        "mount": mp,
                        "size": b.get("size") or "",
                        "fs": b.get("fstype") or "",
                    })
                if b.get("children"):
                    walk(b["children"])
        walk(data.get("blockdevices", []))
        return devs
    except Exception as e:
        log(f"scan_removable error: {e}")
        return []

def detect_ssd() -> dict:
    """Devuelve el estado de la SSD objetivo (por UUID configurado, label legacy o única)."""
    result = {"connected": False, "label": None, "mount": None, "uuid": None, "ambiguous": False}
    devs = scan_removable()
    if not devs:
        return result
    cfg_uuid = (state["config"].get("ssd_uuid") or "").strip()
    cfg_label = (state["config"].get("ssd_label") or "").strip()

    def match(d):
        return {"connected": True, "label": d["label"], "mount": d["mount"],
                "uuid": d["uuid"], "ambiguous": False}

    if cfg_uuid:
        for d in devs:
            if d["uuid"] == cfg_uuid:
                return match(d)
        return result  # uuid configurado pero no montado
    if cfg_label:
        for d in devs:
            if d["label"] == cfg_label:
                return match(d)
        return result
    if len(devs) == 1:
        return match(devs[0])
    result.update(ambiguous=True)
    return result

# ---------------------------------------------------------------- pick folder (Dolphin)

PICK_FILE = STATE_DIR / "pick_request.json"

def ensure_servicemenu():
    """Instala el service menu de Dolphin + el script helper si faltan."""
    try:
        sm_dir = Path.home() / ".local/share/kio/servicemenus"
        sm_dir.mkdir(parents=True, exist_ok=True)
        sm_file = sm_dir / "usbsync-select.desktop"
        if not sm_file.exists():
            content = """[Desktop Entry]
Type=Service
ServiceTypes=KFileItem;inode/directory;
MimeType=inode/directory;
Actions=useAsSource;useAsDest;
X-KDE-Submenu=USB Sync

[Desktop Action useAsSource]
Name=Seleccionar como ORIGEN del equipo
Icon=go-previous
Exec=/home/{user}/.local/bin/usbsync_pick.sh %f source

[Desktop Action useAsDest]
Name=Seleccionar como DESTINO en la SSD
Icon=go-next
Exec=/home/{user}/.local/bin/usbsync_pick.sh %f dest
""".format(user=USER)
            sm_file.write_text(content, encoding="utf-8")
        helper = Path.home() / ".local/bin/usbsync_pick.sh"
        if not helper.exists():
            content = """#!/bin/bash
# usbsync_pick.sh — service menu de Dolphin para USB Sync
# $1 = URL de la carpeta (file:///...), $2 = campo ("source" | "dest")
set -e
URL="$1"
FIELD="$2"
PATH_RAW="${URL#file://}"
PATH_DECODED=$(python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))" "$PATH_RAW")
DIR="$HOME/.local/state/usbsync"
mkdir -p "$DIR"
printf '{{"ts": %s, "path": "%s", "field": "%s"}}' "$(date +%s)" "$PATH_DECODED" "$FIELD" > "$DIR/pick_request.json"
"""
            helper.write_text(content, encoding="utf-8")
            helper.chmod(0o755)
    except Exception as e:
        log(f"ensure_servicemenu error: {e}")

def pick_folder(start: str = "", field: str = "source") -> str | None:
    """Abre el diálogo nativo de KDE (KFileWidget — el mismo que usa Dolphin)
    con botón Aceptar, lanzado con el entorno gráfico completo de la sesión.

    Fallback: si kdialog no está, usa Dolphin + service menu (clic derecho →
    USB Sync → Seleccionar), que escribe pick_request.json.
    """
    try:
        if PICK_FILE.exists():
            PICK_FILE.unlink()
        start = start or str(Path.home())
        if not os.path.isdir(start):
            start = str(Path.home())
        env = session_env()

        # 1) Diálogo nativo KDE (KFileWidget = UI de Dolphin) con Aceptar
        try:
            p = subprocess.run(
                ["kdialog", "--getexistingdirectory", start],
                capture_output=True, text=True, env=env, timeout=300,
            )
            path = (p.stdout or "").strip()
            log(f"[PICK] kdialog rc={p.returncode} stdout='{path}' stderr='{(p.stderr or '').strip()[:120]}'")
            if path and os.path.isdir(path):
                log(f"[PICK] {field} -> {path} (diálogo nativo)")
                return path
            log("[PICK] diálogo cancelado")
            return None
        except FileNotFoundError:
            log("[PICK] kdialog ausente — usando Dolphin + service menu")
        except subprocess.TimeoutExpired:
            log("[PICK] kdialog timeout")

        # 2) Fallback: Dolphin + service menu
        subprocess.Popen(["dolphin", "--new-window", start],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         env=env, start_new_session=True)
        deadline = time.time() + 120
        while time.time() < deadline:
            if PICK_FILE.exists():
                try:
                    data = json.loads(PICK_FILE.read_text(encoding="utf-8"))
                except Exception:
                    time.sleep(0.5)
                    continue
                if data.get("path"):
                    picked = data["path"]
                    if os.path.isdir(picked):
                        log(f"[PICK] {data.get('field')} -> {picked}")
                        return picked
            time.sleep(0.5)
        log("[PICK] timeout sin selección (Dolphin cerrado sin elegir)")
        return None
    except Exception as e:
        log(f"pick_folder error: {e}")
        return None

def session_env() -> dict:
    """Entorno gráfico de la sesión, leído del proceso plasmashell."""
    env = {}
    try:
        out = subprocess.run(["pgrep", "-x", "plasmashell"], capture_output=True, text=True).stdout.split()
        for pid in out[:1]:
            raw = Path(f"/proc/{pid}/environ").read_bytes()
            for kv in raw.split(b"\0"):
                if b"=" in kv:
                    k, _, v = kv.partition(b"=")
                    if k in (b"DISPLAY", b"WAYLAND_DISPLAY", b"XAUTHORITY",
                             b"XDG_RUNTIME_DIR", b"DBUS_SESSION_BUS_ADDRESS", b"HOME",
                             b"KDE_FULL_SESSION", b"XDG_CURRENT_DESKTOP", b"DESKTOP_SESSION",
                             b"XDG_SESSION_TYPE", b"XDG_SESSION_DESKTOP", b"QT_QPA_PLATFORMTHEME"):
                        env[k.decode()] = v.decode()
    except Exception:
        pass
    env.setdefault("DISPLAY", ":0")
    env.setdefault("WAYLAND_DISPLAY", "wayland-0")
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    env.setdefault("KDE_FULL_SESSION", "true")
    env.setdefault("XDG_CURRENT_DESKTOP", "KDE")
    return env

# ---------------------------------------------------------------- sync engine

def _rsync_cmd(pair: dict, dest: str) -> list:
    src = pair.get("source", "").rstrip("/")
    cmd = ["rsync", "-a", "--partial", "--info=progress2", "--stats"]
    if pair.get("delete"):
        cmd.append("--delete")
    cmd += [src + "/", dest.rstrip("/") + "/"]
    return cmd

def _update_progress(line: str):
    with state["lock"]:
        state["sync"]["last_line"] = line.strip()[:120]
        m = re.search(r"(\d+(?:\.\d+)?)\s*%", line)
        if m:
            state["sync"]["pct"] = m.group(1)
            _update_global_pct()
        else:
            state["sync"]["pct"] = None

def _update_global_pct():
    """% global ponderado: (pares completados + % del actual) / total pares."""
    s = state["sync"]
    total = s.get("pairs_total", 0)
    idx = s.get("pair_index", 0)
    if total <= 0:
        s["pct_global"] = None
        return
    pct_cur = 0.0
    try:
        pct_cur = float(s.get("pct") or 0)
    except (TypeError, ValueError):
        pct_cur = 0.0
    s["pct_global"] = round((idx + pct_cur / 100.0) / total * 100.0, 1)

def run_sync(pair: dict, trigger: str = "manual", pair_index: int = 0,
             pairs_total: int = 1) -> dict:
    """Ejecuta rsync de un par. Devuelve {ok, msg, files}."""
    ssd = detect_ssd()
    if not ssd["connected"]:
        return {"ok": False, "msg": "SSD no conectada", "files": 0}
    src = pair.get("source", "")
    dest_rel = (pair.get("dest_rel") or "").strip().strip("/")
    if not src or not os.path.isdir(src):
        return {"ok": False, "msg": f"Origen no existe: {src}", "files": 0}
    if not dest_rel:
        return {"ok": False, "msg": "Destino vacío", "files": 0}
    dest = os.path.join(ssd["mount"], dest_rel)
    try:
        os.makedirs(dest, exist_ok=True)
    except Exception as e:
        return {"ok": False, "msg": f"No se puede crear destino: {e}", "files": 0}

    cmd = _rsync_cmd(pair, dest)
    log(f"[SYNC] {trigger} {src} -> {dest} {'(--delete)' if pair.get('delete') else ''}")
    try:
        env = dict(os.environ)
        env["LC_ALL"] = "C"  # resumen rsync en inglés (el locale localiza "Number of regular files")
        # --stats va a stdout; el progreso (--info=progress2) a stderr.
        # Combinar ambos en un solo stream para parsear el resumen al final.
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors="replace", env=env)
    except FileNotFoundError:
        return {"ok": False, "msg": "rsync no instalado", "files": 0}

    with state["lock"]:
        state["sync"]["running"] = True
        state["sync"]["proc"] = proc
        state["sync"]["pair_id"] = pair.get("id")
        state["sync"]["pair_label"] = f"{src} → {dest_rel}"
        state["sync"]["started"] = time.time()
        state["sync"]["pct"] = None
        state["sync"]["pair_index"] = pair_index
        state["sync"]["pairs_total"] = pairs_total
        state["sync"]["pct_global"] = None
        state["sync"]["last_line"] = ""
        _update_global_pct()

    buf = ""
    try:
        for chunk in iter(lambda: proc.stdout.read(4096), ""):
            buf += chunk
            # progress2 usa \r; procesar el último segmento de cada chunk
            parts = buf.split("\r")
            buf = parts[-1]
            for part in parts[:-1]:
                if part.strip():
                    _update_progress(part)
        if buf.strip():
            _update_progress(buf)
        proc.wait(timeout=3600)
    except Exception as e:
        proc.kill()
        log(f"[SYNC] error: {e}")
        with state["lock"]:
            state["sync"]["running"] = False
        return {"ok": False, "msg": str(e), "files": 0}
    finally:
        with state["lock"]:
            state["sync"]["running"] = False

    ok = proc.returncode == 0
    files = 0
    m = re.search(r"Number of regular files transferred:\s*(\d+)", buf)
    if m:
        files = int(m.group(1))
    msg = f"{files} archivos" if ok else f"rsync error ({proc.returncode})"
    if ok:
        log(f"[SYNC] OK {src} -> {dest_rel} ({files} archivos)")
    else:
        log(f"[SYNC] FALLO {src} -> {dest_rel} rc={proc.returncode}")
    return {"ok": ok, "msg": msg, "files": files}

def run_all_syncs(trigger: str = "manual"):
    with state["lock"]:
        if state["sync"]["running"]:
            return
    results = []
    pairs = state["config"].get("pairs", [])
    total = len(pairs)
    for idx, pair in enumerate(pairs):
        with state["lock"]:
            if state["sync"]["running"]:
                break  # parado a mitad
        r = run_sync(pair, trigger, pair_index=idx, pairs_total=total)
        results.append(r)
        # última sincronización por par (persistida) + invalidar caché de pendientes
        with state["lock"]:
            pair["last_sync"] = {
                "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
                "ok": r["ok"],
                "files": r["files"],
            }
            state["pending"]["computed_at"] = 0.0
        save_config()
        if not r["ok"]:
            break
    total_files = sum(r["files"] for r in results)
    ok = all(r["ok"] for r in results)
    msgs = [r["msg"] for r in results]
    state["last_sync"] = {
        "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
        "ok": ok,
        "msg": "; ".join(msgs) if msgs else "Sin pares configurados",
        "files": total_files,
        "trigger": trigger,
    }
    log(f"[SYNC] total {trigger}: {'OK' if ok else 'FALLO'} ({total_files} archivos)")

def stop_sync():
    with state["lock"]:
        proc = state["sync"]["proc"]
        state["sync"]["running"] = False
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

# ---------------------------------------------------------------- pending changes

def _pair_pending(pair: dict, mount: str) -> dict:
    """Cambios no sincronizados de un par vía `rsync --dry-run` (cuenta líneas).

    --out-format imprime una línea por elemento que CAMBIARÍA; sin -v no imprime
    los ya sincronizados, así que contar líneas = nº de cambios pendientes.
    """
    src = pair.get("source", "")
    dest_rel = (pair.get("dest_rel") or "").strip().strip("/")
    if not src or not os.path.isdir(src):
        return {"pending": None, "n": 0, "error": "origen no existe"}
    if not dest_rel:
        return {"pending": None, "n": 0, "error": "destino vacío"}
    dest = os.path.join(mount, dest_rel)
    cmd = ["rsync", "-a", "--dry-run", "--out-format=%i %n"]
    if pair.get("delete"):
        cmd.append("--delete")
    cmd += [src.rstrip("/") + "/", dest.rstrip("/") + "/"]
    try:
        env = dict(os.environ)
        env["LC_ALL"] = "C"
        out = subprocess.run(cmd, capture_output=True, text=True,
                             errors="replace", env=env, timeout=120)
        lines = [l for l in out.stdout.splitlines() if l.strip()]
        err = None if out.returncode == 0 else f"rc={out.returncode}"
        return {"pending": bool(lines), "n": len(lines), "error": err}
    except subprocess.TimeoutExpired:
        return {"pending": None, "n": 0, "error": "timeout"}
    except FileNotFoundError:
        return {"pending": None, "n": 0, "error": "rsync ausente"}

def compute_pending(force: bool = False):
    """Calcula los cambios pendientes por par si la caché está vieja. Hilo propio."""
    p = state["pending"]
    with state["lock"]:
        if p["computing"]:
            return
        if not force and time.time() - p["computed_at"] < PENDING_TTL:
            return
        if state["sync"]["running"]:
            return
        p["computing"] = True
    try:
        ssd = detect_ssd()
        result = {}
        if ssd["connected"]:
            for pair in state["config"].get("pairs", []):
                result[pair["id"]] = _pair_pending(pair, ssd["mount"])
        with state["lock"]:
            p["pairs"] = result
            p["computed_at"] = time.time()
    except Exception as e:
        log(f"[PENDING] error: {e}")
    finally:
        with state["lock"]:
            p["computing"] = False

# ---------------------------------------------------------------- monitor (autosync)

def monitor_loop():
    while True:
        try:
            ssd = detect_ssd()
            connected = ssd["connected"]
            if connected and not state["prev_connected"]:
                log(f"SSD conectada: {ssd['label']} en {ssd['mount']}")
                if state["config"].get("autosync_on_connect") and state["config"].get("pairs"):
                    threading.Thread(target=run_all_syncs, args=("auto",), daemon=True).start()
            if state["prev_connected"] and not connected:
                log("SSD desconectada")
            state["prev_connected"] = connected
        except Exception as e:
            log(f"monitor error: {e}")
        time.sleep(2)

# ---------------------------------------------------------------- HTTP API

def _json(data, code=200):
    body = json.dumps(data, ensure_ascii=False).encode("utf-8")
    return (code, {
        "Content-Type": "application/json; charset=utf-8",
        "Content-Length": str(len(body)),
        "Access-Control-Allow-Origin": "*",
        "Cache-Control": "no-store",
    }, body)

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "USBSync/1.0"

    def log_message(self, fmt, *args):
        pass  # silencioso; loguear solo eventos de sync

    def _read_body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0:
                return {}
            return json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        except Exception:
            return {}

    def _send(self, data, code=200):
        code, headers, body = _json(data, code)
        self.send_response(code)
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/status":
            ssd = detect_ssd()
            with state["lock"]:
                sync = {k: state["sync"][k] for k in
                        ("running", "pair_id", "pair_label", "started", "pct",
                         "pct_global", "pair_index", "pairs_total", "last_line")}
            self._send({
                "ok": True,
                "ssd": ssd,
                "autosync_on_connect": bool(state["config"].get("autosync_on_connect")),
                "ssd_label_cfg": state["config"].get("ssd_label", ""),
                "sync": sync,
                "last_sync": state["last_sync"],
                "pairs_count": len(state["config"].get("pairs", [])),
                "pairs": state["config"].get("pairs", []),
                "version": "1.1.0",
            })
        elif path == "/api/pairs":
            self._send({"ok": True, "pairs": state["config"].get("pairs", [])})
        elif path == "/api/devices":
            self._send({"ok": True, "devices": scan_removable(),
                        "ssd_uuid_cfg": state["config"].get("ssd_uuid", "")})
        elif path == "/api/config":
            self._send({"ok": True, "config": state["config"]})
        elif path == "/api/log":
            try:
                lines = LOG_FILE.read_text(encoding="utf-8").splitlines()[-40:]
            except Exception:
                lines = []
            self._send({"ok": True, "lines": lines})
        elif path == "/api/pending":
            # lanza el cálculo si la caché está vieja; responde al momento
            threading.Thread(target=compute_pending, daemon=True).start()
            with state["lock"]:
                self._send({
                    "ok": True,
                    "computing": state["pending"]["computing"],
                    "computed_at": state["pending"]["computed_at"],
                    "ssd_connected": detect_ssd()["connected"],
                    "pairs": state["pending"]["pairs"],
                })
        else:
            self._send({"ok": False, "error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0]
        body = self._read_body()
        if path == "/api/pairs":
            source = (body.get("source") or "").strip()
            dest_rel = (body.get("dest_rel") or "").strip().strip("/")
            pair_id = (body.get("id") or "").strip()
            if not source:
                self._send({"ok": False, "error": "source vacío"}, 400)
                return
            if not dest_rel:
                dest_rel = os.path.basename(source.rstrip("/")) or "backup"
            delete = bool(body.get("delete", state["config"].get("default_delete", False)))
            pairs = state["config"].setdefault("pairs", [])
            if pair_id:
                for p in pairs:
                    if p.get("id") == pair_id:
                        p["source"] = source
                        p["dest_rel"] = dest_rel
                        p["delete"] = delete
                        break
                else:
                    pair_id = ""
            if not pair_id:
                pair_id = uuid.uuid4().hex[:8]
                pairs.append({"id": pair_id, "source": source, "dest_rel": dest_rel, "delete": delete})
            save_config()
            log(f"[CONFIG] par {pair_id}: {source} -> {dest_rel} (delete={delete})")
            with state["lock"]:
                state["pending"]["computed_at"] = 0.0  # invalidar caché de pendientes
            saved = next((p for p in pairs if p.get("id") == pair_id), pairs[-1])
            self._send({"ok": True, "pair": saved})
        elif path == "/api/pairs/delete":
            pair_id = (body.get("id") or "").strip()
            pairs = state["config"].get("pairs", [])
            state["config"]["pairs"] = [p for p in pairs if p.get("id") != pair_id]
            save_config()
            log(f"[CONFIG] par eliminado: {pair_id}")
            with state["lock"]:
                state["pending"]["computed_at"] = 0.0  # invalidar caché de pendientes
            self._send({"ok": True})
        elif path == "/api/config":
            cfg = state["config"]
            if "ssd_uuid" in body:
                cfg["ssd_uuid"] = (body.get("ssd_uuid") or "").strip()
            if "ssd_label" in body:
                cfg["ssd_label"] = (body.get("ssd_label") or "").strip()
            if "autosync_on_connect" in body:
                cfg["autosync_on_connect"] = bool(body.get("autosync_on_connect"))
            if "default_delete" in body:
                cfg["default_delete"] = bool(body.get("default_delete"))
            save_config()
            log(f"[CONFIG] actualizado: uuid='{cfg['ssd_uuid']}' label='{cfg['ssd_label']}' "
                f"autosync={cfg['autosync_on_connect']}")
            self._send({"ok": True, "config": cfg})
        elif path == "/api/sync":
            with state["lock"]:
                already = state["sync"]["running"]
            if already:
                self._send({"ok": False, "error": "sync en curso"})
                return
            threading.Thread(target=run_all_syncs, args=("manual",), daemon=True).start()
            self._send({"ok": True, "started": True})
        elif path == "/api/sync/stop":
            stop_sync()
            self._send({"ok": True})
        elif path == "/api/pick_folder":
            start = (body.get("start") or "").strip()
            field = (body.get("field") or "source").strip()
            if field not in ("source", "dest"):
                field = "source"
            picked = pick_folder(start, field)
            self._send({"ok": True, "picked": picked, "field": field})
        else:
            self._send({"ok": False, "error": "not found"}, 404)

    def do_DELETE(self):
        path = self.path.split("?")[0]
        if path.startswith("/api/pairs/"):
            pair_id = path.rsplit("/", 1)[-1]
            pairs = state["config"].get("pairs", [])
            state["config"]["pairs"] = [p for p in pairs if p.get("id") != pair_id]
            save_config()
            log(f"[CONFIG] par eliminado: {pair_id}")
            with state["lock"]:
                state["pending"]["computed_at"] = 0.0  # invalidar caché de pendientes
            self._send({"ok": True})
        else:
            self._send({"ok": False, "error": "not found"}, 404)

def main():
    load_config()
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    ensure_servicemenu()
    if not CONFIG_FILE.exists():
        save_config()
    ssd = detect_ssd()
    log(f"Backend arrancado (puerto {PORT}); SSD {'conectada: ' + ssd['label'] if ssd['connected'] else 'no detectada'}")
    threading.Thread(target=monitor_loop, daemon=True).start()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
