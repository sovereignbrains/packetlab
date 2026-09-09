#!/usr/bin/env bash
MOD_ID=naive
MOD_NAME="NaiveProxy"
MOD_DESC="HTTP/2 CONNECT с паддингом; в Clash-подписку не попадает"
MOD_ENGINE=sing-box
MOD_PORT=8446
MOD_PROTO=tcp
MOD_SNI_LABEL=cloud
MOD_VIA_HAPROXY=yes
# В Clash YAML типа naive нет — нода уезжает только в sing-box JSON и в URI.
MOD_NO_CLASH=yes

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows 443 tcp || { printf blocked; return; }
  printf up
}

mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }
  local pass sni="${MOD_SNI_LABEL}.${PL_DOMAIN}"
  pass=$(pl_secret)
  pl_dns_ensure "$MOD_SNI_LABEL" || return 1
  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"naive","tag":"${MOD_ID}-in","listen":"127.0.0.1","listen_port":${MOD_PORT},
  "network":"tcp",
  "users":[{"username":"${PL_USER}","password":"${pass}"}],
  "tls":{"enabled":true,"server_name":"${sni}",
    "certificate_path":"${PL_CERT}","key_path":"${PL_KEY}"} }
JSON
)" || return 1
  pl_haproxy_add_sni "$sni" "$MOD_ID" "$MOD_PORT" || return 1
  pl_ufw_open 443 tcp "$MOD_ID"
  pl_meta_set "${MOD_ID}_pass" "$pass"
  pl_meta_set "${MOD_ID}_sni"  "$sni"
  pl_singbox_apply && pl_sub_reload
}

mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_haproxy_del_sni "$MOD_ID"
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_sni"
  pl_singbox_apply && pl_sub_reload
}

mod_link() {
  local name="Naive"
  case "$1" in
    clash) : ;;   # mihomo не знает naive
    singbox) cat <<JSON
{ "type":"naive","tag":"${name}","server":"$(pl_meta_get ${MOD_ID}_sni)","server_port":443,
  "username":"${PL_USER}","password":"$(pl_meta_get ${MOD_ID}_pass)","quic":false,
  "tls":{"enabled":true,"server_name":"$(pl_meta_get ${MOD_ID}_sni)"} }
JSON
    ;;
    uri) printf 'naive+https://%s:%s@%s:443#%s\n' \
      "$PL_USER" "$(pl_urlenc "$(pl_meta_get ${MOD_ID}_pass)")" "$(pl_meta_get ${MOD_ID}_sni)" "$name" ;;
  esac
}
