#!/usr/bin/env bash
# packetlab — наборы правил для клиентов (запускает packetlab-rules.timer раз в сутки).
# adguard.srs — фильтр AdGuard DNS, переведённый в rule-set sing-box. Сервер подписок
# отдаёт его по /sub/<токен>/rules/adguard.srs, клиент режет рекламу у себя.
# Новый файл подменяет старый только целиком и только после удачной сборки:
# не скачалось — клиенты остаются на вчерашнем, а не получают пустой набор.
set -euo pipefail

OUT=/var/lib/packetlab/rules
SRC=https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
MIN_BYTES=100000   # меньше — значит, вместо фильтра пришла заглушка или ошибка

mkdir -p "$OUT"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -m 120 -o "$tmp/filter.txt" "$SRC"
[ "$(stat -c %s "$tmp/filter.txt")" -ge "$MIN_BYTES" ] || { echo "фильтр подозрительно мал" >&2; exit 1; }
sing-box rule-set convert --type adguard -o "$tmp/adguard.srs" "$tmp/filter.txt" 2>/dev/null
[ -s "$tmp/adguard.srs" ] || { echo "конвертация не дала файла" >&2; exit 1; }

install -m 644 "$tmp/adguard.srs" "$OUT/adguard.srs.new"
mv -f "$OUT/adguard.srs.new" "$OUT/adguard.srs"
echo "adguard.srs: $(stat -c %s "$OUT/adguard.srs") байт"
