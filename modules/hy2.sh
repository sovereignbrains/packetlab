#!/usr/bin/env bash
MOD_ID=hy2
MOD_NAME="Hysteria2"
MOD_DESC="QUIC/UDP, BBR (без Brutal)"
MOD_ENGINE=sing-box
MOD_PORT=9445
# Порт можно сменить (packetlab reconfig hy2 port=443): выбор хранится в meta.json как hy2_port.
declare -F pl_meta_get >/dev/null 2>&1 && [ -n "$(pl_meta_get hy2_port)" ] && MOD_PORT=$(pl_meta_get hy2_port)
MOD_PROTO=udp
MOD_LEVEL=advanced
MOD_USERS='{"name":"%name%","password":"%pass%"}'

HY2_DECOY=/var/www/decoy

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" udp || { printf down; return; }
  pl_ufw_allows "$MOD_PORT" udp || { printf blocked; return; }
  pl_meta_has hy2_port || { printf broken; return; }
  printf up
}

# Поля инбаунда сверх основных (JSON-объект), собираются из состояния сервера:
#  - ignore_client_bandwidth=true всегда. up_mbps/down_mbps намеренно не заданы, но одного
#    этого мало: без ignore_client_bandwidth сервер включает Brutal на скорость, которую
#    назвал клиент (sing-quic, service.go). С ним при пустых лимитах оба конца идут на BBR.
#    Brutal игнорирует сигналы перегрузки, поэтому нужен именно BBR.
#  - masquerade: если есть decoy-сайт, на не-hy2 запрос по HTTP/3 (зонд) отвечает он, а не 404.
#  - hy2_obfs в meta.json (salamander | gecko): обфускация QUIC. По умолчанию выключена: она
#    меняет ссылки всех клиентов, а gecko понимает только sing-box ≥ 1.14 (не mihomo и не
#    официальный Hysteria2). Пароль обфускации (hy2_obfs_pass) выпускается сам.
#    04.11: у владельца с gecko клиент (Sovereign, sing-box 1.14.4) не соединялся, с salamander
#    заработало сразу — для живых клиентов брать salamander, gecko только после проверки.
#  - hy2_bbr в meta.json (conservative | standard | aggressive): профиль BBR, по умолчанию standard.
_hy2_extras() {
  local ob bb pass=""
  ob=$(pl_meta_get hy2_obfs); bb=$(pl_meta_get hy2_bbr)
  case "$ob" in
    ''|off) ob="" ;;
    salamander|gecko) ;;
    *) ui_warn "hy2_obfs=$ob не понятен (salamander или gecko) — обфускация выключена" >&2; ob="" ;;
  esac
  case "$bb" in
    ''|standard) bb="" ;;
    conservative|aggressive) ;;
    *) ui_warn "hy2_bbr=$bb не понятен (conservative, standard, aggressive) — оставлен standard" >&2; bb="" ;;
  esac
  if [ -n "$ob" ]; then
    pass=$(pl_meta_get hy2_obfs_pass)
    [ -z "$pass" ] && { pass=$(pl_hex 16); pl_meta_set hy2_obfs_pass "$pass"; }
  fi
  python3 - "$ob" "$pass" "$bb" "$HY2_DECOY" <<'PY'
import json, os, sys
ob, pw, bb, decoy = sys.argv[1:]
d = {"ignore_client_bandwidth": True}
if os.path.isfile(decoy + "/index.html"):
    d["masquerade"] = "file://" + decoy
if ob:
    d["obfs"] = {"type": ob, "password": pw}
if bb:
    d["bbr_profile"] = bb
print(json.dumps(d))
PY
}

mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }
  local users extras inb; users=$(pl_inbound_users) || return 1
  extras=$(_hy2_extras) || return 1
  inb=$(cat <<JSON
{ "type":"hysteria2","tag":"${MOD_ID}-in","listen":"::","listen_port":${MOD_PORT},
  "users":${users},
  "tls":{"enabled":true,"server_name":"${PL_DOMAIN}","alpn":["h3"],
    "certificate_path":"${PL_CERT}","key_path":"${PL_KEY}"} }
JSON
)
  inb=$(python3 -c 'import json,sys;a=json.loads(sys.argv[1]);a.update(json.loads(sys.argv[2]));print(json.dumps(a))' "$inb" "$extras") || return 1
  pl_singbox_add_inbound "$inb" || return 1
  pl_ufw_sync_module
  pl_meta_set "${MOD_ID}_port" "$MOD_PORT"
  pl_singbox_apply && pl_sub_reload
}

# packetlab reconfig hy2 [obfs=salamander|gecko|off] [port=N] [bbr=conservative|standard|aggressive]
# Применяет настройки к уже стоящему инбаунду (и к decoy-сайту, если он появился после
# установки). Пользователи и их пароли не трогаются; sing-box перезапускается, только если
# конфиг изменился. Смена obfs или порта меняет ссылки клиентов.
# 443/udp haproxy не занимает (он держит только 443/tcp), так что порт 443 для hy2 свободен.
mod_reconfig() {
  pl_singbox_has_tag "${MOD_ID}-in" || { ui_err "Hysteria2 не установлен"; return 1; }
  local a oldport="$MOD_PORT" newport="$MOD_PORT"
  for a in "$@"; do
    case "$a" in
      obfs=*) pl_meta_set hy2_obfs "${a#obfs=}" ;;
      bbr=*)  pl_meta_set hy2_bbr "${a#bbr=}" ;;
      port=*) newport="${a#port=}"
              case "$newport" in ''|*[!0-9]*) ui_err "порт должен быть числом"; return 1 ;; esac
              [ "$newport" -ge 1 ] && [ "$newport" -le 65535 ] || { ui_err "порт вне 1-65535"; return 1; } ;;
      *) ui_err "не понял «$a» (obfs=, bbr=, port=)"; return 1 ;;
    esac
  done
  if [ "$newport" != "$oldport" ] && pl_port_listening "$newport" udp; then
    ui_err "порт $newport/udp уже занят"; return 1
  fi
  local extras r; extras=$(_hy2_extras) || return 1
  r=$(python3 - "$extras" "$PL_SB" "$newport" <<'PY'
import json, sys
ex, p, port = json.loads(sys.argv[1]), sys.argv[2], int(sys.argv[3])
d = json.load(open(p)); before = json.dumps(d, sort_keys=True)
for i in d["inbounds"]:
    if i.get("tag") == "hy2-in":
        for k in ("ignore_client_bandwidth", "masquerade", "obfs", "bbr_profile"):
            i.pop(k, None)
        i.update(ex)
        i["listen_port"] = port
if json.dumps(d, sort_keys=True) == before:
    print("same")
else:
    json.dump(d, open(p + ".new", "w"), indent=2, ensure_ascii=False)
    print("changed")
PY
  ) || return 1
  [ "$r" = same ] && { ui_ok "Hysteria2 уже настроен так"; return 0; }
  if ! sing-box check -c "$PL_SB.new" >/dev/null 2>&1; then
    ui_err "sing-box отверг конфиг, изменения не применены"
    sing-box check -c "$PL_SB.new" 2>&1 | head -5 | while read -r l; do ui_note "$l"; done
    rm -f "$PL_SB.new"; return 1
  fi
  cp -a "$PL_SB" "$PL_SB.bak-$(date +%s)"
  mv "$PL_SB.new" "$PL_SB"
  if [ "$newport" != "$oldport" ]; then
    pl_ufw_open "$newport" udp "$MOD_ID"
    pl_ufw_close "$oldport" udp
    pl_meta_set "${MOD_ID}_port" "$newport"
  fi
  pl_singbox_apply && pl_sub_reload && ui_ok "Hysteria2 перенастроен"
}
mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_ufw_close "$MOD_PORT" udp
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_port" "${MOD_ID}_obfs_pass"
  pl_singbox_apply && pl_sub_reload
}

# Пароль на проводе — только password. Имя пользователя в ссылку НЕ входит:
# sing-box сравнивает ровно пароль (у каждого пользователя он свой), а
# "user:pass" даст ошибку аутентификации.
mod_link() {  # mod_link <формат> [пользователь]
  local name="Hysteria2" u p ob op
  u=$(pl_link_user "${2:-}"); p=$(pl_cred "$u" "$MOD_ID" pass) || return 1
  ob=$(pl_meta_get hy2_obfs); op=$(pl_meta_get hy2_obfs_pass)
  case "$ob" in salamander|gecko) [ -n "$op" ] || ob="" ;; *) ob="" ;; esac
  case "$1" in
    clash)
      if [ "$ob" = gecko ]; then ui_warn "mihomo не знает обфускацию gecko — в Clash этот протокол не уезжает" >&2; return 0; fi
      cat <<YAML
- name: ${name}
  type: hysteria2
  server: ${PL_DOMAIN}
  port: $(pl_meta_get ${MOD_ID}_port)
  password: ${p}
  sni: ${PL_DOMAIN}
  alpn: [h3]
  skip-cert-verify: false
$([ -n "$ob" ] && printf '  obfs: salamander\n  obfs-password: %s\n' "$op")
YAML
    ;;
    singbox) cat <<JSON
{ "type":"hysteria2","tag":"${name}","server":"${PL_DOMAIN}","server_port":$(pl_meta_get ${MOD_ID}_port),
  "password":"${p}"$([ -n "$ob" ] && printf ',"obfs":{"type":"%s","password":"%s"}' "$ob" "$op"),
  "tls":{"enabled":true,"server_name":"${PL_DOMAIN}","alpn":["h3"]} }
JSON
    ;;
    uri) printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=0%s#%s\n' \
      "$(pl_urlenc "$p")" "$PL_DOMAIN" "$(pl_meta_get ${MOD_ID}_port)" "$PL_DOMAIN" \
      "$([ -n "$ob" ] && printf '&obfs=%s&obfs-password=%s' "$ob" "$(pl_urlenc "$op")")" "$name" ;;
  esac
}
