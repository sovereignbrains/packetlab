#!/usr/bin/env bash
# Telegram MTProxy на Rust (telemt, github.com/telemt/telemt): FakeTLS «ee»-ссылки,
# соединения без своего секрета уходят на настоящий сайт-маску. С доменом сервера
# добавляется ещё WEB-прокси Telegram (tg://webproxy, HTTPS/WebSocket): TLS держит
# Caddy, telemt получает от него обычный HTTP на 127.0.0.1:18080. Не инбаунд
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

# WEB-режим. Путь /<base>/ у домена случайный: по нему Caddy отличает свой трафик от
# сайта-приманки. Носители: клиент сам выбирает из списка, а клиенту без согласования
# (iOS) достаётся единственный https.
TEL_CADDY=/etc/caddy/Caddyfile
TEL_WEB_PORT=18080
TEL_WEB_CARRIER=https
TEL_WEB_CARRIERS='"websocket-lanes", "websocket", "https-lanes"'
TEL_DECOY_SRC=/var/www/decoy
TEL_WEB_MARK='# packetlab:telemt-web'

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
  if _telemt_web_on; then
    pl_port_listening "$TEL_WEB_PORT" tcp && _telemt_caddy_has || { printf broken; return; }
  fi
  printf up
}

# telemt.toml на stdout. Пользователи — по одному на каждого из packetlab.
_telemt_render() {
  local sni users
  sni=$(pl_meta_get telemt_sni); [ -n "$sni" ] || sni=$TEL_SNI_DEFAULT
  users=$(pl_inbound_users) || return 1
  TEL_USERS="$users" TEL_SNI="$sni" TEL_PORT="$MOD_PORT" TEL_HOST="$PL_HOST" TEL_VAR="$TEL_VAR" \
  TEL_WEB_BASE="$(pl_meta_get telemt_web_base)" TEL_WEB_HOST="$PL_DOMAIN" TEL_WEB_IP="$(pl_meta_get ip)" \
  TEL_WEB_PORT="$TEL_WEB_PORT" TEL_WEB_CARRIER="$TEL_WEB_CARRIER" TEL_WEB_CARRIERS="$TEL_WEB_CARRIERS" \
  python3 - <<'PY'
import json, os
e = os.environ
web = bool(e["TEL_WEB_BASE"])
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
''' + (f'''
# WEB: обычный HTTP от Caddy, наружу не открыт. Caddy подставляет в X-Forwarded-For
# адрес, с которого пришёл к нему (за haproxy в режиме tcp это 127.0.0.1).
[[server.listeners]]
ip = "127.0.0.1"
port = {e["TEL_WEB_PORT"]}
transport = "web"
proxy_protocol = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]
''' if web else '') + f'''
[censorship]
tls_domain = "{e["TEL_SNI"]}"
mask = true
tls_emulation = true
tls_front_dir = "{e["TEL_VAR"]}/tlsfront"

[access.users]''')
users = json.loads(e["TEL_USERS"])
for u in users:
    print(f'"{u["name"]}" = "{u["secret"]}"')
if web:
    print(f'''
[web]
enabled = true
carrier = "{e["TEL_WEB_CARRIER"]}"
carriers = [{e["TEL_WEB_CARRIERS"]}]
decoy_fasttrack_mode = "off"
http_connection_capacity_action = "drop"

[[web.vhosts]]
host = "{e["TEL_WEB_HOST"]}"
base_path = "{e["TEL_WEB_BASE"]}"
public_addr = "{e["TEL_WEB_IP"]}:443"

[web.vhosts.decoy]
mode = "static_directory"
directory = "{e["TEL_VAR"]}/decoy"
index = "index.html"''')
    for u in users:
        print(f'''
[[web.vhosts.profiles]]
user = "{u["name"]}"
secret_mode = "dd"
max_sessions = 8
max_streams = 512
max_streams_per_session = 64''')
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

# ----------------------------------------------------------------- WEB -----
# WEB-прокси нужен домен с сертификатом и Caddy-блок :8080 от install.sh — без них
# остаётся один обычный MTProxy.
_telemt_web_possible() {
  [ -n "$PL_DOMAIN" ] && [ -f "$TEL_CADDY" ] && grep -q '^:8080 {' "$TEL_CADDY" \
    && [ -f "$TEL_DECOY_SRC/index.html" ] && command -v caddy >/dev/null 2>&1
}

_telemt_web_on() { pl_meta_has telemt_web_base; }

_telemt_caddy_has() { grep -qF "$TEL_WEB_MARK" "$TEL_CADDY" 2>/dev/null; }

# Правит Caddyfile через временный файл: проверка caddy validate, копия, перезапуск.
# reload у Caddy здесь не работает — в install.sh admin API выключен.
_telemt_caddy_apply() {  # _telemt_caddy_apply add|del
  local act="$1" tmp bak
  tmp=$(mktemp) || return 1
  TEL_ACT="$act" TEL_BASE="$(pl_meta_get telemt_web_base)" TEL_PORT_WEB="$TEL_WEB_PORT" \
  TEL_SRC="$TEL_CADDY" TEL_DST="$tmp" TEL_MARK="$TEL_WEB_MARK" python3 - <<'PY' || { rm -f "$tmp"; return 1; }
import os, re
e = os.environ
lines = open(e["TEL_SRC"]).read().split("\n")
mark = e["TEL_MARK"]; end = mark.replace("packetlab:", "/packetlab:")
out = []; skip = False
for l in lines:                     # прежний блок убираем в любом случае
    if l.strip() == mark: skip = True; continue
    if skip:
        if l.strip() == end: skip = False
        continue
    out.append(l)
if e["TEL_ACT"] == "add":
    base = e["TEL_BASE"]
    block = f"""    {mark}
    handle /{base}/* {{
        reverse_proxy 127.0.0.1:{e["TEL_PORT_WEB"]} {{
            header_up X-Forwarded-For {{remote_host}}
            flush_interval -1
        }}
    }}
    {end}""".split("\n")
    i = next(i for i, l in enumerate(out) if l.startswith(":8080 {"))
    out[i+1:i+1] = block
open(e["TEL_DST"], "w").write("\n".join(out))
PY
  if ! caddy validate --adapter caddyfile --config "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; ui_err "Caddyfile после правки невалиден, не трогаю"; return 1
  fi
  if cmp -s "$tmp" "$TEL_CADDY"; then rm -f "$tmp"; return 0; fi
  bak="$TEL_CADDY.bak-$(date +%s)"
  cp -a "$TEL_CADDY" "$bak"
  cat "$tmp" > "$TEL_CADDY"; rm -f "$tmp"
  if ! systemctl restart caddy || ! systemctl is-active --quiet caddy; then
    cat "$bak" > "$TEL_CADDY"; systemctl restart caddy
    ui_err "Caddy не поднялся с новым блоком, вернул прежний"; return 1
  fi
}

mod_install() {
  [ -f "$TEL_CONF" ] && { ui_err "telemt уже настроен — сначала удалить"; return 1; }
  local sni arch libc asset base tmp ver i web=no
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
  if _telemt_web_possible; then
    web=yes
    pl_meta_set telemt_web_base "w$(pl_hex 6)"
    # Приманка WEB-режима — снимок сайта, который Caddy отдаёт на домене.
    install -d -o telemt -g telemt -m 750 "$TEL_VAR/decoy"
    cp -a "$TEL_DECOY_SRC/." "$TEL_VAR/decoy/" && chown -R telemt:telemt "$TEL_VAR/decoy"
  else
    ui_note "WEB-прокси пропущен: нужен домен сервера и Caddy с decoy-сайтом"
  fi
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
  if [ "$web" = yes ]; then
    pl_port_listening "$TEL_WEB_PORT" tcp \
      || { ui_err "WEB-слушатель telemt не поднялся"; ui_note "journalctl -u telemt -n 20 --no-pager"; return 1; }
    _telemt_caddy_apply add || return 1
  fi

  pl_haproxy_add_sni "$sni" "$MOD_ID" "$MOD_PORT" || return 1
  pl_ufw_sync_module
  [ -n "$ver" ] && pl_meta_set telemt_ver "$ver"
  return 0
}

mod_remove() {
  pl_haproxy_del_sni "$MOD_ID" || return 1
  if _telemt_caddy_has; then _telemt_caddy_apply del || return 1; fi
  systemctl disable --now telemt >/dev/null 2>&1
  rm -f "$TEL_UNIT"; systemctl daemon-reload
  rm -rf "$TEL_ETC" "$TEL_VAR"; rm -f "$TEL_BIN"
  id telemt >/dev/null 2>&1 && userdel telemt >/dev/null 2>&1
  pl_meta_del telemt_sni telemt_ver telemt_web_base
  return 0
}

# Только tg://: в подписку sing-box этот протокол не попадает (clash/singbox — пусто).
#   uri — обычный MTProxy (FakeTLS), web — WEB-прокси (пусто, если WEB не включён).
mod_link() {  # mod_link <формат> [пользователь]
  local u hex sni base
  case "$1" in uri|web) ;; *) return 0 ;; esac
  u=$(pl_link_user "${2:-}"); hex=$(pl_cred "$u" "$MOD_ID" hex) || return 1
  if [ "$1" = web ]; then
    base=$(pl_meta_get telemt_web_base); [ -n "$base" ] || return 0
    # Ссылка с путём: secret = base64url(0x70 ‖ 0xdd ‖ ключ), без «=».
    printf 'tg://webproxy?server=%s&secret=%s\n' "$(pl_urlenc "$PL_DOMAIN/$base")" \
      "$(python3 -c 'import sys,base64;print(base64.urlsafe_b64encode(bytes([0x70,0xdd])+bytes.fromhex(sys.argv[1])).decode().rstrip("="))' "$hex")"
    return 0
  fi
  sni=$(pl_meta_get telemt_sni)
  printf 'tg://proxy?server=%s&port=443&secret=ee%s%s\n' "$PL_HOST" "$hex" \
    "$(printf '%s' "$sni" | od -An -tx1 | tr -d ' \n')"
}
