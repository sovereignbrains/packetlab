#!/usr/bin/env bash
MOD_ID=anytls
MOD_NAME="AnyTLS"
MOD_DESC="TLS с адаптивным паддингом"
MOD_ENGINE=sing-box
MOD_PORT=8445
MOD_PROTO=tcp
MOD_SNI_LABEL=api
MOD_VIA_HAPROXY=yes
MOD_LEVEL=simple
MOD_USERS='{"name":"%name%","password":"%pass%"}'

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows 443 tcp || { printf blocked; return; }
  pl_haproxy_has_backend "$MOD_ID" || { printf broken; return; }
  pl_meta_has anytls_sni || { printf broken; return; }
  printf up
}

mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }
  local users sni="${MOD_SNI_LABEL}.${PL_DOMAIN}"
  pl_dns_ensure "$MOD_SNI_LABEL" || return 1
  users=$(pl_inbound_users) || return 1
  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"anytls","tag":"${MOD_ID}-in","listen":"127.0.0.1","listen_port":${MOD_PORT},
  "users":${users},
  "tls":{"enabled":true,"server_name":"${sni}",
    "certificate_path":"${PL_CERT}","key_path":"${PL_KEY}"} }
JSON
)" || return 1
  pl_haproxy_add_sni "$sni" "$MOD_ID" "$MOD_PORT" || return 1
  pl_ufw_sync_module
  pl_meta_set "${MOD_ID}_sni"  "$sni"
  pl_singbox_apply && pl_sub_reload
}

mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_haproxy_del_sni "$MOD_ID"
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_sni"
  pl_singbox_apply && pl_sub_reload
}

mod_link() {  # mod_link <формат> [пользователь]
  local name="AnyTLS" u pass
  u=$(pl_link_user "${2:-}"); pass=$(pl_cred "$u" "$MOD_ID" pass) || return 1
  case "$1" in
    clash) cat <<YAML
- name: ${name}
  type: anytls
  server: ${PL_DOMAIN}
  port: 443
  password: ${pass}
  sni: $(pl_meta_get ${MOD_ID}_sni)
  udp: true
YAML
    ;;
    singbox) cat <<JSON
{ "type":"anytls","tag":"${name}","server":"${PL_DOMAIN}","server_port":443,
  "password":"${pass}",
  "tls":{"enabled":true,"server_name":"$(pl_meta_get ${MOD_ID}_sni)"} }
JSON
    ;;
    uri) printf 'anytls://%s@%s:443?sni=%s&insecure=0#%s\n' \
      "$(pl_urlenc "$pass")" "$PL_DOMAIN" "$(pl_meta_get ${MOD_ID}_sni)" "$name" ;;
  esac
}
