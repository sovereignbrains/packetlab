#!/usr/bin/env bash
# packetlab — слой отрисовки.
# Без зависимостей, без полноэкранного режима: всё пишется построчно,
# поэтому переживает обрыв SSH-сессии и копируется целиком.

# ---------------------------------------------------------------- цвета ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m';  C_B=$'\033[1m'
  C_GRN=$'\033[38;5;42m';  C_YLW=$'\033[38;5;214m'
  C_RED=$'\033[38;5;203m'; C_GRY=$'\033[38;5;244m'
  C_CYN=$'\033[38;5;80m';  C_MAG=$'\033[38;5;176m'
else
  C_RST=''; C_DIM=''; C_B=''; C_GRN=''; C_YLW=''
  C_RED=''; C_GRY=''; C_CYN=''; C_MAG=''
fi

# ---------------------------------------------------------------- ширина ---
# Termius на телефоне даёт 40-60 колонок. Ниже 46 переходим в узкий режим:
# прячем колонку порта, укорачиваем подписи.
ui_width() {
  local w
  w=$(tput cols 2>/dev/null) || w=80
  [ -z "$w" ] && w=80
  [ "$w" -lt 32 ] && w=32
  [ "$w" -gt 78 ] && w=78
  printf '%s' "$w"
}
ui_narrow() { [ "$(ui_width)" -lt 46 ]; }

# длина строки без ANSI-последовательностей
ui_vlen() {
  local s="$1"
  s=$(printf '%s' "$s" | sed -E $'s/\033\\[[0-9;]*m//g')
  printf '%s' "${#s}"
}

ui_repeat() { local n=$1 c=$2 out=''; while [ "$n" -gt 0 ]; do out="$out$c"; n=$((n-1)); done; printf '%s' "$out"; }

# ----------------------------------------------------------------- рамки ---
ui_rule() { printf '%s%s%s\n' "$C_DIM" "$(ui_repeat "$(ui_width)" '─')" "$C_RST"; }

ui_head() {
  local title="$1" sub="${2:-}" w; w=$(ui_width)
  printf '\n%s%s%s\n' "$C_DIM" "$(ui_repeat "$w" '━')" "$C_RST"
  printf '  %s%s%s%s\n' "$C_B" "$C_CYN" "$title" "$C_RST"
  [ -n "$sub" ] && printf '  %s%s%s\n' "$C_GRY" "$sub" "$C_RST"
  printf '%s%s%s\n' "$C_DIM" "$(ui_repeat "$w" '━')" "$C_RST"
}

ui_section() { printf '\n  %s%s%s\n' "$C_DIM" "$1" "$C_RST"; }

# ---------------------------------------------------------------- статусы ---
# up      — работает: конфиг, порт и firewall согласованы
# blocked — инбаунд поднят, но порт закрыт в UFW (тот самый случай с TUIC)
# down    — установлен, но не слушает
# off     — не установлен
ui_badge() {
  case "$1" in
    up)      printf '%s●%s %sup%s'      "$C_GRN" "$C_RST" "$C_GRN" "$C_RST" ;;
    blocked) printf '%s▲%s %sfw%s'      "$C_YLW" "$C_RST" "$C_YLW" "$C_RST" ;;
    down)    printf '%s●%s %sdown%s'    "$C_RED" "$C_RST" "$C_RED" "$C_RST" ;;
    off)     printf '%s○%s %soff%s'     "$C_GRY" "$C_RST" "$C_GRY" "$C_RST" ;;
    *)       printf '%s?%s'             "$C_GRY" "$C_RST" ;;
  esac
}

# ui_row <ключ> <название> <статус> <порт/примечание>
ui_row() {
  local key="$1" name="$2" state="$3" note="$4"
  local badge pad w namew
  badge=$(ui_badge "$state")
  w=$(ui_width)

  if ui_narrow; then
    namew=$(( w - 16 ))
  else
    namew=24
  fi
  [ "$namew" -lt 8 ] && namew=8
  [ "$namew" -gt 28 ] && namew=28

  # обрезаем имя, если не влезает
  [ "${#name}" -gt "$namew" ] && name="${name:0:$((namew-1))}…"
  pad=$(ui_repeat $(( namew - ${#name} )) ' ')

  printf '  %s%2s%s  %s%s  %s' "$C_B" "$key" "$C_RST" "$name" "$pad" "$badge"
  if ! ui_narrow && [ -n "$note" ]; then
    printf '  %s%s%s' "$C_GRY" "$note" "$C_RST"
  fi
  printf '\n'
}

# ------------------------------------------------------------- сообщения ---
ui_ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
ui_warn() { printf '  %s!%s %s\n' "$C_YLW" "$C_RST" "$*"; }
ui_err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$*"; }
ui_info() { printf '  %s·%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ui_note() { printf '    %s%s%s\n' "$C_GRY" "$*" "$C_RST"; }

# ui_ask <промпт> <дефолт>
ui_ask() {
  local prompt="$1" def="${2:-}" ans
  if [ -n "$def" ]; then
    printf '  %s?%s %s %s[%s]%s\n' "$C_MAG" "$C_RST" "$prompt" "$C_GRY" "$def" "$C_RST" >&2
  else
    printf '  %s?%s %s\n' "$C_MAG" "$C_RST" "$prompt" >&2
  fi
  # Ввод на отдельной строке: Backspace не умеет подниматься на строку выше,
  # поэтому ни приглашение, ни меню стереть нельзя.
  printf '  %s>%s ' "$C_MAG" "$C_RST" >&2
  read -r ans </dev/tty
  ans="${ans:-$def}"
  # Однобуквенный ответ в русской раскладке приводим к латинице по позиции
  # клавиши: пользователь видит «с», жмёт пункт «c» — должно сработать.
  if [ "${#ans}" = 1 ]; then
    case "$ans" in
      й) ans=q ;; ц) ans=w ;; у) ans=e ;; к) ans=r ;; е) ans=t ;; н) ans=y ;;
      г) ans=u ;; ш) ans=i ;; щ) ans=o ;; з) ans=p ;; ф) ans=a ;; ы) ans=s ;;
      в) ans=d ;; а) ans=f ;; п) ans=g ;; р) ans=h ;; о) ans=j ;; л) ans=k ;;
      д) ans=l ;; я) ans=z ;; ч) ans=x ;; с) ans=c ;; м) ans=v ;; и) ans=b ;;
      т) ans=n ;; ь) ans=m ;;
      Й) ans=q ;; Ц) ans=w ;; У) ans=e ;; К) ans=r ;; Е) ans=t ;; Н) ans=y ;;
      Г) ans=u ;; Ш) ans=i ;; Щ) ans=o ;; З) ans=p ;; Ф) ans=a ;; Ы) ans=s ;;
      В) ans=d ;; А) ans=f ;; П) ans=g ;; Р) ans=h ;; О) ans=j ;; Л) ans=k ;;
      Д) ans=l ;; Я) ans=z ;; Ч) ans=x ;; С) ans=c ;; М) ans=v ;; И) ans=b ;;
      Т) ans=n ;; Ь) ans=m ;;
    esac
  fi
  printf '%s' "$ans"
}

# ui_confirm <вопрос> — по умолчанию НЕТ. Для разрушительных операций.
ui_confirm() {
  local ans
  printf '  %s!%s %s %s(y/N)%s ' "$C_YLW" "$C_RST" "$1" "$C_GRY" "$C_RST"
  read -r ans
  case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# спиннер для долгих шагов; переживает отсутствие tty
ui_run() {
  local msg="$1"; shift
  printf '  %s·%s %s … ' "$C_CYN" "$C_RST" "$msg"
  if "$@" >/tmp/packetlab-step.log 2>&1; then
    printf '%s✓%s\n' "$C_GRN" "$C_RST"
    return 0
  else
    printf '%s✗%s\n' "$C_RED" "$C_RST"
    ui_note "лог: /tmp/packetlab-step.log"
    return 1
  fi
}
