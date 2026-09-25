#!/usr/bin/env bash
# Mieru — инбаунд sing-box. Протокол есть в сборке mbox (github.com/enfein/mbox):
# апстримный sing-box плюс один коммит с protocol/mieru от автора Mieru.
# Отдельный сервер mita больше не нужен — install.sh ставит mbox вместо sing-box.
MOD_ID=mieru
MOD_NAME="Mieru"
MOD_DESC="TCP, свой шифр; инбаунд sing-box (сборка mbox)"
MOD_ENGINE=sing-box
MOD_PORT=39000
MOD_PROTO=tcp
MOD_LEVEL=simple
MOD_NEEDS_DOMAIN=no      # свой шифр без TLS — сертификат не нужен
MOD_CLIENTS=extended     # официальный клиент sing-box mieru не знает — в строгую подписку не идёт

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows "$MOD_PORT" tcp || { printf blocked; return; }
  pl_meta_has "${MOD_ID}_pass" || { printf broken; return; }
  printf up
}

mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }
  # Официальный sing-box на инбаунд mieru отвечает «unknown inbound type» —
  # ловим до записи в конфиг и говорим, что делать.
  pl_singbox_has_mieru || {
    ui_err "этот sing-box не знает mieru — нужна сборка mbox"
    ui_note "перезапусти install.sh: он поставит mbox вместо официального sing-box"
    return 1
  }
  local pass
  pass=$(pl_meta_get "${MOD_ID}_pass"); [ -z "$pass" ] && pass=$(pl_secret)

  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"mieru","tag":"${MOD_ID}-in","listen":"::","listen_port":${MOD_PORT},
  "transport":"TCP","users":[{"name":"${PL_USER}","password":"${pass}"}] }
JSON
)" || return 1

  pl_ufw_sync_module
  pl_meta_set "${MOD_ID}_pass" "$pass"
  pl_meta_set "${MOD_ID}_port" "$MOD_PORT"
  pl_singbox_apply && pl_sub_reload
}

mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_ufw_close "$MOD_PORT" tcp
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_port"
  pl_singbox_apply && pl_sub_reload
}

mod_link() {
  local name="Mieru"
  case "$1" in
    clash) cat <<YAML
- name: ${name}
  type: mieru
  server: ${PL_HOST}
  port: $(pl_meta_get ${MOD_ID}_port)
  transport: TCP
  username: ${PL_USER}
  password: $(pl_meta_get ${MOD_ID}_pass)
YAML
    ;;
    singbox) cat <<JSON
{ "type":"mieru","tag":"${name}","server":"${PL_HOST}","server_port":$(pl_meta_get ${MOD_ID}_port),
  "transport":"TCP","username":"${PL_USER}","password":"$(pl_meta_get ${MOD_ID}_pass)",
  "multiplexing":"MULTIPLEXING_HIGH" }
JSON
    ;;
    uri) printf 'mierus://%s@%s:%s#%s\n' \
      "$(printf '%s:%s' "$PL_USER" "$(pl_meta_get ${MOD_ID}_pass)" | base64 -w0)" \
      "$PL_HOST" "$(pl_meta_get ${MOD_ID}_port)" "$name" ;;
  esac
}
