#!/usr/bin/env bash
MOD_ID=reality
MOD_NAME="REALITY"
MOD_DESC="VLESS + xtls-rprx-vision, маскировка под чужой TLS"
MOD_ENGINE=sing-box
MOD_PORT=8443
MOD_PROTO=tcp
MOD_VIA_HAPROXY=yes

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows 443 tcp || { printf blocked; return; }
  pl_haproxy_has_backend "$MOD_ID" || { printf broken; return; }
  pl_meta_has reality_uuid || { printf broken; return; }
  printf up
}

mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }
  local uuid target kp priv pub sid
  uuid=$(pl_uuid)
  target=$(pl_meta_get reality_target); [ -z "$target" ] && target=www.bing.com
  kp=$(sing-box generate reality-keypair)
  priv=$(printf '%s\n' "$kp" | awk '/PrivateKey/{print $2}')
  pub=$(printf '%s\n' "$kp"  | awk '/PublicKey/{print $2}')
  sid=$(pl_hex 8)

  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"vless","tag":"${MOD_ID}-in","listen":"127.0.0.1","listen_port":${MOD_PORT},
  "users":[{"name":"${PL_USER}","uuid":"${uuid}","flow":"xtls-rprx-vision"}],
  "tls":{"enabled":true,"server_name":"${target}","reality":{"enabled":true,
    "handshake":{"server":"${target}","server_port":443},
    "private_key":"${priv}","short_id":["${sid}"]}} }
JSON
)" || return 1

  pl_haproxy_add_sni "$target" "$MOD_ID" "$MOD_PORT" || return 1
  pl_ufw_open 443 tcp "$MOD_ID"
  pl_meta_set "${MOD_ID}_uuid" "$uuid"
  pl_meta_set "${MOD_ID}_pbk" "$pub"
  pl_meta_set "${MOD_ID}_sid" "$sid"
  pl_meta_set "${MOD_ID}_sni" "$target"
  pl_singbox_apply && pl_sub_reload
}

mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_haproxy_del_sni "$MOD_ID"
  pl_meta_del "${MOD_ID}_uuid" "${MOD_ID}_pbk" "${MOD_ID}_sid" "${MOD_ID}_sni"
  pl_singbox_apply && pl_sub_reload
}

mod_link() {
  local name="REALITY"
  case "$1" in
    clash) cat <<YAML
- name: ${name}
  type: vless
  server: ${PL_DOMAIN}
  port: 443
  uuid: $(pl_meta_get ${MOD_ID}_uuid)
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: $(pl_meta_get ${MOD_ID}_sni)
  client-fingerprint: chrome
  reality-opts:
    public-key: $(pl_meta_get ${MOD_ID}_pbk)
    short-id: $(pl_meta_get ${MOD_ID}_sid)
YAML
    ;;
    singbox) cat <<JSON
{ "type":"vless","tag":"${name}","server":"${PL_DOMAIN}","server_port":443,
  "uuid":"$(pl_meta_get ${MOD_ID}_uuid)","flow":"xtls-rprx-vision",
  "tls":{"enabled":true,"server_name":"$(pl_meta_get ${MOD_ID}_sni)","utls":{"enabled":true,"fingerprint":"chrome"},
    "reality":{"enabled":true,"public_key":"$(pl_meta_get ${MOD_ID}_pbk)","short_id":"$(pl_meta_get ${MOD_ID}_sid)"}} }
JSON
    ;;
    uri) printf 'vless://%s@%s:443?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&type=tcp#%s\n' \
      "$(pl_meta_get ${MOD_ID}_uuid)" "$PL_DOMAIN" "$(pl_meta_get ${MOD_ID}_sni)" \
      "$(pl_meta_get ${MOD_ID}_pbk)" "$(pl_meta_get ${MOD_ID}_sid)" "$name" ;;
  esac
}
