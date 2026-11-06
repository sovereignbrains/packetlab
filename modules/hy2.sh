#!/usr/bin/env bash
MOD_ID=hy2
MOD_NAME="Hysteria2"
MOD_DESC="QUIC/UDP, BBR (без Brutal), salamander"
MOD_ENGINE=sing-box
MOD_NEEDS_DOMAIN=no      # без домена — свой сертификат, клиент сверяет его пин
# С доменом порт 9445 (так стояло всегда), без домена — 443/udp: haproxy держит
# только 443/tcp, а 443/udp похож на обычный HTTP/3. Выбор хранится в meta.json
# как hy2_port, сменить — packetlab reconfig hy2 port=N.
MOD_PORT=9445
declare -F pl_meta_get >/dev/null 2>&1 && [ -z "${PL_DOMAIN:-}" ] && MOD_PORT=443
declare -F pl_meta_get >/dev/null 2>&1 && [ -n "$(pl_meta_get hy2_port)" ] && MOD_PORT=$(pl_meta_get hy2_port)
MOD_PROTO=udp
MOD_LEVEL=advanced
MOD_USERS='{"name":"%name%","password":"%pass%"}'

HY2_DECOY=/var/www/decoy
# Без домена: самоподписанный сертификат на безобидное имя. Клиент не проверяет
# цепочку, а сравнивает пин (sha256 открытого ключа), поэтому имя ни на что не
# влияет, кроме SNI в ClientHello. Сертификат не перевыпускается, пока модуль
# стоит: пин зашит у всех клиентов.
HY2_SELF_SNI=www.example.com
HY2_SELF_CRT="${PL_ETC:-/etc/packetlab}/hy2.crt"
HY2_SELF_KEY="${PL_ETC:-/etc/packetlab}/hy2.key"
# Перескок портов: UDP 20000-20100 перенаправляется на порт hy2 своей таблицей
# nftables. Фильтр, который душит один порт (у части провайдеров UDP режется
# по порту и объёму), не видит одного длинного потока. Фильтр стоит в prerouting,
# до ufw: ufw видит уже порт hy2, отдельные правила на диапазон ему не нужны.
HY2_HOP_LO=20000
HY2_HOP_HI=20100
HY2_HOP_NFT="${PL_ETC:-/etc/packetlab}/hop.nft"
HY2_HOP_UNIT=/etc/systemd/system/packetlab-hop.service

_hy2_self() { [ -z "${PL_DOMAIN:-}" ]; }
_hy2_sni()  { if _hy2_self; then printf '%s' "$HY2_SELF_SNI"; else printf '%s' "$PL_DOMAIN"; fi; }
_hy2_crt()  { if _hy2_self; then printf '%s' "$HY2_SELF_CRT"; else printf '%s' "$PL_CERT"; fi; }
_hy2_key()  { if _hy2_self; then printf '%s' "$HY2_SELF_KEY"; else printf '%s' "$PL_KEY"; fi; }

# Пин для sing-box (certificate_public_key_sha256): base64 от sha256 SPKI.
_hy2_pin() {
  openssl x509 -in "$HY2_SELF_CRT" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 -binary | base64
}
# Отпечаток для ссылок Hysteria2 (pinSHA256): sha256 всего сертификата, hex с двоеточиями.
_hy2_fpr() {
  openssl x509 -in "$HY2_SELF_CRT" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
}

_hy2_self_cert() {
  [ -s "$HY2_SELF_CRT" ] && [ -s "$HY2_SELF_KEY" ] && return 0
  mkdir -p "$(dirname "$HY2_SELF_CRT")"
  ( umask 077
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=$HY2_SELF_SNI" -addext "subjectAltName=DNS:$HY2_SELF_SNI" \
      -keyout "$HY2_SELF_KEY" -out "$HY2_SELF_CRT" >/dev/null 2>&1 ) \
    || { ui_err "openssl не сделал сертификат для Hysteria2"; return 1; }
  return 0

}

_hy2_hop_on() {
  local port="$1"
  mkdir -p "$(dirname "$HY2_HOP_NFT")"
  cat > "$HY2_HOP_NFT" <<NFT
add table inet plhop
delete table inet plhop
table inet plhop {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    udp dport ${HY2_HOP_LO}-${HY2_HOP_HI} redirect to :${port}
  }
}
NFT
  cat > "$HY2_HOP_UNIT" <<UNIT
[Unit]
Description=packetlab: Hysteria2 port hopping ${HY2_HOP_LO}-${HY2_HOP_HI} -> ${port}
After=network.target nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${HY2_HOP_NFT}
ExecStop=/usr/sbin/nft delete table inet plhop

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  if command -v nft >/dev/null 2>&1 && systemctl enable -q packetlab-hop 2>/dev/null \
     && systemctl restart packetlab-hop 2>/dev/null; then
    pl_meta_set hy2_hop "${HY2_HOP_LO}-${HY2_HOP_HI}"
    return 0
  fi
  # В контейнере nft может не дать NAT — протокол работает и без перескока.
  ui_warn "перескок портов не включился (nftables отказал — контейнер?), Hysteria2 только на $port/udp" >&2
  _hy2_hop_off
  return 0
}

_hy2_hop_off() {
  systemctl disable --now -q packetlab-hop 2>/dev/null
  nft delete table inet plhop 2>/dev/null
  rm -f "$HY2_HOP_UNIT" "$HY2_HOP_NFT"
  systemctl daemon-reload 2>/dev/null
  pl_meta_del hy2_hop
}

_hy2_hop_up() { nft list table inet plhop >/dev/null 2>&1; }

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" udp || { printf down; return; }
  pl_ufw_allows "$MOD_PORT" udp || { printf blocked; return; }
  pl_meta_has hy2_port || { printf broken; return; }
  if _hy2_self && [ ! -s "$HY2_SELF_CRT" ]; then printf broken; return; fi
  if pl_meta_has hy2_hop && ! _hy2_hop_up; then printf down; return; fi
  printf up
}

# Поля инбаунда сверх основных (JSON-объект), собираются из состояния сервера:
#  - ignore_client_bandwidth=true всегда. up_mbps/down_mbps намеренно не заданы, но одного
#    этого мало: без ignore_client_bandwidth сервер включает Brutal на скорость, которую
#    назвал клиент (sing-quic, service.go). С ним при пустых лимитах оба конца идут на BBR.
#    Brutal игнорирует сигналы перегрузки, поэтому нужен именно BBR.
#  - masquerade: если есть decoy-сайт, на не-hy2 запрос по HTTP/3 (зонд) отвечает он, а не 404.
#  - hy2_obfs в meta.json (salamander | gecko | off): обфускация QUIC. Новая установка
#    ставит salamander: у части людей UDP фильтруют, и голый QUIC с SNI режут первым.
#    Пароль обфускации (hy2_obfs_pass) выпускается сам. Сервер, поставленный раньше без
#    obfs (ключа в meta.json нет), так и остаётся без него — его ссылки не меняются.
#    gecko только после проверки на живом клиенте: 04.11 у владельца с gecko клиент
#    (Sovereign, sing-box 1.14.4) не соединялся, с salamander заработало сразу; mihomo и
#    официальный Hysteria2 gecko не понимают.
#  - hy2_bbr в meta.json (conservative | standard | aggressive): профиль BBR, по умолчанию standard.
_hy2_extras() {
  local ob bb pass=""
  ob=$(pl_meta_get hy2_obfs); bb=$(pl_meta_get hy2_bbr)
  case "$ob" in
    ''|off) ob="" ;;
    salamander|gecko) ;;
    *) ui_warn "hy2_obfs=$ob не понятен (salamander, gecko или off) — обфускация выключена" >&2; ob="" ;;
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
  if _hy2_self; then _hy2_self_cert || return 1; fi
  pl_meta_has hy2_obfs || pl_meta_set hy2_obfs salamander
  local users extras inb; users=$(pl_inbound_users) || return 1
  extras=$(_hy2_extras) || return 1
  inb=$(cat <<JSON
{ "type":"hysteria2","tag":"${MOD_ID}-in","listen":"::","listen_port":${MOD_PORT},
  "users":${users},
  "tls":{"enabled":true,"server_name":"$(_hy2_sni)","alpn":["h3"],
    "certificate_path":"$(_hy2_crt)","key_path":"$(_hy2_key)"} }
JSON
)
  inb=$(python3 -c 'import json,sys;a=json.loads(sys.argv[1]);a.update(json.loads(sys.argv[2]));print(json.dumps(a))' "$inb" "$extras") || return 1
  pl_singbox_add_inbound "$inb" || return 1
  pl_ufw_sync_module
  pl_meta_set "${MOD_ID}_port" "$MOD_PORT"
  _hy2_hop_on "$MOD_PORT"
  pl_singbox_apply && pl_sub_reload
}

# packetlab reconfig hy2 [obfs=salamander|gecko|off] [port=N] [bbr=conservative|standard|aggressive] [hop=on|off]
# Применяет настройки к уже стоящему инбаунду (и к decoy-сайту, если он появился после
# установки). Пользователи и их пароли не трогаются; sing-box перезапускается, только если
# конфиг изменился. Смена obfs, порта или перескока меняет ссылки клиентов.
# 443/udp haproxy не занимает (он держит только 443/tcp), так что порт 443 для hy2 свободен.
mod_reconfig() {
  pl_singbox_has_tag "${MOD_ID}-in" || { ui_err "Hysteria2 не установлен"; return 1; }
  local a oldport="$MOD_PORT" newport="$MOD_PORT" hop=""
  for a in "$@"; do
    case "$a" in
      obfs=*) case "${a#obfs=}" in
                salamander|off) ;;
                gecko) ui_warn "gecko понимает только sing-box ≥ 1.14, и у Sovereign он не соединялся — проверь на клиенте" ;;
                *) ui_err "obfs: salamander, gecko или off"; return 1 ;;
              esac
              pl_meta_set hy2_obfs "${a#obfs=}" ;;
      bbr=*)  pl_meta_set hy2_bbr "${a#bbr=}" ;;
      hop=on|hop=off) hop="${a#hop=}" ;;
      port=*) newport="${a#port=}"
              case "$newport" in ''|*[!0-9]*) ui_err "порт должен быть числом"; return 1 ;; esac
              [ "$newport" -ge 1 ] && [ "$newport" -le 65535 ] || { ui_err "порт вне 1-65535"; return 1; } ;;
      *) ui_err "не понял «$a» (obfs=, bbr=, port=, hop=)"; return 1 ;;
    esac
  done
  if [ "$newport" != "$oldport" ] && pl_port_listening "$newport" udp; then
    ui_err "порт $newport/udp уже занят"; return 1
  fi
  # Перескок идёт за портом: при смене порта таблица переписывается.
  if [ "$hop" = off ]; then
    _hy2_hop_off
  elif [ "$hop" = on ] || { pl_meta_has hy2_hop && [ "$newport" != "$oldport" ]; }; then
    _hy2_hop_on "$newport"
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
  _hy2_hop_off
  # Ключи пользователей уходят вместе с модулем — старый пин больше никому не нужен.
  rm -f "$HY2_SELF_CRT" "$HY2_SELF_KEY"
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_port" "${MOD_ID}_obfs_pass" "${MOD_ID}_obfs"
  pl_singbox_apply && pl_sub_reload
}

# Пароль на проводе — только password. Имя пользователя в ссылку НЕ входит:
# sing-box сравнивает ровно пароль (у каждого пользователя он свой), а
# "user:pass" даст ошибку аутентификации.
mod_link() {  # mod_link <формат> [пользователь]
  local name="Hysteria2" u p ob op port sni hop lo hi tls pin fpr
  u=$(pl_link_user "${2:-}"); p=$(pl_cred "$u" "$MOD_ID" pass) || return 1
  ob=$(pl_meta_get hy2_obfs); op=$(pl_meta_get hy2_obfs_pass)
  case "$ob" in salamander|gecko) [ -n "$op" ] || ob="" ;; *) ob="" ;; esac
  port=$(pl_meta_get ${MOD_ID}_port); sni=$(_hy2_sni)
  hop=$(pl_meta_get hy2_hop); lo=${hop%-*}; hi=${hop#*-}
  if _hy2_self; then
    pin=$(_hy2_pin); fpr=$(_hy2_fpr)
    [ -n "$pin" ] || { ui_err "нет сертификата $HY2_SELF_CRT — переустанови Hysteria2" >&2; return 1; }
    tls=$(printf '{"enabled":true,"server_name":"%s","alpn":["h3"],"certificate_public_key_sha256":["%s"]}' "$sni" "$pin")
  else
    tls=$(printf '{"enabled":true,"server_name":"%s","alpn":["h3"]}' "$sni")
  fi
  local obj; obj=$([ -n "$ob" ] && printf ',"obfs":{"type":"%s","password":"%s"}' "$ob" "$op")
  case "$1" in
    clash)
      if [ "$ob" = gecko ]; then ui_warn "mihomo не знает обфускацию gecko — в Clash этот протокол не уезжает" >&2; return 0; fi
      # Строки по одной: $(…) срезает перевод строки, и необязательные поля слиплись бы.
      printf -- '- name: %s\n  type: hysteria2\n  server: %s\n  port: %s\n' "$name" "$PL_HOST" "$port"
      [ -n "$hop" ] && printf '  ports: %s-%s\n' "$lo" "$hi"
      printf '  password: %s\n  sni: %s\n  alpn: [h3]\n' "$p" "$sni"
      if _hy2_self; then
        printf '  skip-cert-verify: true\n  fingerprint: %s\n' "$(printf '%s' "$fpr" | tr -d ':' | tr 'A-F' 'a-f')"
      else
        printf '  skip-cert-verify: false\n'
      fi
      [ -n "$ob" ] && printf '  obfs: salamander\n  obfs-password: %s\n' "$op"
    ;;
    singbox)
      printf '{ "type":"hysteria2","tag":"%s","server":"%s","server_port":%s,\n  "password":"%s"%s,\n  "tls":%s }\n' \
        "$name" "$PL_HOST" "$port" "$p" "$obj" "$tls"
      if [ -n "$hop" ]; then
        printf '{ "type":"hysteria2","tag":"%s · порты %s-%s","server":"%s","server_ports":["%s:%s"],\n  "hop_interval":"20s","password":"%s"%s,\n  "tls":%s }\n' \
          "$name" "$lo" "$hi" "$PL_HOST" "$lo" "$hi" "$p" "$obj" "$tls"
      fi
    ;;
    uri)
      # Официальный клиент и большинство остальных: с самоподписанным сертификатом
      # проверка цепочки выключена (insecure=1), а сертификат сверяется по pinSHA256.
      local q; q="sni=${sni}&alpn=h3"
      if _hy2_self; then q="${q}&insecure=1&pinSHA256=$(pl_urlenc "$fpr")"; else q="${q}&insecure=0"; fi
      [ -n "$ob" ] && q="${q}&obfs=${ob}&obfs-password=$(pl_urlenc "$op")"
      [ -n "$hop" ] && q="${q}&mport=${lo}-${hi}"
      printf 'hysteria2://%s@%s:%s?%s#%s\n' "$(pl_urlenc "$p")" "$PL_HOST" "$port" "$q" "$name" ;;
  esac
}
