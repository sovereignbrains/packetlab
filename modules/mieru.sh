#!/usr/bin/env bash
# Mieru обслуживает mita — родной сервер от автора протокола.
# mihomo на сервере стоит, но пустой: оставлен под будущие эксперименты.
MOD_ID=mieru
MOD_NAME="Mieru"
MOD_DESC="TCP, свой шифр; сервер mita"
MOD_ENGINE=mita
MOD_PORT=39000
MOD_PROTO=tcp
MOD_LEVEL=simple

mod_status() {
  command -v mita >/dev/null 2>&1 || { printf off; return; }
  mita describe config 2>/dev/null | grep -q "$MOD_PORT" || { printf off; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows "$MOD_PORT" tcp || { printf blocked; return; }
  pl_meta_has mieru_pass || { printf broken; return; }
  printf up
}

mod_install() {
  command -v mita >/dev/null 2>&1 || { ui_err "mita не установлен"; return 1; }
  local pass state=/var/lib/packetlab/mita-state.json
  pass=$(pl_meta_get "${MOD_ID}_pass"); [ -z "$pass" ] && pass=$(pl_secret)
  mkdir -p /var/lib/packetlab
  cat > "$state" <<JSON
{ "portBindings":[{"port":${MOD_PORT},"protocol":"TCP"}],
  "users":[{"name":"${PL_USER}","password":"${pass}"}],
  "loggingLevel":"INFO" }
JSON
  mita apply config "$state" >/dev/null 2>&1 || { ui_err "mita отверг конфиг"; return 1; }
  mita start >/dev/null 2>&1 || mita reload >/dev/null 2>&1
  pl_ufw_sync_module
  pl_meta_set "${MOD_ID}_pass" "$pass"
  pl_meta_set "${MOD_ID}_port" "$MOD_PORT"
  pl_sub_reload
}

mod_remove() {
  mita stop >/dev/null 2>&1 || true
  pl_ufw_close "$MOD_PORT" tcp
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_port"
  pl_sub_reload
}

mod_link() {
  local name="Mieru"
  case "$1" in
    clash) cat <<YAML
- name: ${name}
  type: mieru
  server: ${PL_DOMAIN}
  port: $(pl_meta_get ${MOD_ID}_port)
  transport: TCP
  username: ${PL_USER}
  password: $(pl_meta_get ${MOD_ID}_pass)
YAML
    ;;
    singbox) cat <<JSON
{ "type":"mieru","tag":"${name}","server":"${PL_DOMAIN}","server_port":$(pl_meta_get ${MOD_ID}_port),
  "transport":"TCP","username":"${PL_USER}","password":"$(pl_meta_get ${MOD_ID}_pass)",
  "multiplexing":"MULTIPLEXING_HIGH" }
JSON
    ;;
    uri) printf 'mierus://%s@%s:%s#%s\n' \
      "$(printf '%s:%s' "$PL_USER" "$(pl_meta_get ${MOD_ID}_pass)" | base64 -w0)" \
      "$PL_DOMAIN" "$(pl_meta_get ${MOD_ID}_port)" "$name" ;;
  esac
}
