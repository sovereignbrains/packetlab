#!/usr/bin/env bash
MOD_ID=ech
MOD_NAME="AnyTLS + ECH"
MOD_DESC="AnyTLS с шифрованием SNI (ECH), отдельный decoy-домен"
MOD_ENGINE=sing-box
MOD_PORT=8447
MOD_PROTO=tcp
MOD_VIA_HAPROXY=yes
MOD_ECH_DIR=/etc/packetlab/ech
MOD_LEVEL=advanced

mod_status() {
  pl_singbox_has_tag "${MOD_ID}-in" || { printf off; return; }
  pl_port_listening "$MOD_PORT" tcp || { printf down; return; }
  pl_ufw_allows 443 tcp || { printf blocked; return; }
  pl_haproxy_has_backend "$MOD_ID" || { printf broken; return; }
  pl_meta_has ech_pass || { printf broken; return; }
  printf up
}

# Публикует/обновляет base64 ECHConfigList в HTTPS-запись домена ($1),
# используя тот же CF-токен, что и основной домен (тот же аккаунт).
_ech_publish() {
  local target="$1" b64="$2" token zone rec payload
  token=$(pl_meta_get cf_token)
  zone=$(curl -s -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?name=${target}" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);r=d.get('result') or [];print(r[0]['id'] if r else '')")
  [ -z "$zone" ] && { ui_err "CF-токен не видит зону $target"; return 1; }

  rec=$(curl -s -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?type=HTTPS&name=${target}" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin); rs=d.get('result') or []
m=[x for x in rs if 'ech=' in x.get('data',{}).get('value','')]
print(m[0]['id'] if m else '')")

  payload=$(python3 -c "
import json,sys
print(json.dumps({'type':'HTTPS','name':sys.argv[1],'ttl':300,
  'data':{'priority':1,'target':'.','value':'ech='+sys.argv[2]}}))" "$target" "$b64")

  if [ -n "$rec" ]; then
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$rec" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" --data "$payload" \
      | grep -q '"success":true' || { ui_err "не смог обновить ECH-запись"; return 1; }
  else
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone/dns_records" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" --data "$payload" \
      | grep -q '"success":true' || { ui_err "не смог создать ECH-запись"; return 1; }
  fi
}

mod_install() {
  pl_singbox_has_tag "${MOD_ID}-in" && { ui_err "инбаунд ${MOD_ID}-in уже есть — сначала удалить"; return 1; }
  local pass target cert key
  target=$(pl_meta_get ech_domain); [ -z "$target" ] && target=edgevanga.xyz
  pass=$(pl_secret)
  cert="/etc/letsencrypt/live/${target}/fullchain.pem"
  key="/etc/letsencrypt/live/${target}/privkey.pem"

  getent hosts "$target" >/dev/null 2>&1 \
    || { ui_err "$target не резолвится — заведи A-запись (DNS only) вручную"; return 1; }

  if [ ! -f "$cert" ]; then
    certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
      --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare/token.ini \
      --dns-cloudflare-propagation-seconds 30 \
      -d "$target" --cert-name "$target" \
      || { ui_err "certbot не смог выпустить сертификат для $target"; return 1; }
  fi

  mkdir -p "$MOD_ECH_DIR"; chmod 700 "$MOD_ECH_DIR"
  if [ ! -f "$MOD_ECH_DIR/ech-keys.pem" ]; then
    sing-box generate ech-keypair "$target" > "$MOD_ECH_DIR/ech-full.pem" \
      || { ui_err "sing-box не смог сгенерировать ECH-ключ"; return 1; }
    awk '/BEGIN ECH KEYS/,/END ECH KEYS/' "$MOD_ECH_DIR/ech-full.pem" > "$MOD_ECH_DIR/ech-keys.pem"
    awk '/BEGIN ECH CONFIGS/,/END ECH CONFIGS/' "$MOD_ECH_DIR/ech-full.pem" \
      | sed '1d;$d' | tr -d '\n' > "$MOD_ECH_DIR/ech-b64.txt"
    chmod 600 "$MOD_ECH_DIR"/ech-*.pem "$MOD_ECH_DIR/ech-b64.txt"
  fi

  _ech_publish "$target" "$(cat "$MOD_ECH_DIR/ech-b64.txt")" || return 1

  pl_singbox_add_inbound "$(cat <<JSON
{ "type":"anytls","tag":"${MOD_ID}-in","listen":"127.0.0.1","listen_port":${MOD_PORT},
  "users":[{"name":"${PL_USER}","password":"${pass}"}],
  "tls":{"enabled":true,"server_name":"${target}",
    "certificate_path":"${cert}","key_path":"${key}",
    "ech":{"enabled":true,"key_path":"${MOD_ECH_DIR}/ech-keys.pem"}} }
JSON
)" || return 1

  pl_haproxy_add_sni "$target" "$MOD_ID" "$MOD_PORT" || return 1
  pl_ufw_open 443 tcp "$MOD_ID"
  pl_meta_set "${MOD_ID}_pass" "$pass"
  pl_meta_set "${MOD_ID}_sni"  "$target"
  pl_singbox_apply && pl_sub_reload
}

mod_remove() {
  pl_singbox_del_inbound "${MOD_ID}-in" || return 1
  pl_haproxy_del_sni "$MOD_ID"
  pl_meta_del "${MOD_ID}_pass" "${MOD_ID}_sni"
  pl_singbox_apply && pl_sub_reload
}

mod_link() {
  local name="AnyTLS-ECH"
  case "$1" in
    singbox) cat <<JSON
{ "type":"anytls","tag":"${name}","server":"$(pl_meta_get ${MOD_ID}_sni)","server_port":443,
  "password":"$(pl_meta_get ${MOD_ID}_pass)",
  "tls":{"enabled":true,"server_name":"$(pl_meta_get ${MOD_ID}_sni)","ech":{"enabled":true}} }
JSON
    ;;
    clash|uri) ui_warn "ECH включается автодетектом sing-box через DoH; для $1 отдельного поля под ech нет, соединение пойдёт без него" ;;
  esac
}
