#!/usr/bin/env bash
MOD_ID=shadowtls
MOD_NAME="ShadowTLS v3"
MOD_DESC="Настоящее рукопожатие чужого сайта, внутри shadowsocks-2022; домен не нужен"
MOD_ENGINE=sing-box
MOD_PORT=8449
MOD_PROTO=tcp
MOD_VIA_HAPROXY=yes
MOD_LEVEL=advanced
MOD_NEEDS_DOMAIN=no      # рукопожатие идёт к чужому сайту, своего сертификата нет
# Пароль ShadowTLS — у каждого пользователя свой: по нему сервер решает, пускать ли
# в shadowsocks или отдать соединение настоящему сайту. Ключ самого shadowsocks
# (внутренний инбаунд ${MOD_ID}-ss) общий, в meta: ShadowTLS v3 не шифрует данные,
# это делает shadowsocks, а попасть к нему без пароля ShadowTLS нельзя.
MOD_USERS='{"name":"%name%","password":"%pass%"}'

SHT_METHOD=2022-blake3-aes-128-gcm

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_singbox_has_tag "${MOD_ID}-ss" || { printf broken; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows 443 tcp || { printf blocked; return; }
  pl_haproxy_has_backend "$MOD_ID" || { printf broken; return; }
  pl_meta_has "${MOD_ID}_ss" || { printf broken; return; }
  printf up
}

mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }
  local target psk users
  # Как у REALITY: SNI делит haproxy, поэтому сайт для рукопожатия не должен быть занят
  # другим протоколом. ShadowTLS v3 требует TLS 1.3 на этом сайте.
  target=$(pl_meta_get "${MOD_ID}_target"); [ -z "$target" ] && target=www.cloudflare.com
  if grep -q "req.ssl_sni -i ${target} " "$PL_HAP" 2>/dev/null; then
    ui_err "SNI $target в haproxy уже занят другим протоколом"
    ui_note "задай другой сайт ключом ${MOD_ID}_target в $PL_META"
    return 1
  fi
  pl_port_listening "$MOD_PORT" tcp && { ui_err "порт $MOD_PORT уже занят"; return 1; }
  timeout 8 openssl s_client -connect "${target}:443" -servername "$target" -tls1_3 </dev/null >/dev/null 2>&1 \
    || { ui_err "$target не отвечает по TLS 1.3 — ShadowTLS v3 с ним работать не будет"; return 1; }

  psk=$(pl_meta_get "${MOD_ID}_ss"); [ -z "$psk" ] && psk=$(sing-box generate rand 16 --base64)
  [ -n "$psk" ] || { ui_err "не смог выпустить ключ shadowsocks"; return 1; }
  users=$(pl_inbound_users) || return 1

  # Внутренний shadowsocks не слушает порт: к нему ведёт только detour из ShadowTLS.
  # Он добавляется первым — detour на несуществующий инбаунд конфиг не пройдёт.
  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"shadowsocks","tag":"${MOD_ID}-ss","method":"${SHT_METHOD}","password":"${psk}" }
JSON
)" || return 1

  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"shadowtls","tag":"${MOD_ID}-in","listen":"127.0.0.1","listen_port":${MOD_PORT},
  "version":3,"users":${users},
  "handshake":{"server":"${target}","server_port":443},
  "strict_mode":true,"detour":"${MOD_ID}-ss" }
JSON
)" || { pl_singbox_del_inbound "${MOD_ID}-ss"; return 1; }

  pl_haproxy_add_sni "$target" "$MOD_ID" "$MOD_PORT" || return 1
  pl_ufw_sync_module
  pl_meta_set "${MOD_ID}_ss"  "$psk"
  pl_meta_set "${MOD_ID}_sni" "$target"
  pl_singbox_apply && pl_sub_reload
}

mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_singbox_del_inbound "${MOD_ID}-ss" || return 1
  pl_haproxy_del_sni "$MOD_ID"
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_ss" "${MOD_ID}_sni"
  pl_singbox_apply && pl_sub_reload
}

# sing-box: два звена — shadowsocks (его выбирают в списке) и ShadowTLS под ним через
# detour. Сервер подписок понимает массив: первый элемент — нода, остальные — вспомогательные.
mod_link() {  # mod_link <формат> [пользователь]
  local name="ShadowTLS" u pass psk sni
  u=$(pl_link_user "${2:-}"); pass=$(pl_cred "$u" "$MOD_ID" pass) || return 1
  psk=$(pl_meta_get "${MOD_ID}_ss"); sni=$(pl_meta_get "${MOD_ID}_sni")
  case "$1" in
    singbox) cat <<JSON
[
{ "type":"shadowsocks","tag":"${name}","server":"${PL_HOST}","server_port":443,
  "method":"${SHT_METHOD}","password":"${psk}","detour":"${name}-hop" },
{ "type":"shadowtls","tag":"${name}-hop","server":"${PL_HOST}","server_port":443,
  "version":3,"password":"${pass}",
  "tls":{"enabled":true,"server_name":"${sni}","utls":{"enabled":true,"fingerprint":"chrome"}} }
]
JSON
    ;;
    clash) cat <<YAML
- name: ${name}
  type: ss
  server: ${PL_HOST}
  port: 443
  cipher: ${SHT_METHOD}
  password: ${psk}
  plugin: shadow-tls
  client-fingerprint: chrome
  plugin-opts:
    host: ${sni}
    password: ${pass}
    version: 3
YAML
    ;;
    # Формат Shadowrocket/Stash: общего стандарта у ссылок ShadowTLS нет.
    uri) python3 - "$SHT_METHOD" "$psk" "$PL_HOST" "$sni" "$pass" "$name" <<'PY'
import base64, json, sys, urllib.parse
method, psk, host, sni, pw, name = sys.argv[1:]
b = lambda s: base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")
plugin = b(json.dumps({"version": "3", "host": sni, "password": pw}, separators=(",", ":")))
print(f"ss://{b(method + ':' + psk)}@{host}:443?shadow-tls={plugin}#{urllib.parse.quote(name)}")
PY
    ;;
  esac
}
