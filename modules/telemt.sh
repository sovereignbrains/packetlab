#!/usr/bin/env bash
# Telegram MTProxy на Rust (telemt, github.com/telemt/telemt): FakeTLS «ee»-ссылки,
# соединения без своего секрета уходят на настоящий сайт-маску. Не инбаунд
# sing-box — отдельный бинарник и systemd-служба, поэтому sing-box при установке,
# смене пользователей и удалении не перезапускается.
MOD_ID=telemt
MOD_NAME="Telegram MTProxy"
MOD_DESC="прокси для Telegram: MTProto с FakeTLS под чужой сайт"
MOD_ENGINE=telemt
MOD_PORT=8450
MOD_PROTO=tcp
MOD_VIA_HAPROXY=yes
MOD_LEVEL=simple
MOD_NEEDS_DOMAIN=no      # ни сертификата, ни домена: секрет несёт в себе имя сайта-маски
# Ключ пользователя — 32 hex (%hex%). users sync ищет инбаунд telemt-in, не находит и
# ничего не делает; пользователей в конфиг telemt пишет mod_users_sync.
MOD_USERS='{"name":"%name%","secret":"%hex%"}'

TEL_BIN=/usr/local/bin/telemt
TEL_ETC=/etc/telemt
TEL_CONF=/etc/telemt/telemt.toml
TEL_VAR=/var/lib/telemt
TEL_UNIT=/etc/systemd/system/telemt.service
TEL_SNI_DEFAULT=www.apple.com   # TLS 1.3 + h2, не занят другими модулями

mod_can_install() {
  case "$(uname -m)" in x86_64|aarch64) ;; *) return 1 ;; esac
  command -v curl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1
}

mod_status() {
  [ -x "$TEL_BIN" ] && [ -f "$TEL_CONF" ] || { printf off; return; }
  systemctl is-active --quiet telemt || { printf down; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows 443 tcp || { printf blocked; return; }
  pl_haproxy_has_backend "$MOD_ID" || { printf broken; return; }
  pl_meta_has telemt_sni || { printf broken; return; }
  printf up
}

# telemt.toml на stdout. Пользователи — по одному на каждого из packetlab.
_telemt_render() {
  local sni users
  sni=$(pl_meta_get telemt_sni); [ -n "$sni" ] || sni=$TEL_SNI_DEFAULT
  users=$(pl_inbound_users) || return 1
  TEL_USERS="$users" TEL_SNI="$sni" TEL_PORT="$MOD_PORT" TEL_HOST="$PL_HOST" TEL_VAR="$TEL_VAR" python3 - <<'PY'
import json, os
e = os.environ
print(f'''# Сгенерировано packetlab: правки перетрутся при смене пользователей.
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

# Ссылки в журнал не печатаем: в них секреты.
[general.links]
show = []
public_host = "{e["TEL_HOST"]}"
public_port = 443

[server]
port = {e["TEL_PORT"]}

[server.api]
enabled = false

[[server.listeners]]
ip = "127.0.0.1"

[censorship]
tls_domain = "{e["TEL_SNI"]}"
mask = true
tls_emulation = true
tls_front_dir = "{e["TEL_VAR"]}/tlsfront"

[access.users]''')
for u in json.loads(e["TEL_USERS"]):
    print(f'"{u["name"]}" = "{u["secret"]}"')
PY
}

# Пишет конфиг, если он изменился. Список пользователей telemt перечитывает сам
# (проверено: добавление и удаление без рестарта и без обрыва остальных).
_telemt_write_conf() {
  local tmp
  tmp=$(mktemp "$TEL_ETC/.telemt.toml.XXXXXX") || return 1
  _telemt_render > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$TEL_CONF" ] && cmp -s "$tmp" "$TEL_CONF"; then rm -f "$tmp"; return 0; fi
  chown root:telemt "$tmp"; chmod 640 "$tmp"
  mv -f "$tmp" "$TEL_CONF"
}

# Зовётся из pl_users_apply после добавления/удаления/смены ключей пользователей.
mod_users_sync() {
  [ -f "$TEL_CONF" ] || return 0
  _telemt_write_conf
}

mod_install() {
  [ -f "$TEL_CONF" ] && { ui_err "telemt уже настроен — сначала удалить"; return 1; }
  local sni arch libc asset base tmp ver i
  sni=$(pl_meta_get telemt_sni); [ -n "$sni" ] || sni=$TEL_SNI_DEFAULT
  if grep -qE "req\.ssl_sni -i ${sni//./\\.}[[:space:]]" "$PL_HAP" 2>/dev/null; then
    ui_err "SNI $sni в haproxy уже занят другим протоколом"; return 1
  fi

  case "$(uname -m)" in x86_64) arch=x86_64 ;; aarch64) arch=aarch64 ;; *) ui_err "архитектура не поддерживается"; return 1 ;; esac
  ldd --version 2>&1 | grep -qi musl && libc=musl || libc=gnu
  asset="telemt-${arch}-linux-${libc}.tar.gz"
  base="https://github.com/telemt/telemt/releases/latest/download"

  tmp=$(mktemp -d) || return 1
  ui_note "качаю $asset"
  if ! { curl -fsSL --max-time 180 -o "$tmp/$asset" "$base/$asset" \
         && curl -fsSL --max-time 30 -o "$tmp/$asset.sha256" "$base/$asset.sha256"; }; then
    ui_err "не скачалось с github.com/telemt/telemt"; rm -rf "$tmp"; return 1
  fi
  (cd "$tmp" && sha256sum -c "$asset.sha256" >/dev/null 2>&1) \
    || { ui_err "контрольная сумма не сошлась — не ставлю"; rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/$asset" -C "$tmp" telemt 2>/dev/null && "$tmp/telemt" --help >/dev/null 2>&1 \
    || { ui_err "в архиве нет рабочего telemt"; rm -rf "$tmp"; return 1; }
  ver=$(curl -fsSI --max-time 15 -o /dev/null -w '%{redirect_url}' https://github.com/telemt/telemt/releases/latest 2>/dev/null | sed 's#.*/##')
  install -m 755 "$tmp/telemt" "$TEL_BIN"; rm -rf "$tmp"

  id telemt >/dev/null 2>&1 || useradd -r -M -d "$TEL_VAR" -s /usr/sbin/nologin -U telemt
  install -d -o telemt -g telemt -m 750 "$TEL_VAR"
  install -d -o root -g telemt -m 750 "$TEL_ETC"
  pl_meta_set telemt_sni "$sni"
  _telemt_write_conf || { ui_err "не смог собрать конфиг telemt"; return 1; }

  cat > "$TEL_UNIT" <<UNIT
[Unit]
Description=telemt — Telegram MTProxy
After=network-online.target
Wants=network-online.target

[Service]
User=telemt
Group=telemt
WorkingDirectory=${TEL_VAR}
ExecStart=${TEL_BIN} --data-path ${TEL_VAR} ${TEL_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
# telemt печатает tg://-ссылку с секретом при добавлении пользователя, show=[] этого не гасит
LogFilterPatterns=~telemt::links
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${TEL_VAR}

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now telemt >/dev/null 2>&1

  # Первый старт ходит за конфигурацией Telegram и слушает порт не сразу.
  for i in $(seq 1 60); do pl_port_listening "$MOD_PORT" tcp && break; sleep 0.5; done
  if ! pl_port_listening "$MOD_PORT" tcp; then
    ui_err "telemt не поднялся"; ui_note "journalctl -u telemt -n 20 --no-pager"
    return 1
  fi

  pl_haproxy_add_sni "$sni" "$MOD_ID" "$MOD_PORT" || return 1
  pl_ufw_sync_module
  [ -n "$ver" ] && pl_meta_set telemt_ver "$ver"
  return 0
}

mod_remove() {
  pl_haproxy_del_sni "$MOD_ID" || return 1
  systemctl disable --now telemt >/dev/null 2>&1
  rm -f "$TEL_UNIT"; systemctl daemon-reload
  rm -rf "$TEL_ETC" "$TEL_VAR"; rm -f "$TEL_BIN"
  id telemt >/dev/null 2>&1 && userdel telemt >/dev/null 2>&1
  pl_meta_del telemt_sni telemt_ver
  return 0
}

# Только tg://: в подписку sing-box этот протокол не попадает (clash/singbox — пусто).
mod_link() {  # mod_link <формат> [пользователь]
  [ "$1" = uri ] || return 0
  local u hex sni
  u=$(pl_link_user "${2:-}"); hex=$(pl_cred "$u" "$MOD_ID" hex) || return 1
  sni=$(pl_meta_get telemt_sni)
  printf 'tg://proxy?server=%s&port=443&secret=ee%s%s\n' "$PL_HOST" "$hex" \
    "$(printf '%s' "$sni" | od -An -tx1 | tr -d ' \n')"
}
