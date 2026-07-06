#!/usr/bin/env bash
# Общие функции для скриптов настройки XHTTP + Yandex Cloud CDN

set -euo pipefail

if [ -t 1 ]; then
  C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_RST='\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''
fi

step()  { echo -e "\n${C_BLU}==>${C_RST} $*"; }
ok()    { echo -e "${C_GRN}[OK]${C_RST} $*"; }
warn()  { echo -e "${C_YEL}[!]${C_RST} $*"; }
fail()  { echo -e "${C_RED}[X]${C_RST} $*" >&2; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "Запустите скрипт от root: sudo -i, затем ./$(basename "$0")"
  fi
}

# ask VARNAME "Вопрос" ["значение_по_умолчанию"]
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}"
  local __answer
  if [ -n "$__default" ]; then
    read -r -p "$__prompt [$__default]: " __answer || true
    __answer="${__answer:-$__default}"
  else
    while true; do
      read -r -p "$__prompt: " __answer || true
      [ -n "$__answer" ] && break
      warn "Значение не может быть пустым"
    done
  fi
  printf -v "$__var" '%s' "$__answer"
}

confirm() {
  local __prompt="$1" __answer
  read -r -p "$__prompt [y/N]: " __answer || true
  case "$__answer" in
    y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    fail "Не удалось сгенерировать UUID (нет /proc/sys/kernel/random/uuid)"
  fi
}

is_valid_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# ask_domain VARNAME "Вопрос"
ask_domain() {
  local __var="$1" __prompt="$2" __val
  while true; do
    ask __val "$__prompt"
    if is_valid_domain "$__val"; then
      printf -v "$__var" '%s' "$__val"
      break
    fi
    warn "Похоже, это не домен (пример: sub.example.com). Попробуйте снова."
  done
}
