#!/usr/bin/env python3
"""packetlab — пользователи и их ключи.

users.json — список [{name, sub_token, creds: {<модуль>: {uuid|pass: …}}}],
первый в списке — владелец. У каждого пользователя в каждом протоколе свои
ключи: подписка по его токену отдаёт его ключи, а удаление убирает их из
инбаундов — доступ отзывается по-настоящему, а не только ссылка-подписка.

Ключи создаются по первому требованию. Владелец при этом забирает ключи из
meta.json (<модуль>_uuid / <модуль>_pass), с которыми протоколы ставились до
многопользовательского режима, — его ссылки не меняются, отдельной миграции
не нужно.

Команды (вызываются из bash-слоя и сервера подписок):
  owner | names | token <имя>
  cred <имя> <модуль> uuid|pass          — ключ (создаётся, если нет)
  inbound-users <модуль> <шаблон>        — JSON-массив users для инбаунда
  add <имя> | del <имя> | rotate <имя>
  sync <модуль>=<шаблон> …               — переписать users в инбаундах;
                                           печатает changed или same
В шаблоне: %name%, %uuid%, %pass% — например {"name":"%name%","password":"%pass%"}.
"""

import base64
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

ETC = Path(os.environ.get("PL_ETC", "/etc/packetlab"))
USERS = ETC / "users.json"
META = ETC / "meta.json"
SB = Path(os.environ.get("PL_SB", "/etc/sing-box/config.json"))

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$")   # имя уходит в JSON конфигов и в ссылки
FIELDS = ("uuid", "pass")


def _load(p: Path, default):
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return default


def _save(p: Path, data) -> None:
    # Атомарно: сервер подписок читает файл параллельно с меню.
    fd, tmp = tempfile.mkstemp(dir=p.parent, prefix="." + p.name + ".")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)


def _new(field: str) -> str:
    if field == "uuid":
        return str(uuid.uuid4())
    return base64.b64encode(secrets.token_bytes(18)).decode()   # как pl_secret


def users() -> list:
    return _load(USERS, [])


def find(us: list, name: str) -> dict:
    for u in us:
        if u.get("name") == name:
            return u
    sys.exit(f"нет пользователя {name}")


def ensure(us: list, u: dict, mod: str, fields) -> bool:
    """Досоздаёт ключи пользователя для модуля. True — что-то добавилось."""
    creds = u.setdefault("creds", {}).setdefault(mod, {})
    added = False
    for f in fields:
        if creds.get(f):
            continue
        legacy = _load(META, {}).get(f"{mod}_{f}") if u is us[0] else None
        creds[f] = legacy or _new(f)
        added = True
    return added


def fill(tpl: str, u: dict, mod: str) -> dict:
    c = u["creds"][mod]
    out = tpl.replace("%name%", u["name"])
    for f in FIELDS:
        out = out.replace(f"%{f}%", c.get(f, ""))
    return json.loads(out)


def fields_of(tpl: str):
    return [f for f in FIELDS if f"%{f}%" in tpl]


def inbound_users(us: list, mod: str, tpl: str):
    changed = False
    for u in us:
        changed |= ensure(us, u, mod, fields_of(tpl))
    return [fill(tpl, u, mod) for u in us], changed


def main(argv):
    cmd, args = (argv[0] if argv else ""), argv[1:]
    us = users()

    if cmd == "owner":
        print(us[0]["name"] if us else "")
    elif cmd == "names":
        for u in us:
            print(u["name"])
    elif cmd == "token":
        print(find(us, args[0]).get("sub_token", ""))
    elif cmd == "cred":
        name, mod, field = args
        u = find(us, name)
        if ensure(us, u, mod, [field]):
            _save(USERS, us)
        print(u["creds"][mod][field])
    elif cmd == "inbound-users":
        mod, tpl = args
        arr, changed = inbound_users(us, mod, tpl)
        if changed:
            _save(USERS, us)
        print(json.dumps(arr, ensure_ascii=False))
    elif cmd == "add":
        name = args[0]
        if not NAME_RE.match(name):
            print("имя: латиница, цифры и _.- , до 32 символов", file=sys.stderr)
            return 2
        if any(u["name"] == name for u in us):
            print("имя уже занято", file=sys.stderr)
            return 3
        us.append({"name": name, "sub_token": secrets.token_hex(16), "creds": {}})
        _save(USERS, us)
    elif cmd == "del":
        name = args[0]
        if us and us[0]["name"] == name:
            print("владельца не удалить", file=sys.stderr)
            return 3
        rest = [u for u in us if u["name"] != name]
        if len(rest) == len(us):
            print("нет такого пользователя", file=sys.stderr)
            return 4
        _save(USERS, rest)
    elif cmd == "rotate":
        find(us, args[0])["sub_token"] = secrets.token_hex(16)
        _save(USERS, us)
    elif cmd == "sync":
        return sync(us, args)
    else:
        print(__doc__, file=sys.stderr)
        return 1
    return 0


def sync(us: list, pairs) -> int:
    """Переписывает users во всех перечисленных инбаундах (<модуль>-in).
    Конфиг меняется, только если реально поменялся список: иначе рестарт
    sing-box оборвал бы всем соединения зря."""
    cfg = _load(SB, None)
    if cfg is None:
        print("не читается " + str(SB), file=sys.stderr)
        return 1
    creds_changed = False
    for pair in pairs:
        mod, tpl = pair.split("=", 1)
        for ib in cfg.get("inbounds", []):
            if ib.get("tag") == f"{mod}-in":
                arr, ch = inbound_users(us, mod, tpl)
                creds_changed |= ch
                ib["users"] = arr
    if creds_changed:
        _save(USERS, us)
    if json.dumps(cfg, sort_keys=True) == json.dumps(_load(SB, None), sort_keys=True):
        print("same")
        return 0
    new = SB.with_suffix(".json.new")
    new.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    r = subprocess.run(["sing-box", "check", "-c", str(new)], capture_output=True, text=True)
    if r.returncode != 0:
        new.unlink()
        print("sing-box отверг конфиг: " + (r.stderr or r.stdout).strip()[:300], file=sys.stderr)
        return 1
    subprocess.run(["cp", "-a", str(SB), f"{SB}.bak-users"], check=False)
    os.replace(new, SB)
    print("changed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
