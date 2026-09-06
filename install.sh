#!/usr/bin/env bash
# packetlab — установка с нуля.
#
#   curl -fsSL https://raw.githubusercontent.com/sovereignbrains/packetlab/main/install.sh | bash
#
# Что делает: ставит ядра (sing-box, mita, mihomo), haproxy как SNI-мультиплексор,
# Caddy с decoy-сайтом, выпускает wildcard-сертификат через DNS-01, тюнит ядро,
# поднимает сервер подписок и ставит CLI `packetlab`.
#
# Протоколы НЕ ставятся автоматически — это делается из меню после установки.
# Идемпотентен: повторный запуск дочиняет недостающее, не ломая рабочее.

set -uo pipefail

REPO_RAW="https://raw.githubusercontent.com/sovereignbrains/packetlab/main"
PL_ROOT=/opt/packetlab
PL_ETC=/etc/packetlab
PL_VAR=/var/lib/packetlab

# ---------------------------------------------------------------- вывод ---
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_GRY=$'\033[38;5;244m'
  C_GRN=$'\033[38;5;42m'; C_YLW=$'\033[38;5;214m'
  C_RED=$'\033[38;5;203m'; C_CYN=$'\033[38;5;80m'
else
  C_RST=''; C_B=''; C_GRY=''; C_GRN=''; C_YLW=''; C_RED=''; C_CYN=''
fi
say()  { printf '  %s·%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YLW" "$C_RST" "$*"; }
die()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$*"; exit 1; }
head_() {
  printf '\n%s%s%s\n' "$C_GRY" "$(printf '━%.0s' $(seq 1 60))" "$C_RST"
  printf '  %s%s%s%s\n' "$C_B" "$C_CYN" "$1" "$C_RST"
  [ $# -gt 1 ] && printf '  %s%s%s\n' "$C_GRY" "$2" "$C_RST"
  printf '%s%s%s\n' "$C_GRY" "$(printf '━%.0s' $(seq 1 60))" "$C_RST"
}
ask() {
  local p="$1" d="${2:-}" a
  if [ -n "$d" ]; then printf '  ? %s [%s] ' "$p" "$d" >&2; else printf '  ? %s ' "$p" >&2; fi
  read -r a </dev/tty
  printf '%s' "${a:-$d}"
}

# --------------------------------------------------------------- проверки -
[ "$(id -u)" -eq 0 ] || die "нужен root"

. /etc/os-release 2>/dev/null || die "не могу определить ОС"
if [ "${ID:-}" != debian ]; then
  warn "ОС: ${PRETTY_NAME:-неизвестно}. Скрипт писался под Debian 13."
  [ "$(ask 'продолжить? (y/N)')" = y ] || exit 1
elif [ "${VERSION_ID:-0}" -lt 13 ] 2>/dev/null; then
  warn "Debian ${VERSION_ID}, ожидался 13+"
fi
[ "$(uname -m)" = x86_64 ] || warn "архитектура $(uname -m), пакеты подбирались под amd64"

head_ "packetlab" "установка с нуля · $(date +%F)"

# ---------------------------------------------------------------- ввод ----
# Всё, что передано в окружении, не спрашивается. Позволяет разворачивать
# несколько серверов одной командой без интерактива:
#   PL_DOMAIN=… PL_CF_TOKEN=… PL_CF_ZONE=… bash <(curl -fsSL …/install.sh)
DOMAIN="${PL_DOMAIN:-}"
CF_TOKEN="${PL_CF_TOKEN:-}"
CF_ZONE="${PL_CF_ZONE:-}"
PL_USER="${PL_USER:-Boss}"     # метка пользователя внутри инбаундов,
                               # в именах нод не используется

[ -n "$DOMAIN" ]   || DOMAIN=$(ask "домен (без поддомена)")
[ -n "$DOMAIN" ]   || die "домен обязателен"
[ -n "$CF_TOKEN" ] || CF_TOKEN=$(ask "Cloudflare API token (Zone:DNS:Edit)")
[ -n "$CF_TOKEN" ] || die "токен обязателен для DNS-01"
[ -n "$CF_ZONE" ]  || CF_ZONE=$(ask "Cloudflare Zone ID")

SERVER_IP=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
say "внешний IP: $SERVER_IP"

# Токены при копипасте с телефона регулярно теряют последний символ —
# проверяем сразу, а не после получаса установки.
say "проверяю токен…"
if ! curl -fsS -H "Authorization: Bearer $CF_TOKEN" \
     https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null | grep -q '"success":true'; then
  die "Cloudflare отверг токен. Частая причина — при копировании потерялся последний символ."
fi
ok "токен принят"

# A-запись домена. Сертификат выпустится и без неё (DNS-01), но клиент
# в такой сервер не попадёт — предупреждаем до, а не после установки.
resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
if [ -z "$resolved" ]; then
  warn "A-запись $DOMAIN не резолвится — создай её на $SERVER_IP"
elif [ "$resolved" != "$SERVER_IP" ]; then
  warn "$DOMAIN указывает на $resolved, а сервер — $SERVER_IP"
  warn "если запись проксируется Cloudflare, переключи её в DNS only"
else
  ok "A-запись $DOMAIN → $SERVER_IP"
fi

# --------------------------------------------------------------- пакеты ---
head_ "пакеты"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # не спрашивать, какие сервисы перезапустить
say "apt update…"
apt-get update -qq || die "apt update не прошёл"

# Обновление системы — только по явному запросу: PL_UPGRADE=1.
# На работающем стеке upgrade может дёрнуть haproxy/openssl и перезапустить
# сервисы, поэтому по умолчанию не трогаем.
if [ "${PL_UPGRADE:-0}" = 1 ]; then
  pending=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')
  if [ "${pending:-0}" -eq 0 ]; then
    ok "система актуальна"
  else
    say "обновляю систему: пакетов к обновлению — $pending…"
    apt-get upgrade -y -qq \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      >/dev/null 2>&1 && ok "система обновлена" || warn "часть пакетов не обновилась, продолжаю"
  fi
else
  pending=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')
  [ "${pending:-0}" -gt 0 ] \
    && say "доступно обновлений: $pending (PL_UPGRADE=1 — обновить)" \
    || ok "система актуальна"
fi

apt-get install -y -qq \
  curl ca-certificates gnupg jq openssl ufw haproxy python3 python3-venv \
  certbot python3-certbot-dns-cloudflare dnsutils iproute2 >/dev/null \
  || die "не смог поставить базовые пакеты"
ok "базовые пакеты"

# Caddy живёт в собственном репозитории — в Debian он есть не всегда.
if ! command -v caddy >/dev/null; then
  if ! apt-get install -y -qq caddy >/dev/null 2>&1; then
    say "подключаю репозиторий Caddy…"
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq && apt-get install -y -qq caddy >/dev/null || die "Caddy не встал"
  fi
fi
ok "caddy $(caddy version 2>/dev/null | head -1)"

# ----------------------------------------------------------------- ядра ---
# Тянем .deb из GitHub Releases. Версия не фиксируется намеренно: стек
# новый, и отставать от апстрима смысла нет.
fetch_deb() {   # fetch_deb <owner/repo> <шаблон-имени>
  local repo="$1" pat="$2" url tmp
  url=$(curl -fsS "https://api.github.com/repos/$repo/releases/latest" \
        | jq -r --arg p "$pat" '.assets[] | select(.name|test($p)) | .browser_download_url' \
        | head -1)
  [ -n "$url" ] || return 1
  tmp=$(mktemp /tmp/pl-XXXX.deb)
  curl -fsSL -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
  dpkg -i "$tmp" >/dev/null 2>&1 || apt-get -f install -y -qq >/dev/null
  rm -f "$tmp"
}

head_ "ядра"
if command -v sing-box >/dev/null; then
  ok "sing-box уже стоит: $(sing-box version | head -1 | awk '{print $3}')"
else
  fetch_deb SagerNet/sing-box 'linux_amd64\.deb$' && ok "sing-box $(sing-box version | head -1 | awk '{print $3}')" \
    || die "sing-box не установился"
fi

if command -v mita >/dev/null; then
  ok "mita уже стоит"
else
  fetch_deb enfein/mieru 'mita.*amd64\.deb$' && ok "mita" || warn "mita не установился — Mieru будет недоступен"
fi

# mihomo ставится пустым: протоколов на нём нет, held под будущие тесты.
if command -v mihomo >/dev/null; then
  ok "mihomo уже стоит"
else
  fetch_deb MetaCubeX/mihomo 'linux-amd64.*\.deb$' && ok "mihomo (простаивает)" \
    || warn "mihomo не установился — не критично"
fi

# ---------------------------------------------------------- сертификат ----
head_ "сертификат" "wildcard через DNS-01"
install -d -m 700 /etc/letsencrypt/cloudflare
printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > /etc/letsencrypt/cloudflare/token.ini
chmod 600 /etc/letsencrypt/cloudflare/token.ini

if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  ok "сертификат уже выпущен"
else
  say "запрашиваю (DNS-01 занимает ~1 минуту)…"
  certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
    --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare/token.ini \
    --dns-cloudflare-propagation-seconds 30 \
    -d "$DOMAIN" -d "*.$DOMAIN" >/dev/null 2>&1 \
    || die "certbot не смог выпустить сертификат, смотри /var/log/letsencrypt/"
  ok "выпущен: $DOMAIN + *.$DOMAIN"
fi

# sing-box читает сертификат с диска и не перечитывает его сам —
# после продления нужен рестарт, иначе через 90 дней всё тихо ляжет.
install -d /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/packetlab.sh <<HOOK
#!/bin/sh
# Caddy работает не от root и приватный ключ в /etc/letsencrypt (0600 root)
# прочитать не может — держим для него копию с правами группы caddy.
d=/var/lib/packetlab/certs
install -d -m 750 "\$d"
cp -L /etc/letsencrypt/live/$DOMAIN/fullchain.pem "\$d/fullchain.pem" 2>/dev/null
cp -L /etc/letsencrypt/live/$DOMAIN/privkey.pem   "\$d/privkey.pem"   2>/dev/null
chgrp caddy "\$d" "\$d"/*.pem 2>/dev/null
chmod 640 "\$d"/*.pem 2>/dev/null
systemctl restart sing-box 2>/dev/null
systemctl reload haproxy 2>/dev/null
systemctl reload caddy 2>/dev/null
exit 0
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/packetlab.sh
ok "deploy-hook на продление"

# ------------------------------------------------------------- тюнинг ----
head_ "тюнинг ядра"
cat > /etc/sysctl.d/99-packetlab.conf <<'SYS'
# QUIC (TUIC, Hysteria2) упирается в размер UDP-буферов: без этого
# quic-go пишет предупреждение в лог и режет пропускную способность.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
SYS
sysctl -p /etc/sysctl.d/99-packetlab.conf >/dev/null 2>&1
[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] \
  && ok "bbr + fq, буферы 16 МБ" || warn "bbr не активировался, проверь модуль ядра"

# -------------------------------------------------------------- firewall -
head_ "firewall"
ufw --force disable >/dev/null 2>&1
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
ufw allow 443/tcp comment 'packetlab:haproxy' >/dev/null
ufw --force enable >/dev/null
ok "открыты: SSH, 443/tcp. Порты протоколов откроются при их установке"

# --------------------------------------------------------------- haproxy -
head_ "haproxy" "SNI-мультиплексор на 443/tcp"
[ -f /etc/haproxy/haproxy.cfg ] && cp -a /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.orig-$(date +%s)"
cat > /etc/haproxy/haproxy.cfg <<'HAP'
global
    daemon
    maxconn 20000
    log /dev/log local0 warning

defaults
    mode tcp
    timeout connect 5s
    timeout client 300s
    timeout server 300s

# TLS здесь НЕ терминируется: haproxy читает SNI из ClientHello и передаёт
# соединение дальше как есть. Поэтому REALITY продолжает работать.
frontend tls_in
    bind *:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    # правила use_backend дописываются модулями протоколов
    default_backend site

backend site
    mode tcp
    server site 127.0.0.1:8080
HAP
haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 || die "haproxy.cfg невалиден"
systemctl enable --now haproxy >/dev/null 2>&1
ok "haproxy поднят"

# ----------------------------------------------------------------- caddy -
head_ "decoy-сайт" "то, что видит случайный гость"
install -d /var/www/decoy
cat > /var/www/decoy/index.html <<'HTML'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Status</title><style>
body{font-family:ui-sans-serif,system-ui,sans-serif;background:#0f1115;color:#c9d1d9;
display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
main{text-align:center}h1{font-weight:500;font-size:1.25rem;margin:0 0 .5rem}
p{color:#7d8590;font-size:.875rem;margin:0}</style></head>
<body><main><h1>All systems operational</h1><p>Nothing to see here.</p></main></body></html>
HTML

# haproxy отдаёт сюда TLS как есть, не расшифровывая (иначе сломался бы
# REALITY), поэтому терминировать соединение обязан сам Caddy — иначе клиент
# здоровается TLS с открытым HTTP и получает ошибку рукопожатия.
/etc/letsencrypt/renewal-hooks/deploy/packetlab.sh >/dev/null 2>&1

cat > /etc/caddy/Caddyfile <<CADDY
{
    admin off
    auto_https off
}

:8080 {
    tls /var/lib/packetlab/certs/fullchain.pem /var/lib/packetlab/certs/privkey.pem

    root * /var/www/decoy
    file_server

    # подписка отдаётся через тот же decoy-хост
    handle /sub/* {
        reverse_proxy 127.0.0.1:9999
    }
}
CADDY
systemctl enable --now caddy >/dev/null 2>&1
systemctl restart caddy >/dev/null 2>&1
sleep 1
if systemctl is-active --quiet caddy; then
  ok "decoy на 8080 (TLS), /sub/* → 9999"
else
  warn "caddy не поднялся: journalctl -u caddy -n 20 --no-pager"
fi

# -------------------------------------------------------------- sing-box -
head_ "sing-box" "пустой конфиг, инбаунды добавит меню"
install -d /etc/sing-box
if [ ! -f /etc/sing-box/config.json ]; then
  cat > /etc/sing-box/config.json <<'SB'
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
SB
  ok "конфиг создан"
else
  # Пакет sing-box кладёт свой демонстрационный конфиг (shadowsocks на 8080),
  # который конфликтует с decoy-сайтом и роняет сервис на старте. Свои
  # инбаунды packetlab всегда тегирует, поэтому нетегированные — чужие.
  # `sing-box check` такое не ловит: синтаксис валиден, падает уже listener.
  if python3 - <<'PYSB'
import json, shutil, time, sys
p = '/etc/sing-box/config.json'
d = json.load(open(p))
keep = [i for i in d.get('inbounds', []) if i.get('tag')]
drop = [i for i in d.get('inbounds', []) if not i.get('tag')]
if not drop:
    sys.exit(1)
shutil.copy2(p, p + '.bak-%d' % time.time())
d['inbounds'] = keep
json.dump(d, open(p, 'w'), indent=2, ensure_ascii=False)
print(', '.join('%s:%s' % (i.get('type'), i.get('listen_port')) for i in drop))
PYSB
  then
    ok "убраны чужие инбаунды из конфига (копия рядом, .bak-*)"
  else
    ok "конфиг на месте"
  fi
fi
sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 || die "базовый конфиг невалиден"
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
ok "sing-box запущен"

# ------------------------------------------------------------ packetlab --
head_ "packetlab"
install -d "$PL_ROOT/lib" "$PL_ROOT/modules" "$PL_ROOT/sub" "$PL_ETC" "$PL_VAR"

get() {  # get <путь-в-репо> <куда>
  curl -fsSL "$REPO_RAW/$1" -o "$2" || die "не смог скачать $1"
}
get packetlab              "$PL_ROOT/packetlab"
get lib/ui.sh              "$PL_ROOT/lib/ui.sh"
get lib/core.sh            "$PL_ROOT/lib/core.sh"
get lib/state.sh           "$PL_ROOT/lib/state.sh"
get sub/packetlab-sub.py   "$PL_ROOT/sub/packetlab-sub.py"
for m in reality tuic anytls naive hy2 mieru; do
  get "modules/$m.sh" "$PL_ROOT/modules/$m.sh"
done
chmod +x "$PL_ROOT/packetlab" "$PL_ROOT/sub/packetlab-sub.py"
ln -sf "$PL_ROOT/packetlab" /usr/local/bin/packetlab
ok "файлы разложены"

# состояние: домен — параметр, а не константа, чтобы переезд на другой
# домен был операцией, а не переустановкой
if [ ! -f "$PL_ETC/meta.json" ]; then
  cat > "$PL_ETC/meta.json" <<META
{
  "domain": "$DOMAIN",
  "user": "$PL_USER",
  "ip": "$SERVER_IP",
  "cf_token": "$CF_TOKEN",
  "cf_zone": "$CF_ZONE",
  "reality_target": "www.bing.com"
}
META
  chmod 600 "$PL_ETC/meta.json"
else
  # Файл уже есть: обновляем то, что задано этим запуском (домен мог
  # смениться), остальные ключи — reality_target и прочее — не трогаем.
  old_domain=$(PL_ETC="$PL_ETC" python3 -c "import json,os;print(json.load(open(os.environ['PL_ETC']+'/meta.json')).get('domain',''))" 2>/dev/null)
  if DOMAIN="$DOMAIN" PL_USER="$PL_USER" SERVER_IP="$SERVER_IP" \
     CF_TOKEN="$CF_TOKEN" CF_ZONE="$CF_ZONE" PL_ETC="$PL_ETC" python3 - <<'PYMETA'
import json, os
p = os.environ['PL_ETC'] + '/meta.json'
m = json.load(open(p))
m.update({
    'domain':   os.environ['DOMAIN'],
    'user':     os.environ['PL_USER'],
    'ip':       os.environ['SERVER_IP'],
    'cf_token': os.environ['CF_TOKEN'],
    'cf_zone':  os.environ['CF_ZONE'],
})
json.dump(m, open(p, 'w'), indent=2, ensure_ascii=False)
PYMETA
  then
    chmod 600 "$PL_ETC/meta.json"
    if [ -n "$old_domain" ] && [ "$old_domain" != "$DOMAIN" ]; then
      ok "состояние обновлено: домен $old_domain → $DOMAIN"
      warn "поддомены протоколов на $old_domain остались в Cloudflare — почисти вручную"
      warn "старый сертификат: certbot delete --cert-name $old_domain"
    fi
  else
    warn "не смог обновить $PL_ETC/meta.json — проверь файл вручную"
  fi
fi

if [ ! -f "$PL_ETC/users.json" ]; then
  printf '[{"name":"%s","sub_token":"%s"}]\n' \
    "$PL_USER" "$(openssl rand -hex 16)" > "$PL_ETC/users.json"
  chmod 600 "$PL_ETC/users.json"
fi
ok "состояние в $PL_ETC"

cat > /etc/systemd/system/packetlab-sub.service <<UNIT
[Unit]
Description=packetlab subscription server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $PL_ROOT/sub/packetlab-sub.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now packetlab-sub >/dev/null 2>&1
sleep 1
systemctl is-active --quiet packetlab-sub && ok "сервер подписок на :9999" \
  || warn "packetlab-sub не поднялся: journalctl -u packetlab-sub"

# ----------------------------------------------------------------- итог ---
# Ядро могло обновиться при PL_UPGRADE=1 — перезагружать сервер сами не будем.
run_kern=$(uname -r)
new_kern=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
if [ -n "$new_kern" ] && [ "$new_kern" != "$run_kern" ]; then
  warn "ядро обновлено: работает $run_kern, установлено $new_kern — нужна перезагрузка"
fi

head_ "готово" "протоколы ставятся из меню"
printf '  %sпроверь, что A-запись %s → %s уже есть%s\n' "$C_GRY" "$DOMAIN" "$SERVER_IP" "$C_RST"
printf '  %sподдомены протоколов создадутся автоматически%s\n\n' "$C_GRY" "$C_RST"
printf '  запуск меню:  %spacketlab%s\n\n' "$C_B" "$C_RST"
