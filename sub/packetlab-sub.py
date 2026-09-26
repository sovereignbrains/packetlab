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
import re
import shlex
import subprocess
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ETC = Path("/etc/packetlab")
ROOT = Path("/opt/packetlab")
PORT = 9999
# Наборы правил (.srs), которые сервер собирает сам: adguard.srs — фильтр рекламы,
# его раз в сутки обновляет packetlab-rules.timer (sub/update-rules.sh).
RULES = Path("/var/lib/packetlab/rules")
RULE_NAME = re.compile(r"^[a-z0-9-]+\.srs$")


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


def ask_module(mod: Path, fmt: str, user: str) -> str:
    """Нода с ключами этого пользователя: у каждого они свои (lib/users.py)."""
    return _run_module(mod, f"mod_link {fmt} {shlex.quote(user)}")


def mod_var(mod: Path, name: str) -> str:
    """Значение MOD_<name> из шапки модуля (без хвостового комментария)."""
    for line in mod.read_text(errors="replace").splitlines():
        if line.startswith(f"MOD_{name}="):
            return line.split("=", 1)[1].split("#", 1)[0].strip().strip('"\'')
    return ""


def needs_extended_client(mod: Path) -> bool:
    """MOD_CLIENTS=extended: протокол есть не у всех клиентов. Раньше это
    угадывалось по ядру (не sing-box — значит, отдельный сервер), но Mieru теперь живёт
    в sing-box (сборка mbox), а официальный клиент его по-прежнему не знает."""
    return mod_var(mod, "CLIENTS") == "extended"


def detect(ua: str) -> str:
    ua = (ua or "").lower()
    # Karing/Hiddify — форки с расширенным набором протоколов, им отдаём всё.
    if any(k in ua for k in ("karing", "hiddify")):
        return "singbox"
    # Апстримный sing-box не знает mieru и падает на неизвестном outbound.
    if any(k in ua for k in ("sing-box", "singbox")):
        return "singbox_strict"
    return "singbox_strict"


# С адреса хостера Qwen/Alibaba сыплют капчами, а напрямую из РФ открываются.
DIRECT_SUFFIXES = [
    "qwen.ai", "qwenlm.ai", "qwen.com", "alicdn.com", "aliyun.com",
    "aliyuncs.com", "alibabacloud.com", "alibaba.com", "mmstat.com",
]


def domain() -> str:
    try:
        return json.loads((ETC / "meta.json").read_text()).get("domain", "")
    except (OSError, ValueError):
        return ""


def sing_box_version(ua: str) -> tuple:
    """(мажор, минор) ядра из User-Agent, (0, 0) — не удалось понять."""
    m = re.search(r"sing-box[ /]v?(\d+)\.(\d+)", ua or "", re.I)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def add_adblock(cfg: dict, base: str, core: tuple = (0, 0)) -> None:
    """Реклама режется в клиенте: DNS-запрос к рекламному домену получает отказ,
    а соединение по SNI (sniff) — reject; второе ловит и браузеры со своим DoH.
    Правило встаёт после «напрямую», чтобы не ломать Qwen (mmstat.com в фильтре)."""
    if not base or not (RULES / "adguard.srs").exists():
        return
    rs = {"type": "remote", "tag": "ads", "format": "binary",
          "url": f"{base}/rules/adguard.srs", "update_interval": "24h"}
    # Качаем напрямую, а не через proxy: иначе без живого туннеля набор не
    # скачается, и клиент не стартует вовсе. Сама подписка скачивается так же.
    # С 1.14 это http_client без detour (download_detour там устарел и уйдёт
    # в 1.16); ядра старше и форки неизвестной версии (Karing) http_client
    # не знают и упали бы на незнакомом поле — им прежний download_detour.
    if core >= (1, 14):
        # Пустой {} ядро считает неявным клиентом по умолчанию — это тоже
        # устарело; клиент нужен объявленный и названный. Без detour — напрямую.
        cfg["http_clients"] = [{"tag": "dl-direct"}]
        cfg["route"]["default_http_client"] = "dl-direct"
        rs["http_client"] = "dl-direct"
    else:
        rs["download_detour"] = "direct"
    cfg["route"]["rule_set"] = [rs]
    rules = cfg["route"]["rules"]
    at = next(i for i, r in enumerate(rules) if r.get("protocol") == "quic")
    rules.insert(at, {"rule_set": "ads", "action": "reject"})
    cfg["dns"]["rules"].append({"rule_set": "ads", "action": "reject"})


def build(fmt: str, user: str, base: str = "", core: tuple = (0, 0)) -> tuple[bytes, str]:
    strict = fmt == "singbox_strict"
    if strict:
        fmt = "singbox"
    mods = [m for m in modules() if installed(m)]
    if strict:
        mods = [m for m in mods if not needs_extended_client(m)]
    parts = [ask_module(m, fmt, user) for m in mods]
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
            "rules": ([{"domain": own_hosts, "server": "local"}] if own_hosts else [])
                     + [{"domain_suffix": DIRECT_SUFFIXES, "server": "local"}],
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
            "route": {
                "rules": [
                    {"action": "sniff"},
                    # DNS к роутеру иначе уходит в туннель и висит до таймаута.
                    {"protocol": "dns", "action": "hijack-dns"},
                    {"ip_is_private": True, "outbound": "direct"},
                    {"domain_suffix": DIRECT_SUFFIXES, "outbound": "direct"},
                    # QUIC поверх TCP-туннеля тормозит; браузер сам уйдёт на TCP.
                    {"protocol": "quic", "action": "reject"},
                ],
                "final": "proxy", "auto_detect_interface": True,
                "default_domain_resolver": {"server": "local"},
            },
        }
        add_adblock(cfg, base, core)
        return json.dumps(cfg, indent=2, ensure_ascii=False).encode(), "application/json"


class Handler(BaseHTTPRequestHandler):
    server_version = "nginx"          # не светим Python в баннере
    sys_version = ""

    def _resolve(self):
        """/sub/<токен> — подписка, /sub/<токен>/rules/<имя>.srs — набор правил.
        Правила отдаются только по живому токену, как и сама подписка."""
        parts = self.path.split("?")[0].strip("/").split("/")
        if len(parts) not in (2, 4) or parts[0] != "sub" or not parts[1]:
            return None, None
        if len(parts) == 4 and (parts[2] != "rules" or not RULE_NAME.match(parts[3])):
            return None, None
        user = next((u for u in users() if u.get("sub_token") == parts[1]), None)
        return user, (parts[3] if len(parts) == 4 else None)

    def _send_file(self, path: Path, head_only: bool):
        try:
            body = path.read_bytes()
        except OSError:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _serve(self, head_only=False):
        user, rule = self._resolve()
        if not user:
            self.send_response(404)
            self.end_headers()
            return
        if rule:
            self._send_file(RULES / rule, head_only)
            return
        ua = self.headers.get("User-Agent") or ""
        # В журнал: по UA выбирается формат, и разбирать «почему этому клиенту
        # приехало не то» без него нечем. Токен не пишем.
        print(f"sub {user['name']} ua={ua[:120]!r}", flush=True)
        fmt = self.headers.get("X-Format") or detect(ua)
        dom = domain()
        base = f"https://{dom}/sub/{user['sub_token']}" if dom else ""
        # Без этого исключение при сборке обрывает соединение без ответа:
        # клиент видит «empty reply», а причина остаётся только в журнале.
        try:
            body, ctype = build(fmt, user["name"], base, sing_box_version(ua))
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
