#!/usr/bin/env bash
# plr — цепочка «вход → выход» (中转 → 落地) на sing-box. Один файл, обе роли, packetlab не нужен.
#
#   curl -fsSL https://raw.githubusercontent.com/sovereignbrains/packetlab/main/relay/plr.sh \
#     -o /usr/local/bin/plr && chmod +x /usr/local/bin/plr
#
# Выходной сервер (его IP видят сайты):
#   plr exit            поднять relay-in (VLESS + REALITY, домен не нужен) и напечатать токен;
#                       повторный запуск ничего не меняет и печатает тот же токен
#                       если на сервере haproxy-мультиплексор на 443 (packetlab), relay-in прячется
#                       за ним по SNI: наружу только 443/tcp, в токене порт 443
#   plr exit --move     перенести уже поднятый relay-in с отдельного порта за haproxy (токен новый)
#   plr exit --remove   убрать relay-in
# Входной сервер (к нему подключаются клиенты):
#   plr link <токен>    outbound relay-out к выходу + проверочный relay-probe на 127.0.0.1:20999;
#                       трафик клиентов пока идёт напрямую
#   plr test            запрос через relay-probe должен вернуться с IP выхода
#   plr on | off        весь трафик клиентов через выход (route.final = relay-out) / напрямую
#   plr unlink          убрать всё, что добавил link
#   plr status
#
# Для exit: PLR_PORT (443, если свободен, иначе случайный), PLR_SNI (www.bing.com),
#           PLR_HOST (внешний IPv4), PLR_NAME (hostname).
# Каждое изменение перезапускает sing-box — активные соединения через этот сервер обрываются.
set -uo pipefail

SB=/etc/sing-box/config.json
STATE_DIR=/etc/packetlab-relay
EXIT_STATE=$STATE_DIR/exit.json
ENTRY_STATE=$STATE_DIR/entry.json
PROBE=20999

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_GRY=$'\033[38;5;244m'
  C_GRN=$'\033[38;5;42m'; C_YLW=$'\033[38;5;214m'; C_RED=$'\033[38;5;203m'; C_CYN=$'\033[38;5;80m'
else
  C_RST=''; C_B=''; C_GRY=''; C_GRN=''; C_YLW=''; C_RED=''; C_CYN=''
fi
say()  { printf '  %s·%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YLW" "$C_RST" "$*"; }
err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$*"; }
note() { printf '    %s%s%s\n' "$C_GRY" "$*" "$C_RST"; }
die()  { err "$*"; exit 1; }

port_busy() { ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
ufw_on()    { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; }
has_in()    { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if any(i.get("tag")==sys.argv[2] for i in d.get("inbounds",[])) else 1)' "$SB" "$1" 2>/dev/null; }
jget()      { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }

# Новый конфиг лежит в $SB.new: sing-box check, бэкап рядом, подмена. Битый до systemd не доедет.
sb_commit() {
  if ! sing-box check -c "$SB.new" >/tmp/plr-check.log 2>&1; then
    rm -f "$SB.new"; sed 's/^/    /' /tmp/plr-check.log | head -5
    die "sing-box отверг конфиг, ничего не изменено"
  fi
  [ -f "$SB" ] && cp -a "$SB" "$SB.bak-$(date +%s)"
  mv "$SB.new" "$SB"
}

sb_restart() {
  systemctl enable sing-box >/dev/null 2>&1
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || die "sing-box не поднялся: journalctl -u sing-box -n 20 --no-pager"
}

need_root() { [ "$(id -u)" -eq 0 ] || die "нужен root"; }

# ================================================================ выход ===
# Токен: plr1.<base64url(json)>.<первые 8 hex sha256 от json>. Контрольная сумма ловит обрезанную
# или испорченную вставку раньше, чем вход попробует подключиться.
print_token() {
  local token
  token=$(python3 - "$EXIT_STATE" <<'PY'
import base64, hashlib, json, sys
s = json.load(open(sys.argv[1]))
body = {k: s[k] for k in ("name", "host", "port", "uuid", "pbk", "sid", "sni")}
body["v"] = 1
raw = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
print("plr1." + base64.urlsafe_b64encode(raw).decode().rstrip("=") + "." + hashlib.sha256(raw).hexdigest()[:8])
PY
) || die "не смог собрать токен из $EXIT_STATE"
  printf '\n  %sтокен выхода%s %s(это секрет — как пароль)%s\n\n%s\n\n' "$C_B" "$C_RST" "$C_GRY" "$C_RST" "$token"
  note "на входном сервере: plr link <токен>  (в packetlab: меню → r «вход → выход»)"
  printf '\n'
}

exit_state() { [ -f "$EXIT_STATE" ] && [ -f "$SB" ] && has_in relay-in && printf up || printf off; }

exit_remove() {
  [ -f "$SB" ] && has_in relay-in || { rm -f "$EXIT_STATE"; ok "relay-in нет — нечего убирать"; return 0; }
  local port listen
  port=$(python3 -c 'import json,sys;print(next(i["listen_port"] for i in json.load(open(sys.argv[1]))["inbounds"] if i.get("tag")=="relay-in"))' "$SB")
  listen=$(python3 -c 'import json,sys;print(next(i.get("listen","") for i in json.load(open(sys.argv[1]))["inbounds"] if i.get("tag")=="relay-in"))' "$SB")
  python3 - "$SB" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["inbounds"] = [i for i in d.get("inbounds", []) if i.get("tag") != "relay-in"]
json.dump(d, open(p + ".new", "w"), indent=2, ensure_ascii=False)
PY
  sb_commit
  rm -f "$EXIT_STATE"
  sb_restart
  if [ "$listen" = 127.0.0.1 ]; then
    hap_del
    ok "выход убран, маршрут в haproxy снят; входы с этим токеном больше не подключатся"
  else
    ufw_on && ufw delete allow "$port/tcp" >/dev/null 2>&1
    ok "выход убран, порт $port закрыт; входы с этим токеном больше не подключатся"
  fi
}

# --------------------------------------------------------------- haproxy ---
# Если на сервере уже стоит haproxy-мультиплексор на 443 (так ставит packetlab), relay-in
# прячется за ним по SNI: наружу торчит только 443, отдельного порта нет. Строки с
# маркером «# packetlab:relay» — те же, что понимает packetlab (pl_haproxy_*).
HAP=/etc/haproxy/haproxy.cfg
hap_front() {
  command -v haproxy >/dev/null && systemctl is-active --quiet haproxy \
    && grep -qE 'bind (\*|0\.0\.0\.0|:::?):443' "$HAP" 2>/dev/null \
    && grep -q 'req.ssl_sni' "$HAP" 2>/dev/null
}
hap_sni_used() { grep -qiE "req\.ssl_sni -i $1( |\$)" "$HAP" 2>/dev/null; }

hap_edit() {   # hap_edit add <sni> <порт> | del
  local bak="$HAP.bak-$(date +%s)"
  cp -a "$HAP" "$bak"
  python3 - "$HAP" "$@" <<'PY'
import sys
p, action = sys.argv[1:3]
mark = "# packetlab:relay"
lines = open(p).read().split("\n")
out, skip = [], False
for l in lines:   # старое снимаем всегда — add идемпотентен
    ours = l.rstrip().endswith(mark)
    if l.startswith("backend relay ") and ours: skip = True; continue
    if skip and (l.startswith("backend ") or l.startswith("frontend ")): skip = False
    if skip or ours: continue
    out.append(l)
s = "\n".join(out)
if action == "add":
    sni, port = sys.argv[3:5]
    rule = f"    use_backend relay if {{ req.ssl_sni -i {sni} }}  {mark}\n"
    block = f"\nbackend relay  {mark}\n    mode tcp\n    server relay 127.0.0.1:{port}\n"
    s = s.replace("    default_backend", rule + "    default_backend", 1) + ("" if s.endswith("\n") else "\n") + block
open(p, "w").write(s)
PY
  if ! haproxy -c -f "$HAP" >/dev/null 2>&1; then
    cp -a "$bak" "$HAP"; die "haproxy.cfg невалиден, откатил"
  fi
  systemctl reload haproxy
}
hap_add() { hap_edit add "$1" "$2"; }
hap_del() { hap_edit del; }

# SNI для relay-in за haproxy: заданный PLR_SNI, иначе первый из списка, не занятый другим маршрутом.
pick_hap_sni() {
  local c
  if [ -n "${PLR_SNI:-}" ]; then
    hap_sni_used "$PLR_SNI" && die "SNI $PLR_SNI уже занят другим маршрутом haproxy — задай другой PLR_SNI"
    printf '%s' "$PLR_SNI"; return
  fi
  for c in www.bing.com www.amazon.com www.cloudflare.com www.nvidia.com www.tesla.com; do
    hap_sni_used "$c" && continue
    timeout 8 openssl s_client -connect "$c:443" -servername "$c" -tls1_3 </dev/null >/dev/null 2>&1 || continue
    printf '%s' "$c"; return
  done
  die "не нашёл свободный SNI с TLS 1.3 — задай PLR_SNI"
}

free_local_port() {
  local p _
  for _ in $(seq 50); do
    p=$(( 20000 + RANDOM % 40000 ))
    port_busy "$p" || { printf '%s' "$p"; return; }
  done
  die "не нашёл свободный порт"
}

# Перенос уже работающего relay-in с отдельного порта за haproxy: ключи и uuid те же,
# меняются порт (на 443) и, если старый занят, SNI. Входам нужен новый токен.
exit_move() {
  [ "$(exit_state)" = up ] || die "выход не поднят — нечего переносить"
  [ "$(jget "$EXIT_STATE" mode)" = haproxy ] && { ok "выход уже за haproxy — тот же токен:"; print_token; return 0; }
  hap_front || die "haproxy-мультиплексора на 443 нет — переносить некуда"
  local old sni lport
  old=$(jget "$EXIT_STATE" port); sni=$(jget "$EXIT_STATE" sni)
  hap_sni_used "$sni" && sni=$(pick_hap_sni)
  lport=$(free_local_port)
  python3 - "$SB" "$lport" "$sni" <<'PY' || die "не смог изменить $SB"
import json, sys
p, lport, sni = sys.argv[1:4]
d = json.load(open(p))
for i in d["inbounds"]:
    if i.get("tag") == "relay-in":
        i["listen"] = "127.0.0.1"; i["listen_port"] = int(lport)
        i["tls"]["server_name"] = sni
        i["tls"]["reality"]["handshake"] = {"server": sni, "server_port": 443}
json.dump(d, open(p + ".new", "w"), indent=2, ensure_ascii=False)
PY
  sb_commit
  sb_restart
  port_busy "$lport" || die "sing-box запущен, но порт $lport не слушается"
  hap_add "$sni" "$lport"
  ufw_on && ufw delete allow "$old/tcp" >/dev/null 2>&1
  python3 - "$EXIT_STATE" "$sni" "$lport" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d.update({"port": 443, "sni": sys.argv[2], "mode": "haproxy", "lport": int(sys.argv[3])})
json.dump(d, open(p, "w"), indent=2)
os.chmod(p, 0o600)
PY
  ok "relay-in за haproxy: 443/tcp, SNI $sni (порт $old закрыт)"
  warn "старый токен больше не работает — на входах: plr link <новый токен>"
  print_token
}

exit_up() {
  if [ "$(exit_state)" = up ]; then
    ok "выход уже поднят — тот же токен:"
    print_token
    if [ "$(jget "$EXIT_STATE" mode)" != haproxy ] && hap_front; then
      note "на сервере есть haproxy на 443: plr exit --move спрячет relay-in за ним (токен сменится)"
    fi
    return 0
  fi

  local missing=() c
  for c in curl python3 openssl; do command -v "$c" >/dev/null || missing+=("$c"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    say "ставлю ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" </dev/null >/dev/null 2>&1 \
      || die "не установилось: ${missing[*]}"
  fi

  local fresh=0 arch url tmp
  if ! command -v sing-box >/dev/null; then
    case "$(uname -m)" in
      x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) die "архитектура $(uname -m) не поддерживается" ;;
    esac
    say "ставлю sing-box"
    url=$(curl -fsS https://api.github.com/repos/SagerNet/sing-box/releases/latest | python3 -c '
import json, re, sys
for a in json.load(sys.stdin)["assets"]:
    if re.search(r"linux_" + sys.argv[1] + r"\.deb$", a["name"]):
        print(a["browser_download_url"]); break' "$arch")
    [ -n "$url" ] || die "не нашёл .deb sing-box в релизах GitHub"
    tmp=$(mktemp /tmp/plr-XXXX.deb)
    curl -fsSL -o "$tmp" "$url" || die "не скачался $url"
    dpkg -i "$tmp" >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get -f install -y -qq </dev/null >/dev/null 2>&1
    rm -f "$tmp"
    command -v sing-box >/dev/null || die "sing-box не установился"
    fresh=1
  fi
  ok "sing-box $(sing-box version | head -1 | awk '{print $3}')"

  local sni port host name kp priv pbk uuid sid _ mode=public listen='::' lport=0
  if [ -z "${PLR_PORT:-}" ] && hap_front; then
    mode=haproxy; listen=127.0.0.1
    sni=$(pick_hap_sni)
  else
    sni=${PLR_SNI:-www.bing.com}
  fi
  timeout 8 openssl s_client -connect "$sni:443" -servername "$sni" -tls1_3 </dev/null >/dev/null 2>&1 \
    || die "$sni не отвечает по TLS 1.3 отсюда — REALITY с ним работать не будет; задай PLR_SNI"

  if [ "$mode" = haproxy ]; then
    lport=$(free_local_port); port=$lport
  elif [ -n "${PLR_PORT:-}" ]; then
    port=$PLR_PORT
    port_busy "$port" && die "порт $port занят"
  elif ! port_busy 443; then
    port=443
  else
    for _ in $(seq 50); do
      port=$(( 20000 + RANDOM % 40000 ))
      port_busy "$port" || break
    done
  fi

  host=${PLR_HOST:-$(curl -4 -fsS -m 10 https://api.ipify.org 2>/dev/null || curl -4 -fsS -m 10 https://ifconfig.me 2>/dev/null)}
  [ -n "$host" ] || die "не смог узнать внешний IP — задай PLR_HOST"
  name=${PLR_NAME:-$(hostname -s)}

  kp=$(sing-box generate reality-keypair)
  priv=$(printf '%s\n' "$kp" | awk '/PrivateKey/{print $2}')
  pbk=$(printf '%s\n' "$kp"  | awk '/PublicKey/{print $2}')
  uuid=$(sing-box generate uuid)
  sid=$(openssl rand -hex 8)
  [ -n "$priv" ] && [ -n "$pbk" ] && [ -n "$uuid" ] || die "sing-box не сгенерировал ключи"

  install -d -m 755 /etc/sing-box
  [ -f "$SB" ] || printf '{ "log": { "level": "warn" }, "inbounds": [], "outbounds": [ { "type": "direct", "tag": "direct" } ] }\n' > "$SB"
  python3 - "$SB" "$port" "$uuid" "$sni" "$priv" "$sid" "$fresh" "$listen" <<'PY' || die "не смог прочитать $SB"
import json, sys
p, port, uuid, sni, priv, sid, fresh, listen = sys.argv[1:9]
d = json.load(open(p))
ins = [i for i in d.get("inbounds", []) if i.get("tag") != "relay-in"]
# Пакет sing-box кладёт демонстрационный shadowsocks на 8080 — на свежей установке это открытый
# прокси с чужим паролем. Свои инбаунды всегда с тегом, так что нетегированные — от пакета.
if fresh == "1":
    ins = [i for i in ins if i.get("tag")]
ins.append({
    "type": "vless", "tag": "relay-in", "listen": listen, "listen_port": int(port),
    "users": [{"name": "relay", "uuid": uuid, "flow": "xtls-rprx-vision"}],
    "tls": {"enabled": True, "server_name": sni, "reality": {
        "enabled": True, "handshake": {"server": sni, "server_port": 443},
        "private_key": priv, "short_id": [sid]}},
})
d["inbounds"] = ins
if not d.get("outbounds"):
    d["outbounds"] = [{"type": "direct", "tag": "direct"}]
json.dump(d, open(p + ".new", "w"), indent=2, ensure_ascii=False)
PY
  sb_commit

  if [ "$mode" = public ] && ufw_on; then
    ufw allow "$port/tcp" comment "packetlab:relay" >/dev/null 2>&1 && ok "порт $port открыт в UFW"
  fi
  sb_restart
  port_busy "$port" || die "sing-box запущен, но порт $port не слушается"
  if [ "$mode" = haproxy ]; then
    hap_add "$sni" "$port"
    ok "relay-in за haproxy: 443/tcp, SNI $sni (локально 127.0.0.1:$port)"
    port=443
  else
    ok "relay-in слушает $port/tcp (REALITY под $sni)"
  fi

  install -d -m 700 "$STATE_DIR"
  python3 - "$EXIT_STATE" "$name" "$host" "$port" "$uuid" "$pbk" "$sid" "$sni" "$mode" "$lport" <<'PY'
import json, os, sys
p = sys.argv[1]
d = dict(zip(("name", "host", "port", "uuid", "pbk", "sid", "sni", "mode", "lport"), sys.argv[2:]))
d["port"] = int(d["port"]); d["lport"] = int(d["lport"])
json.dump(d, open(p, "w"), indent=2)
os.chmod(p, 0o600)
PY
  print_token
}

# ================================================================= вход ===
# Токен → нормализованный JSON на stdout; битый токен → текст ошибки на stderr и код 1.
decode_token() {
  python3 - "$1" <<'PY'
import base64, hashlib, json, sys
t = "".join(sys.argv[1].split())
try:
    ver, body, crc = t.split(".")
except ValueError:
    sys.exit("это не токен выхода: ждал plr1.<данные>.<сумма>")
if ver != "plr1":
    sys.exit("неизвестная версия токена: " + ver)
try:
    raw = base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))
except Exception:
    sys.exit("токен повреждён: данные не читаются")
if hashlib.sha256(raw).hexdigest()[:8] != crc:
    sys.exit("токен повреждён или обрезан: не сходится контрольная сумма")
d = json.loads(raw)
missing = [k for k in ("host", "port", "uuid", "pbk", "sid", "sni") if not d.get(k)]
if missing:
    sys.exit("в токене нет полей: " + ", ".join(missing))
print(json.dumps(d))
PY
}

# off — не связан; linked — relay-out есть, трафик напрямую; on — трафик через выход.
entry_state() {
  python3 - "$SB" <<'PY' 2>/dev/null || printf off
import json, sys
d = json.load(open(sys.argv[1]))
if not any(o.get("tag") == "relay-out" for o in d.get("outbounds", [])):
    print("off", end="")
elif d.get("route", {}).get("final") == "relay-out":
    print("on", end="")
else:
    print("linked", end="")
PY
}

entry_where() {
  [ -f "$ENTRY_STATE" ] || return 0
  printf '%s %s:%s' "$(jget "$ENTRY_STATE" name)" "$(jget "$ENTRY_STATE" host)" "$(jget "$ENTRY_STATE" port)"
}

# entry_edit <link|on|off|unlink> [json выхода]
entry_edit() {
  python3 - "$SB" "$PROBE" "$@" <<'PY' || die "не смог изменить $SB"
import json, sys
p, probe, action = sys.argv[1:4]
d = json.load(open(p))
route = d.setdefault("route", {})
if action in ("link", "unlink"):
    d["outbounds"] = [o for o in d.get("outbounds", []) if o.get("tag") != "relay-out"]
    d["inbounds"] = [i for i in d.get("inbounds", []) if i.get("tag") != "relay-probe"]
    route["rules"] = [r for r in route.get("rules", []) if r.get("inbound") != ["relay-probe"]]
if action == "link":
    x = json.loads(sys.argv[4])
    d["outbounds"].append({
        "type": "vless", "tag": "relay-out", "server": x["host"], "server_port": int(x["port"]),
        "uuid": x["uuid"], "flow": "xtls-rprx-vision", "packet_encoding": "xudp",
        "tls": {"enabled": True, "server_name": x["sni"],
                "utls": {"enabled": True, "fingerprint": "chrome"},
                "reality": {"enabled": True, "public_key": x["pbk"], "short_id": x["sid"]}},
    })
    d["inbounds"].append({"type": "mixed", "tag": "relay-probe", "listen": "127.0.0.1", "listen_port": int(probe)})
    route["rules"].append({"inbound": ["relay-probe"], "outbound": "relay-out"})
elif action == "on":
    if not any(o.get("tag") == "relay-out" for o in d.get("outbounds", [])):
        sys.exit("выход не связан")
    route["final"] = "relay-out"
elif route.get("final") == "relay-out":  # off, unlink
    route.pop("final")
if not route.get("rules"):
    route.pop("rules", None)
if not route:
    d.pop("route")
json.dump(d, open(p + ".new", "w"), indent=2, ensure_ascii=False)
PY
  sb_commit
}

entry_link() {
  local json
  [ -f "$SB" ] || die "нет $SB — на входе должен стоять sing-box с инбаундами клиентов"
  json=$(decode_token "$1") || exit 1
  entry_edit link "$json"
  sb_restart
  install -d -m 700 "$STATE_DIR"
  python3 - "$ENTRY_STATE" "$json" <<'PY'
import json, os, sys
x = json.loads(sys.argv[2])
json.dump({"name": x.get("name") or x["host"], "host": x["host"], "port": x["port"]}, open(sys.argv[1], "w"), indent=2)
os.chmod(sys.argv[1], 0o600)
PY
  ok "связан с выходом $(entry_where) — трафик клиентов пока идёт напрямую"
}

# Ответ через relay-probe должен прийти с IP выхода.
entry_test() {
  local host want got t0 ms
  [ "$(entry_state)" = off ] && die "выход не связан"
  host=$(jget "$ENTRY_STATE" host)
  want=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
  [ -z "$want" ] && want=$host
  t0=$(date +%s%N)
  got=$(curl -s -m 12 -x "socks5h://127.0.0.1:$PROBE" https://api.ipify.org 2>/dev/null)
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  if [ -z "$got" ]; then
    err "через выход ответа нет"
    note "здесь: journalctl -u sing-box -n 20 --no-pager; на выходе: plr exit (покажет, поднят ли)"
    return 1
  fi
  if [ "$got" != "$want" ]; then
    warn "ответ пришёл с $got, а выход — $want (у выхода другой исходящий IP?)"
    return 0
  fi
  ok "через выход: $got, $ms мс"
}

entry_on() {
  entry_test || die "проверка не прошла — трафик не переключаю"
  entry_edit on
  sb_restart
  ok "трафик клиентов идёт через $(jget "$ENTRY_STATE" name)"
}

entry_off() {
  entry_edit off
  sb_restart
  ok "трафик клиентов идёт напрямую"
}

entry_unlink() {
  entry_edit unlink
  sb_restart
  rm -f "$ENTRY_STATE"
  ok "выход отвязан"
}

status() {
  case "$(entry_state)" in
    off)    say "вход: не связан" ;;
    linked) say "вход: связан с $(entry_where), трафик напрямую" ;;
    on)     say "вход: трафик через $(entry_where)" ;;
  esac
  if [ "$(exit_state)" = up ]; then
    say "выход: relay-in на $(jget "$EXIT_STATE" port)/tcp$([ "$(jget "$EXIT_STATE" mode)" = haproxy ] && printf ' (за haproxy, SNI %s)' "$(jget "$EXIT_STATE" sni)") — plr exit покажет токен"
  else
    say "выход: не поднят"
  fi
}

# ================================================================= CLI ====
case "${1:-status}" in
  exit)        need_root
               case "${2:-}" in
                 --remove) exit_remove ;;
                 --move)   exit_move ;;
                 *)        exit_up ;;
               esac ;;
  link)        need_root; [ -n "${2:-}" ] || die "plr link <токен>"; entry_link "$2" && entry_test ;;
  test)        entry_test ;;
  on)          need_root; entry_on ;;
  off)         need_root; entry_off ;;
  unlink)      need_root; entry_unlink ;;
  status)      status ;;
  state)       entry_state ;;         # для меню packetlab: off | linked | on
  exit-state)  exit_state ;;          # off | up
  where)       entry_where ;;
  *)           die "plr [exit [--remove] | link <токен> | test | on | off | unlink | status]" ;;
esac
