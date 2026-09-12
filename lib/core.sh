#!/usr/bin/env bash
# packetlab — общий слой. Всё, что модули делают с системой, проходит здесь.
# Правило: любая функция, меняющая систему, идемпотентна и умеет откатиться.

PL_ETC=${PL_ETC:-/etc/packetlab}
PL_META="$PL_ETC/meta.json"
PL_USERS="$PL_ETC/users.json"
PL_SB=/etc/sing-box/config.json
PL_HAP=/etc/haproxy/haproxy.cfg

PL_DOMAIN=$(python3 -c "import json;print(json.load(open('$PL_META'))['domain'])" 2>/dev/null || echo '')
PL_USER=$(python3   -c "import json;print(json.load(open('$PL_META')).get('user','Boss'))" 2>/dev/null || echo Boss)
PL_CERT="/etc/letsencrypt/live/$PL_DOMAIN/fullchain.pem"
PL_KEY="/etc/letsencrypt/live/$PL_DOMAIN/privkey.pem"

# ------------------------------------------------------------- секреты ----
pl_uuid()   { cat /proc/sys/kernel/random/uuid; }
pl_secret() { openssl rand -base64 18 | tr -d '\n'; }
pl_hex()    { openssl rand -hex "${1:-8}" | tr -d '\n'; }
pl_urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

# ---------------------------------------------------------------- meta ----
pl_meta_get() {
  python3 -c "import json,sys;print(json.load(open('$PL_META')).get(sys.argv[1],''))" "$1" 2>/dev/null
}
pl_meta_set() {
  python3 - "$1" "$2" <<'PY'
import json,sys
p="/etc/packetlab/meta.json"
d=json.load(open(p)); d[sys.argv[1]]=sys.argv[2]
json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
PY
}
pl_meta_del() {
  python3 - "$@" <<'PY'
import json,sys
p="/etc/packetlab/meta.json"
d=json.load(open(p))
for k in sys.argv[1:]: d.pop(k,None)
json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
PY
}

# ------------------------------------------------------------- sing-box ---
pl_singbox_has_tag() {
  python3 -c "
import json,sys
try: d=json.load(open('$PL_SB'))
except Exception: sys.exit(1)
sys.exit(0 if any(i.get('tag')==sys.argv[1] for i in d.get('inbounds',[])) else 1)" "$1" 2>/dev/null
}

# Пишет во временный файл, проверяет `sing-box check`, и только потом
# подменяет боевой конфиг. Битый конфиг до systemd не доедет.
pl_singbox_add_inbound() {
  local json="$1"
  cp -a "$PL_SB" "$PL_SB.bak-$(date +%s)"
  python3 - "$json" <<'PY' || return 1
import json,sys
p="/etc/sing-box/config.json"
d=json.load(open(p)); nb=json.loads(sys.argv[1])
d.setdefault("inbounds",[])
if any(i.get("tag")==nb["tag"] for i in d["inbounds"]):
    sys.exit(0)
d["inbounds"].append(nb)
json.dump(d,open(p+".new","w"),indent=2,ensure_ascii=False)
PY
  [ -f "$PL_SB.new" ] || return 0
  if sing-box check -c "$PL_SB.new" >/dev/null 2>&1; then
    mv "$PL_SB.new" "$PL_SB"; return 0
  fi
  ui_err "sing-box отверг конфиг, изменения не применены"
  sing-box check -c "$PL_SB.new" 2>&1 | head -5 | while read -r l; do ui_note "$l"; done
  rm -f "$PL_SB.new"; return 1
}

pl_singbox_del_inbound() {
  cp -a "$PL_SB" "$PL_SB.bak-$(date +%s)"
  python3 - "$1" <<'PY' || return 1
import json,sys
p="/etc/sing-box/config.json"
d=json.load(open(p))
d["inbounds"]=[i for i in d.get("inbounds",[]) if i.get("tag")!=sys.argv[1]]
json.dump(d,open(p+".new","w"),indent=2,ensure_ascii=False)
PY
  if sing-box check -c "$PL_SB.new" >/dev/null 2>&1; then
    mv "$PL_SB.new" "$PL_SB"; return 0
  fi
  rm -f "$PL_SB.new"; ui_err "конфиг не прошёл проверку"; return 1
}

pl_singbox_apply() {
  sing-box check -c "$PL_SB" >/dev/null 2>&1 || { ui_err "конфиг невалиден, рестарт отменён"; return 1; }
  systemctl restart sing-box || return 1
  sleep 1
  systemctl is-active --quiet sing-box || { ui_err "sing-box не поднялся"; return 1; }
}

# ------------------------------------------------------------------ ufw ---
pl_port_listening() {
  local port="$1" proto="$2" flag
  [ "$proto" = udp ] && flag=-uln || flag=-tln
  ss $flag 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

pl_ufw_allows() {
  ufw status 2>/dev/null | grep -qE "^${1}/${2}[[:space:]]+ALLOW"
}

# Открытие порта — часть установки протокола, а не отдельный шаг.
pl_ufw_open() {
  local port="$1" proto="$2" tag="$3"
  pl_ufw_allows "$port" "$proto" && return 0
  ufw allow "${port}/${proto}" comment "packetlab:${tag}" >/dev/null 2>&1
}

pl_ufw_close() {
  ufw delete allow "${1}/${2}" >/dev/null 2>&1 || true
}

# Публичный порт модуля, той же логикой, что mod_install и pl_preflight:
# протоколы за haproxy (MOD_VIA_HAPROXY=yes) делят 443/tcp, остальные слушают
# сами на MOD_PORT/MOD_PROTO. Идемпотентно — pl_ufw_open не дублирует правило.
# Модуль должен быть уже source'нут в этой оболочке (или подоболочке):
# функция читает его MOD_ID/MOD_VIA_HAPROXY/MOD_PORT/MOD_PROTO из области
# видимости, как и mod_status/mod_install в самом модуле.
pl_ufw_sync_module() {
  if [ "${MOD_VIA_HAPROXY:-}" = yes ]; then
    pl_ufw_open 443 tcp "$MOD_ID"
  else
    pl_ufw_open "$MOD_PORT" "$MOD_PROTO" "$MOD_ID"
  fi
}

# Правила packetlab, за которыми уже нет слушателя.
pl_ufw_orphans() {
  local found=1 line port proto
  while read -r line; do
    port=${line%%/*}; proto=${line##*/}
    pl_port_listening "$port" "$proto" && continue
    ui_row "" "${port}/${proto}" off "нет слушателя"
    found=0
  done < <(ufw status 2>/dev/null | awk '/ALLOW/ && $1 ~ /\// {print $1}' | sort -u)
  return $found
}

# -------------------------------------------------------------- haproxy ---
# Бэкенды добавляются между маркерами, поэтому удаление точное и не задевает
# ручные правки.
pl_haproxy_add_sni() {
  local sni="$1" backend="$2" port="$3"
  grep -q "packetlab:${backend}" "$PL_HAP" 2>/dev/null && return 0
  local bak="$PL_HAP.bak-$(date +%s)"
  cp -a "$PL_HAP" "$bak"
  python3 - "$sni" "$backend" "$port" <<'PY'
import sys
p="/etc/haproxy/haproxy.cfg"; sni,be,port=sys.argv[1:4]
s=open(p).read()
rule=f"    use_backend {be} if {{ req.ssl_sni -i {sni} }}  # packetlab:{be}\n"
block=f"\nbackend {be}  # packetlab:{be}\n    mode tcp\n    server {be} 127.0.0.1:{port}\n"
s=s.replace("    default_backend", rule+"    default_backend",1)
open(p,"w").write(s+block)
PY
  haproxy -c -f "$PL_HAP" >/dev/null 2>&1 \
    || { cp -a "$bak" "$PL_HAP"; ui_err "haproxy.cfg невалиден, откатил"; return 1; }
  systemctl reload haproxy
}

pl_haproxy_del_sni() {
  local backend="$1"
  local bak="$PL_HAP.bak-$(date +%s)"
  cp -a "$PL_HAP" "$bak"
  python3 - "$backend" <<'PY'
import sys,re
p="/etc/haproxy/haproxy.cfg"; be=sys.argv[1]
lines=open(p).read().split("\n"); out=[]; skip=False
for l in lines:
    if l.startswith(f"backend {be}") and f"packetlab:{be}" in l: skip=True; continue
    if skip and (l.startswith("backend ") or l.startswith("frontend ")): skip=False
    if skip: continue
    if f"packetlab:{be}" in l: continue
    out.append(l)
open(p,"w").write("\n".join(out))
PY
  haproxy -c -f "$PL_HAP" >/dev/null 2>&1 \
    || { cp -a "$bak" "$PL_HAP"; ui_err "haproxy.cfg невалиден, откатил"; return 1; }
  systemctl reload haproxy
}

# Бэкенд модуля есть в haproxy? Маркер ставит pl_haproxy_add_sni.
pl_haproxy_has_backend() {
  grep -q "packetlab:${1}" "$PL_HAP" 2>/dev/null
}

# Ключ в meta.json существует и непустой. Без него сервер подписок отдаёт
# конфиг с пустым паролем: клиент подключится, но не аутентифицируется.
pl_meta_has() {
  [ -n "$(pl_meta_get "$1")" ]
}

# ------------------------------------------------------------------ dns ---
# Проверяет A-запись, при отсутствии создаёт через Cloudflare API.
# Proxy обязан быть выключен: иначе Cloudflare терминирует TLS и SNI-роутинг
# ломается.
pl_dns_ensure() {
  local label="$1" fqdn="$1.$PL_DOMAIN" ip token zone
  [ "$label" = "@" ] && fqdn="$PL_DOMAIN"
  getent hosts "$fqdn" >/dev/null 2>&1 && return 0

  token=$(pl_meta_get cf_token); zone=$(pl_meta_get cf_zone)
  ip=$(pl_meta_get ip)
  [ -z "$token" ] && { ui_err "нет CF-токена, заведи A-запись $fqdn вручную"; return 1; }

  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone/dns_records" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"proxied\":false}" \
    | grep -q '"success":true' || { ui_err "не смог создать A-запись $fqdn"; return 1; }
  ui_ok "создана A-запись $fqdn"
}

# --------------------------------------------------------------- подписка -
pl_sub_reload()  { systemctl restart packetlab-sub 2>/dev/null || true; }
pl_sub_url() {
  local t; t=$(python3 -c "import json;print(json.load(open('$PL_USERS'))[0]['sub_token'])" 2>/dev/null)
  [ -n "$t" ] && printf 'https://%s/sub/%s\n' "$PL_DOMAIN" "$t"
}
