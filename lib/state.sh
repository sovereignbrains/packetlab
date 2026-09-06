#!/usr/bin/env bash
# Индикаторы для меню. Ничего не меняют, только читают.

pl_domain_or_unset() { [ -n "${PL_DOMAIN:-}" ] && printf '%s' "$PL_DOMAIN" || printf 'домен не задан'; }

pl_engine_line() {
  local out=()
  command -v sing-box >/dev/null && out+=("sing-box $(sing-box version 2>/dev/null | head -1 | awk '{print $3}')")
  command -v mita     >/dev/null && out+=("mita")
  command -v mihomo   >/dev/null && out+=("mihomo")
  local IFS=' + '; printf '%s' "${out[*]}"
}

pl_user_count() {
  python3 -c "import json;print(len(json.load(open('$PL_USERS'))))" 2>/dev/null || printf '0'
}

pl_sub_state() {
  systemctl is-active --quiet packetlab-sub && printf 'up' || printf 'down'
}

pl_cert_state() {
  [ -f "$PL_CERT" ] || { printf 'off'; return; }
  if openssl x509 -in "$PL_CERT" -noout -checkend 604800 >/dev/null 2>&1; then
    printf 'up'
  else
    printf 'blocked'   # живой, но истекает в пределах недели
  fi
}

pl_cert_days() {
  [ -f "$PL_CERT" ] || return
  local end now
  end=$(date -d "$(openssl x509 -in "$PL_CERT" -noout -enddate | cut -d= -f2)" +%s 2>/dev/null) || return
  now=$(date +%s)
  printf '%d дн.' $(( (end-now)/86400 ))
}

# Тюнинг ядра: буферы под QUIC + bbr/fq. Без буферов sing-box упирается
# в потолок quic-go и пишет предупреждение в лог.
pl_sysctl_state() {
  local r q c
  r=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
  q=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '')
  c=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')
  if [ "$r" -ge 16777216 ] && [ "$q" = fq ] && [ "$c" = bbr ]; then printf 'up'
  elif [ "$r" -ge 16777216 ] || [ "$c" = bbr ]; then printf 'blocked'
  else printf 'off'; fi
}

# Общее здоровье: down если хоть один обязательный сервис лежит.
pl_health() {
  local s bad=0
  for s in sing-box haproxy caddy packetlab-sub; do
    systemctl list-unit-files "$s.service" >/dev/null 2>&1 || continue
    systemctl is-active --quiet "$s" || bad=1
  done
  [ "$bad" -eq 0 ] && printf 'up' || printf 'down'
}
