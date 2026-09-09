#!/usr/bin/env python3
"""packetlab — сервер подписок.

Одна ссылка, два режима sing-box JSON. Клиент определяется по User-Agent:

  Karing / Hiddify → полный набор, включая Mieru (эти клиенты его понимают)
  sing-box / всё остальное (незнакомый UA) → без Mieru — апстримный клиент
                                              падает на неизвестном outbound

Ноды не хардкодятся: скрипт спрашивает их у модулей `packetlab`, поэтому
добавление протокола не требует правки этого файла.
"""

import base64
import json
import subprocess
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ETC = Path("/etc/packetlab")
ROOT = Path("/opt/packetlab")
PORT = 9999


def users():
    return json.loads((ETC / "users.json").read_text())


def modules():
    return sorted(p for p in (ROOT / "modules").glob("*.sh"))


def _run_module(mod: Path, func: str) -> str:
    """Выполняет функцию модуля в его собственной подоболочке."""
    cmd = f'PL_ROOT={ROOT} . {ROOT}/lib/ui.sh; . {ROOT}/lib/core.sh; . {mod}; {func}'
    try:
        r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired:
        return ""
    return r.stdout.strip()


def installed(mod: Path) -> bool:
    """Модуль отдаёт шаблон ссылки независимо от того, установлен ли протокол,
    и у неустановленного подстановки пустые — получается битый JSON. Поэтому
    спрашиваем статус: 'off' означает, что инбаунда в конфиге нет."""
    return _run_module(mod, "mod_status") != "off"


def ask_module(mod: Path, fmt: str) -> str:
    return _run_module(mod, f"mod_link {fmt}")


def engine(mod: Path) -> str:
    """MOD_ENGINE модуля: sing-box, mita и т.п."""
    for line in mod.read_text(errors="replace").splitlines():
        if line.startswith("MOD_ENGINE="):
            return line.split("=", 1)[1].strip().strip('"\'')
    return ""


def detect(ua: str) -> str:
    ua = (ua or "").lower()
    # Karing/Hiddify — форки с расширенным набором протоколов, им отдаём всё.
    if any(k in ua for k in ("karing", "hiddify")):
        return "singbox"
    # Апстримный sing-box не знает mieru и падает на неизвестном outbound.
    if any(k in ua for k in ("sing-box", "singbox")):
        return "singbox_strict"
    return "singbox_strict"


def build(fmt: str) -> tuple[bytes, str]:
    strict = fmt == "singbox_strict"
    if strict:
        fmt = "singbox"
    mods = [m for m in modules() if installed(m)]
    if strict:
        mods = [m for m in mods if engine(m) == "sing-box"]
    parts = [ask_module(m, fmt) for m in mods]
    parts = [p for p in parts if p]

    if fmt == "singbox":
        # Один сломанный модуль не должен ронять всю подписку.
        outs = []
        for p in parts:
            try:
                outs.append(json.loads(p))
            except json.JSONDecodeError:
                continue
        tags = [o["tag"] for o in outs]
        own_hosts = sorted({o["server"] for o in outs if o.get("server")})
        cfg_dns = {
            "servers": [
                {"type": "tls", "tag": "remote", "server": "1.1.1.1", "detour": "proxy"},
                {"type": "local", "tag": "local"},
            ],
            "rules": ([{"domain": own_hosts, "server": "local"}] if own_hosts else []),
            "final": "remote",
            "strategy": "ipv4_only",
        }
        cfg = {
            "log": {"level": "warn", "timestamp": True},
            "dns": cfg_dns,
            "inbounds": [
                {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"],
                 "auto_route": True, "strict_route": True, "stack": "mixed"},
                {"type": "mixed", "tag": "mixed-in",
                 "listen": "127.0.0.1", "listen_port": 2080},
            ],
            "outbounds": (
                [{
                    "type": "selector", "tag": "proxy",
                    "outbounds": ["auto"] + tags, "default": "auto",
                }, {
                    "type": "urltest", "tag": "auto", "outbounds": tags,
                    "url": "https://www.gstatic.com/generate_204",
                    "interval": "3m", "tolerance": 50,
                }]
                + outs
                + [{"type": "direct", "tag": "direct"}]
            ),
            "route": {"final": "proxy", "auto_detect_interface": True,
                      "default_domain_resolver": {"server": "local"}},
        }
        return json.dumps(cfg, indent=2, ensure_ascii=False).encode(), "application/json"


class Handler(BaseHTTPRequestHandler):
    server_version = "nginx"          # не светим Python в баннере
    sys_version = ""

    def _resolve(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        if len(parts) != 2 or parts[0] != "sub" or not parts[1]:
            return None
        return next((u for u in users() if u.get("sub_token") == parts[1]), None)

    def _serve(self, head_only=False):
        user = self._resolve()
        if not user:
            self.send_response(404)
            self.end_headers()
            return
        fmt = self.headers.get("X-Format") or detect(self.headers.get("User-Agent"))
        # Без этого исключение при сборке обрывает соединение без ответа:
        # клиент видит «empty reply», а причина остаётся только в журнале.
        try:
            body, ctype = build(fmt)
        except Exception:
            traceback.print_exc()
            self.send_response(500)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Subscription-Userinfo", "upload=0; download=0; total=0")
        self.send_header("Profile-Update-Interval", "12")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    # Karing шлёт HEAD перед GET; без обработчика BaseHTTPRequestHandler
    # отвечает 501 и подписка не добавляется.
    def do_HEAD(self):
        self._serve(head_only=True)

    def do_GET(self):
        self._serve()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
