#!/usr/bin/env bash
MOD_ID=anytls-reality
MOD_NAME="AnyTLS + REALITY"
MOD_DESC="AnyTLS с маскировкой REALITY под чужой TLS, без своего сертификата"
MOD_ENGINE=sing-box
MOD_PORT=8448
MOD_PROTO=tcp
MOD_VIA_HAPROXY=yes
MOD_LEVEL=simple
MOD_NEEDS_DOMAIN=no      # REALITY живёт на чужом сертификате — домен не нужен
MOD_USERS='{"name":"%name%","password":"%pass%"}'

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows 443 tcp || { printf blocked; return; }
  pl_haproxy_has_backend "$MOD_ID" || { printf broken; return; }
  pl_meta_has "${MOD_ID}_pbk" || { printf broken; return; }
  printf up
}

mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }
  local target kp priv pub sid users
  # haproxy делит 443 по SNI, поэтому цель маскировки не может совпадать с чужой: REALITY-модуль
  # по умолчанию уже изображает www.bing.com.
  target=$(pl_meta_get "${MOD_ID}_target"); [ -z "$target" ] && target=www.microsoft.com
  if grep -q "req.ssl_sni -i ${target} " "$PL_HAP" 2>/dev/null; then
    ui_err "SNI $target в haproxy уже занят другим протоколом"
    ui_note "задай другой сайт ключом ${MOD_ID}_target в $PL_META"
    return 1
  fi
  timeout 8 openssl s_client -connect "${target}:443" -servername "$target" -tls1_3 </dev/null >/dev/null 2>&1 \
    || { ui_err "$target не отвечает по TLS 1.3 — REALITY с ним работать не будет"; return 1; }

  kp=$(sing-box generate reality-keypair)
  priv=$(printf '%s\n' "$kp" | awk '/PrivateKey/{print $2}')
  pub=$(printf '%s\n' "$kp"  | awk '/PublicKey/{print $2}')
  sid=$(pl_hex 8)
  users=$(pl_inbound_users) || return 1

  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"anytls","tag":"${MOD_ID}-in","listen":"127.0.0.1","listen_port":${MOD_PORT},
  "users":${users},
  "tls":{"enabled":true,"server_name":"${target}","reality":{"enabled":true,
    "handshake":{"server":"${target}","server_port":443},
    "private_key":"${priv}","short_id":["${sid}"]}} }
JSON
)" || return 1

  pl_haproxy_add_sni "$target" "$MOD_ID" "$MOD_PORT" || return 1
  pl_ufw_sync_module
  pl_meta_set "${MOD_ID}_pbk"  "$pub"
  pl_meta_set "${MOD_ID}_sid"  "$sid"
  pl_meta_set "${MOD_ID}_sni"  "$target"
  pl_singbox_apply && pl_sub_reload
}

mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_haproxy_del_sni "$MOD_ID"
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_pbk" "${MOD_ID}_sid" "${MOD_ID}_sni"
  pl_singbox_apply && pl_sub_reload
}

mod_link() {  # mod_link <формат> [пользователь]
  local name="AnyTLS-REALITY" u pass
  u=$(pl_link_user "${2:-}"); pass=$(pl_cred "$u" "$MOD_ID" pass) || return 1
  case "$1" in
    singbox) cat <<JSON
{ "type":"anytls","tag":"${name}","server":"${PL_HOST}","server_port":443,
  "password":"${pass}",
  "tls":{"enabled":true,"server_name":"$(pl_meta_get ${MOD_ID}_sni)","utls":{"enabled":true,"fingerprint":"chrome"},
    "reality":{"enabled":true,"public_key":"$(pl_meta_get ${MOD_ID}_pbk)","short_id":"$(pl_meta_get ${MOD_ID}_sid)"}} }
JSON
    ;;
    # Поля security=reality для anytls-ссылок общепринятыми не стали: часть клиентов их молча
    # пропускает и подключается без REALITY, то есть не подключается вовсе.
    uri) printf 'anytls://%s@%s:443?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s\n' \
      "$(pl_urlenc "$pass")" "$PL_HOST" "$(pl_meta_get ${MOD_ID}_sni)" \
      "$(pl_meta_get ${MOD_ID}_pbk)" "$(pl_meta_get ${MOD_ID}_sid)" "$name" ;;
    clash) ui_warn "mihomo не поддерживает REALITY для anytls — в Clash этот протокол не уезжает" ;;
  esac
}
