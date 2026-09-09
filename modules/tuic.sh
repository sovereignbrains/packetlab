#!/usr/bin/env bash
# Модуль протокола — образец контракта.
#
# Каждый модуль объявляет метаданные и четыре функции. Диспетчер ничего не
# знает о протоколах: он только перечисляет модули и дёргает эти функции.
#
# Ключевой принцип: правило UFW создаётся и удаляется ВМЕСТЕ с инбаундом.
# Рассинхрон конфига и firewall — источник самого дорогого бага в проекте
# (TUIC переехал с 9444 на 443, правило осталось на старом порту, протокол
# молча умер: таймаут на клиенте и ноль записей в логах сервера).

MOD_ID=tuic
MOD_NAME="TUIC"
MOD_DESC="QUIC поверх UDP, BBR"
MOD_ENGINE=sing-box
MOD_PORT=443
MOD_PROTO=udp
MOD_NEEDS_SNI=yes          # требует поддомен в DNS
MOD_SNI_LABEL=cdn          # cdn.<домен>

# ---------------------------------------------------------------- status ---
# Сверяет ТРИ источника, а не один. Расхождение между ними — и есть баг.
#   1. есть ли инбаунд в конфиге
#   2. слушает ли порт на самом деле
#   3. открыт ли порт в UFW
mod_status() {
  local in_cfg=no listening=no fw=no

  pl_singbox_has_tag "${MOD_ID}-in" && in_cfg=yes
  pl_port_listening "$MOD_PORT" "$MOD_PROTO" && listening=yes
  pl_ufw_allows "$MOD_PORT" "$MOD_PROTO" && fw=yes

  if [ "$in_cfg" = no ]; then
    printf 'off'
  elif [ "$listening" = no ]; then
    printf 'down'
  elif [ "$fw" = no ]; then
    printf 'blocked'
  else
    printf 'up'
  fi
}

# --------------------------------------------------------------- install ---
mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }

  local uuid pass
  uuid=$(pl_uuid)
  pass=$(pl_secret)

  pl_dns_ensure "$MOD_SNI_LABEL" || return 1

  pl_singbox_add_inbound "$(cat <<JSON
{
  "type": "tuic",
  "tag": "${MOD_ID}-in",
  "listen": "::",
  "listen_port": ${MOD_PORT},
  "congestion_control": "bbr",
  "users": [{ "name": "${PL_USER}", "uuid": "${uuid}", "password": "${pass}" }],
  "tls": {
    "enabled": true,
    "server_name": "${MOD_SNI_LABEL}.${PL_DOMAIN}",
    "alpn": ["h3"],
    "certificate_path": "${PL_CERT}",
    "key_path": "${PL_KEY}"
  }
}
JSON
)" || return 1

  # firewall — неотделимая часть установки, не отдельный шаг
  pl_ufw_open "$MOD_PORT" "$MOD_PROTO" "$MOD_ID" || return 1

  pl_meta_set "${MOD_ID}_uuid" "$uuid"
  pl_meta_set "${MOD_ID}_pass" "$pass"
  pl_meta_set "${MOD_ID}_port" "$MOD_PORT"
  pl_meta_set "${MOD_ID}_sni"  "${MOD_SNI_LABEL}.${PL_DOMAIN}"

  pl_singbox_apply || return 1
  pl_sub_reload
}

# ---------------------------------------------------------------- remove ---
mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_ufw_close "$MOD_PORT" "$MOD_PROTO"
  pl_meta_del "${MOD_ID}_uuid" "${MOD_ID}_pass" "${MOD_ID}_port" "${MOD_ID}_sni"
  pl_singbox_apply || return 1
  pl_sub_reload
}

# ------------------------------------------------------------------ link ---
# Нода для подписки. Формат просит диспетчер: clash | singbox | uri
mod_link() {
  local fmt="$1" name="TUIC"
  case "$fmt" in
    clash)
      cat <<YAML
- name: ${name}
  type: tuic
  server: ${PL_DOMAIN}
  port: $(pl_meta_get "${MOD_ID}_port")
  uuid: $(pl_meta_get "${MOD_ID}_uuid")
  password: $(pl_meta_get "${MOD_ID}_pass")
  sni: $(pl_meta_get "${MOD_ID}_sni")
  alpn: [h3]
  congestion-controller: bbr
  udp-relay-mode: native
YAML
      ;;
    singbox)
      cat <<JSON
{
  "type": "tuic", "tag": "${name}",
  "server": "${PL_DOMAIN}", "server_port": $(pl_meta_get "${MOD_ID}_port"),
  "uuid": "$(pl_meta_get "${MOD_ID}_uuid")",
  "password": "$(pl_meta_get "${MOD_ID}_pass")",
  "congestion_control": "bbr",
  "tls": { "enabled": true, "server_name": "$(pl_meta_get "${MOD_ID}_sni")", "alpn": ["h3"] }
}
JSON
      ;;
    uri)
      printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr#%s\n' \
        "$(pl_meta_get "${MOD_ID}_uuid")" "$(pl_urlenc "$(pl_meta_get "${MOD_ID}_pass")")" \
        "$PL_DOMAIN" "$(pl_meta_get "${MOD_ID}_port")" \
        "$(pl_meta_get "${MOD_ID}_sni")" "$name"
      ;;
  esac
}
