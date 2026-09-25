#!/usr/bin/env bash
# Mieru — инбаунд sing-box. Протокол есть в сборке mbox (github.com/enfein/mbox):
# апстримный sing-box плюс один коммит protocol/mieru от автора Mieru.
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
MOD_USERS='{"name":"%name%","password":"%pass%"}'   # логин Mieru — имя пользователя packetlab

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows "$MOD_PORT" tcp || { printf blocked; return; }
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
  local users; users=$(pl_inbound_users) || return 1

  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"mieru","tag":"${MOD_ID}-in","listen":"::","listen_port":${MOD_PORT},
  "transport":"TCP","users":${users} }
JSON
)" || return 1

  pl_ufw_sync_module
  pl_meta_set "${MOD_ID}_port" "$MOD_PORT"
  pl_singbox_apply && pl_sub_reload
}

mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_ufw_close "$MOD_PORT" tcp
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_port"
  pl_singbox_apply && pl_sub_reload
}

mod_link() {  # mod_link <формат> [пользователь]
  local name="Mieru" u pass port
  u=$(pl_link_user "${2:-}"); pass=$(pl_cred "$u" "$MOD_ID" pass) || return 1
  port=$(pl_meta_get ${MOD_ID}_port); [ -n "$port" ] || port=$MOD_PORT
  case "$1" in
    clash) cat <<YAML
- name: ${name}
  type: mieru
  server: ${PL_HOST}
  port: ${port}
  transport: TCP
  username: ${u}
  password: ${pass}
YAML
    ;;
    singbox) cat <<JSON
{ "type":"mieru","tag":"${name}","server":"${PL_HOST}","server_port":${port},
  "transport":"TCP","username":"${u}","password":"${pass}",
  "multiplexing":"MULTIPLEXING_HIGH" }
JSON
    ;;
    # Простая ссылка Mieru (docs/client-install.md, разбор — URLToClientProfile):
    # имя и пароль открытым текстом в userinfo, порт — не через «:», а парой
    # параметров port/protocol, profile обязателен. Раньше тут был формат
    # «как у ss://» (base64 и host:port) — клиенты отвечали «invalid port».
    # #имя парсер Mieru игнорирует, а клиенты берут из него название.
    uri) printf 'mierus://%s:%s@%s?multiplexing=MULTIPLEXING_HIGH&port=%s&profile=%s&protocol=TCP#%s\n' \
      "$(pl_urlenc "$u")" "$(pl_urlenc "$pass")" "$PL_HOST" "$port" "$name" "$name" ;;
  esac
}
