#!/usr/bin/env bash
MOD_ID=hy2
MOD_NAME="Hysteria2"
MOD_DESC="QUIC/UDP, BBR (без Brutal)"
MOD_ENGINE=sing-box
MOD_PORT=9445
MOD_PROTO=udp

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" udp || { printf down; return; }
  pl_ufw_allows "$MOD_PORT" udp || { printf blocked; return; }
  printf up
}

# up_mbps/down_mbps намеренно не задаются: с ними включается Brutal, который
# игнорирует сигналы перегрузки. По умолчанию работает BBR.
mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }
  local pass; pass=$(pl_secret)
  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"hysteria2","tag":"${MOD_ID}-in","listen":"::","listen_port":${MOD_PORT},
  "users":[{"name":"${PL_USER}","password":"${pass}"}],
  "tls":{"enabled":true,"server_name":"${PL_DOMAIN}","alpn":["h3"],
    "certificate_path":"${PL_CERT}","key_path":"${PL_KEY}"} }
JSON
)" || return 1
  pl_ufw_open "$MOD_PORT" udp "$MOD_ID"
  pl_meta_set "${MOD_ID}_pass" "$pass"
  pl_meta_set "${MOD_ID}_port" "$MOD_PORT"
  pl_singbox_apply && pl_sub_reload
}

mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_ufw_close "$MOD_PORT" udp
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_port"
  pl_singbox_apply && pl_sub_reload
}

# Пароль на проводе — только password. Имя пользователя в ссылку НЕ входит:
# sing-box сравнивает ровно пароль, а "user:pass" даст ошибку аутентификации.
mod_link() {
  local name="Hysteria2" p; p=$(pl_meta_get ${MOD_ID}_pass)
  case "$1" in
    clash) cat <<YAML
- name: ${name}
  type: hysteria2
  server: ${PL_DOMAIN}
  port: $(pl_meta_get ${MOD_ID}_port)
  password: ${p}
  sni: ${PL_DOMAIN}
  alpn: [h3]
  skip-cert-verify: false
YAML
    ;;
    singbox) cat <<JSON
{ "type":"hysteria2","tag":"${name}","server":"${PL_DOMAIN}","server_port":$(pl_meta_get ${MOD_ID}_port),
  "password":"${p}","tls":{"enabled":true,"server_name":"${PL_DOMAIN}","alpn":["h3"]} }
JSON
    ;;
    uri) printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=0#%s\n' \
      "$(pl_urlenc "$p")" "$PL_DOMAIN" "$(pl_meta_get ${MOD_ID}_port)" "$PL_DOMAIN" "$name" ;;
  esac
}
