# packetlab

Модульный установщик и меню управления мультипротокольным прокси-стеком.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/sovereignbrains/packetlab/main/install.sh | bash
```

Debian 13, x86_64, root. Установщик спрашивает домен — дальше развилка:

- **с доменом** — домен в Cloudflare и API-токен с правами `Zone:DNS:Edit`:
  wildcard-сертификат по DNS-01, decoy-сайт, подписка, все протоколы.
  Zone ID установщик находит по токену сам, спрашивает — только если токен зону не видит;
- **без домена** (пустой Enter) — ни Cloudflare, ни сертификата: доступны REALITY,
  AnyTLS + REALITY и Mieru, в ссылках IP сервера, подписки нет (ссылки и QR — в меню).

Без интерактива (удобно для нескольких серверов):

```bash
PL_DOMAIN=example.com PL_CF_TOKEN=... PL_CF_ZONE=... \
  bash <(curl -fsSL https://raw.githubusercontent.com/sovereignbrains/packetlab/main/install.sh)

PL_NO_DOMAIN=1 bash <(curl -fsSL https://raw.githubusercontent.com/sovereignbrains/packetlab/main/install.sh)
```

⚠️ Установщик выполняет `ufw --force reset` — запускать только на чистом
сервере, иначе снесёт существующие правила firewall.

## Управление

```bash
packetlab            # меню
packetlab status     # диагностика: конфиг / порт / firewall
packetlab sub        # ссылка-подписка
packetlab link uri   # все ноды списком
packetlab install anytls-reality   # поставить модуль без меню
```

## Что внутри

| Слой | Чем |
|---|---|
| Вход 443/tcp | haproxy, SNI-роутинг без терминации TLS |
| Вход UDP | sing-box напрямую |
| Ядро | одно — sing-box в сборке [mbox](https://github.com/enfein/mbox): апстрим + протокол Mieru от его автора, пакет закреплён `apt-mark hold` |
| Протоколы | REALITY, AnyTLS, AnyTLS + REALITY, AnyTLS + ECH, TUIC, NaiveProxy, Hysteria2, Mieru — все инбаунды sing-box |
| Маскировка | Caddy, decoy-сайт (с доменом); без домена чужой SNI уходит в REALITY |
| Подписка | один URL, формат по User-Agent |

Подписка — sing-box JSON с `urltest`. Karing и Hiddify получают всё, официальный
клиент sing-box — без Mieru: он этого протокола не знает (модуль помечен
`MOD_CLIENTS=extended`).

## Модули

Протокол — один файл в `modules/`, объявляющий метаданные и четыре функции:
`mod_status`, `mod_install`, `mod_remove`, `mod_link`. Меню сканирует папку и
подхватывает новый файл само, править диспетчер не нужно.

`mod_status` сверяет три источника — конфиг, реально слушающий порт и правило
firewall — и различает `down` (не слушает) и `blocked` (слушает, но порт
закрыт). Правило UFW создаётся и удаляется вместе с инбаундом, поэтому
рассинхрон конфига и firewall невозможен.
## Вход → выход (中转 → 落地)

Клиенты подключаются к одному серверу (вход), а в интернет выходят с другого (выход).
Подписка не меняется — сайты просто видят IP выхода. Между серверами — VLESS + REALITY:
выходу не нужны ни домен, ни сертификат, а канал вход → выход устойчив к DPI (нужно, когда
вход стоит в стране с фильтрацией).

Всё делает `relay/plr.sh` — один файл, обе роли, packetlab для него не нужен. На серверах с
packetlab он уже стоит как `plr` и доступен из меню (`r`).

```bash
# на сервере без packetlab
curl -fsSL https://raw.githubusercontent.com/sovereignbrains/packetlab/main/relay/plr.sh \
  -o /usr/local/bin/plr && chmod +x /usr/local/bin/plr

plr exit             # на выходе: поднять relay-in и напечатать токен plr1.…
plr link <токен>     # на входе: связать; трафик клиентов пока идёт напрямую
plr test             # запрос через проверочный порт должен вернуться с IP выхода
plr on               # весь трафик клиентов — через выход (plr off — обратно)
plr unlink           # на входе: убрать связку;  plr exit --remove — на выходе
```

Токен — это секрет (внутри ключи выхода), с контрольной суммой: обрезанная вставка
отлавливается сразу. `plr on` не переключит трафик, пока не пройдёт проверка. Каждое
изменение перезапускает sing-box — активные соединения через сервер обрываются.
