#!/usr/bin/env bash
# packetlab — меню цепочки «вход → выход» (中转 → 落地). Вся работа — в relay/plr.sh: тот же файл
# ставится и на серверы без packetlab, поэтому меню только вызывает его.

PL_PLR="$PL_ROOT/relay/plr.sh"
plr() { bash "$PL_PLR" "$@"; }

pl_relay_badge() {
  case "$(plr state)" in on) printf up ;; linked) printf ready ;; *) printf off ;; esac
}

menu_relay() {
  local st ex tok
  while true; do
    st=$(plr state); ex=$(plr exit-state)
    ui_screen "вход → выход" "клиенты → этот сервер → выход; подписка не меняется"

    ui_section "этот сервер как вход"
    case "$st" in
      off)    ui_row "" "выход" off "не связан" ;;
      linked) ui_row "" "$(plr where)" ready "трафик напрямую" ;;
      on)     ui_row "" "$(plr where)" up "трафик через выход" ;;
    esac
    ui_section "этот сервер как выход"
    ui_row "" "relay-in" "$ex" "$([ "$ex" = up ] && printf 'токен: пункт 5')"
    ui_note "каждое изменение перезапускает sing-box — активные соединения оборвутся"

    ui_section ""
    if [ "$st" = off ]; then
      ui_key 1 "связать по токену выхода"
    else
      ui_key 1 "проверить"
      if [ "$st" = on ]; then ui_key 2 "вернуть трафик напрямую"
      else ui_key 2 "пустить трафик через выход"; fi
      ui_key 3 "заменить токен"
      ui_key 4 "отвязать"
    fi
    if [ "$ex" = up ]; then
      ui_key 5 "показать токен выхода"
      ui_key 6 "перестать быть выходом"
    else
      ui_key 5 "стать выходом"
    fi
    ui_key b назад; printf '\n'

    case "$(ui_ask "выбор")" in
      1) if [ "$st" = off ]; then
           tok=$(ui_ask "токен выхода"); [ -n "$tok" ] && plr link "$tok"
         else
           plr test
         fi
         ui_ask "enter" >/dev/null ;;
      2) [ "$st" = off ] && continue
         if [ "$st" = on ]; then plr off
         else ui_confirm "весь трафик клиентов пойдёт через выход. продолжить?" && plr on; fi
         ui_ask "enter" >/dev/null ;;
      3) [ "$st" = off ] && continue
         tok=$(ui_ask "новый токен выхода"); [ -n "$tok" ] && plr link "$tok"
         ui_ask "enter" >/dev/null ;;
      4) [ "$st" = off ] && continue
         ui_confirm "отвязать выход? трафик пойдёт напрямую" && plr unlink
         ui_ask "enter" >/dev/null ;;
      5) plr exit; ui_ask "enter" >/dev/null ;;
      6) [ "$ex" = up ] || continue
         ui_confirm "убрать relay-in? входы с этим токеном перестанут работать" && plr exit --remove
         ui_ask "enter" >/dev/null ;;
      b|B|'') return ;;
    esac
  done
}
