#!/usr/bin/env bash
# Управление пользователями (UUID) VLESS-инбаунда на Origin-сервере + выдача
# готового клиентского профиля. Позволяет выдавать отдельный доступ каждому
# устройству/человеку без расшаривания одного UUID на всех.
#
# Запуск на Origin-сервере (там же, где /usr/local/etc/xray/config.json):
#   sudo -i
#   ./05-manage-vless-users.sh            — интерактивное меню
#   ./05-manage-vless-users.sh add <метка>
#   ./05-manage-vless-users.sh list
#   ./05-manage-vless-users.sh remove <метка|uuid>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

CONFIG="/usr/local/etc/xray/config.json"
INBOUND_TAG="from-yandex-cdn"
DEFAULTS_FILE="/usr/local/etc/xray/client-defaults.env"

[ -f "$CONFIG" ] || fail "Не найден $CONFIG — сначала запустите 02-setup-origin-server.sh"

# --- параметры транспорта (общие для всех пользователей), с запоминанием ---

load_defaults() {
  CDN_HOST=""; XHTTP_PATH="/api-test"; PADDING_KEY="dc"
  if [ -f "$DEFAULTS_FILE" ]; then
    # shellcheck disable=SC1090
    source "$DEFAULTS_FILE"
  fi
}

save_defaults() {
  cat > "$DEFAULTS_FILE" <<EOF
CDN_HOST="$CDN_HOST"
XHTTP_PATH="$XHTTP_PATH"
PADDING_KEY="$PADDING_KEY"
EOF
}

ask_transport_defaults() {
  load_defaults
  while true; do
    if [ -n "$CDN_HOST" ]; then
      ask CDN_HOST "CDN-домен для клиентов" "$CDN_HOST"
    else
      ask CDN_HOST "CDN-домен для клиентов (например cdn.example.com)"
    fi
    if is_valid_domain "$CDN_HOST"; then
      break
    fi
    warn "Похоже, это не домен (пример: sub.example.com). Попробуйте снова."
  done
  ask XHTTP_PATH "Путь XHTTP" "$XHTTP_PATH"
  ask PADDING_KEY "Ключ padding" "$PADDING_KEY"
  save_defaults
}

urlencode() {
  local s="$1" out="" c i hex
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

print_padding_json() {
  # Однострочный (minified) JSON: многие клиенты (HAPP, V2RayTun) держат поле
  # "XHTTP extra / Raw JSON" как однострочное, и при вставке из терминала
  # многострочный JSON с отступами обрывается/ломается по переносам строк,
  # из-за чего клиент выдаёт ошибку парсинга JSON.
  printf '{"mode":"packet-up","scMaxEachPostBytes":1000000,"scMinPostsIntervalMs":30,"scMaxBufferedPosts":30,"xPaddingObfsMode":true,"xPaddingKey":"%s","xPaddingHeader":"X-Cache","xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","uplinkHTTPMethod":"OPTIONS"}\n' "$PADDING_KEY"
}

print_client_link() {
  local uuid="$1" label="$2"
  local enc_path enc_remark uri
  enc_path="$(urlencode "$XHTTP_PATH")"
  enc_remark="$(urlencode "${label:-$CDN_HOST}")"
  uri="vless://${uuid}@${CDN_HOST}:443?encryption=none&security=tls&sni=${CDN_HOST}&host=${CDN_HOST}&type=xhttp&path=${enc_path}#${enc_remark}"
  echo "$uri"
}

# --- работа с config.json ---

py_list_users() {
  python3 - "$CONFIG" "$INBOUND_TAG" <<'PYEOF'
import json, sys
path, tag = sys.argv[1:3]
with open(path) as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    if inbound.get("tag") == tag:
        for u in inbound["settings"]["users"]:
            print(f"{u.get('id')}\t{u.get('email', '')}")
        break
else:
    sys.exit(f"Инбаунд с tag={tag} не найден")
PYEOF
}

py_add_user() {
  local uuid="$1" label="$2"
  python3 - "$CONFIG" "$INBOUND_TAG" "$uuid" "$label" <<'PYEOF'
import json, sys
path, tag, uuid, label = sys.argv[1:5]
with open(path) as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    if inbound.get("tag") == tag:
        users = inbound["settings"]["users"]
        if any(u.get("id") == uuid for u in users):
            sys.exit("UUID уже существует")
        if label and any(u.get("email") == label for u in users):
            sys.exit(f"Метка '{label}' уже используется")
        users.append({"id": uuid, "email": label})
        break
else:
    sys.exit(f"Инбаунд с tag={tag} не найден")
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF
}

py_remove_user() {
  local target="$1"
  python3 - "$CONFIG" "$INBOUND_TAG" "$target" <<'PYEOF'
import json, sys
path, tag, target = sys.argv[1:4]
with open(path) as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    if inbound.get("tag") == tag:
        users = inbound["settings"]["users"]
        before = len(users)
        users[:] = [u for u in users if u.get("id") != target and u.get("email") != target]
        if len(users) == before:
            sys.exit(f"Пользователь '{target}' не найден")
        if not users:
            sys.exit("Отмена: нельзя удалить последнего пользователя")
        break
else:
    sys.exit(f"Инбаунд с tag={tag} не найден")
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF
}

reload_xray() {
  step "Проверка конфигурации"
  /usr/local/bin/xray run -test -config "$CONFIG"
  step "Перезапуск Xray"
  systemctl restart xray
}

# --- действия ---

action_add() {
  local label="${1:-}"
  [ -n "$label" ] || ask label "Метка пользователя (для учёта, например имя/устройство)"
  local uuid
  uuid="$(gen_uuid)"

  step "Добавление пользователя '$label' ($uuid)"
  py_add_user "$uuid" "$label"
  reload_xray
  ok "Пользователь добавлен."

  ask_transport_defaults
  echo
  echo "=== Профиль для '$label' ==="
  print_client_link "$uuid" "$label"
  echo
  warn "Вставьте в клиент JSON padding (поле 'XHTTP extra / Raw JSON'):"
  print_padding_json
}

action_list() {
  local users
  users="$(py_list_users)"
  [ -n "$users" ] || { warn "Пользователей нет"; return; }

  local has_defaults=0
  load_defaults
  if [ -n "$CDN_HOST" ]; then has_defaults=1; fi

  echo
  echo "=== Пользователи ==="
  local i=0
  while IFS=$'\t' read -r uuid label; do
    i=$((i+1))
    echo "$i) ${label:-(без метки)}  —  $uuid"
    if [ "$has_defaults" -eq 1 ]; then
      echo "   $(print_client_link "$uuid" "$label")"
    fi
  done <<< "$users"

  if [ "$has_defaults" -eq 1 ]; then
    echo
    warn "JSON padding (общий для всех, вставляется в клиент отдельно):"
    print_padding_json
  else
    echo
    warn "CDN-домен ещё не задан — ссылки не показаны. Выберите в меню 'Добавить'"
    warn "хотя бы раз, чтобы задать CDN_HOST/XHTTP_PATH/PADDING_KEY, либо задайте"
    warn "их вручную в $DEFAULTS_FILE"
  fi
}

action_remove() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    local users
    users="$(py_list_users)"
    [ -n "$users" ] || { warn "Пользователей нет"; return; }

    echo
    echo "=== Кого удалить? ==="
    local i=0
    local uuids=() labels=()
    while IFS=$'\t' read -r uuid label; do
      i=$((i+1))
      uuids+=("$uuid"); labels+=("$label")
      echo "$i) ${label:-(без метки)}  —  $uuid"
    done <<< "$users"

    ask CHOICE "Номер пользователя для удаления"
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$i" ]; then
      fail "Неверный номер"
    fi
    target="${uuids[$((CHOICE-1))]}"
    confirm "Удалить '${labels[$((CHOICE-1))]:-$target}'?" || { warn "Отменено"; return; }
  fi

  step "Удаление '$target'"
  py_remove_user "$target"
  reload_xray
  ok "Пользователь удалён."
}

menu() {
  while true; do
    echo
    echo "============================================================"
    echo " Управление пользователями VLESS ($CONFIG)"
    echo "============================================================"
    echo "1) Добавить пользователя (метка -> UUID -> готовый профиль)"
    echo "2) Показать пользователей и их профили"
    echo "3) Удалить пользователя"
    echo "0) Выход"
    ask CHOICE "Выберите действие"
    case "$CHOICE" in
      1) action_add ;;
      2) action_list ;;
      3) action_remove ;;
      0) exit 0 ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}

# --- точка входа ---

if [ $# -eq 0 ]; then
  menu
fi

ACTION="$1"; shift || true
case "$ACTION" in
  add)    action_add "${1:-}" ;;
  list)   action_list ;;
  remove) action_remove "${1:-}" ;;
  *)
    cat <<EOF
Использование:
  $(basename "$0")                     — интерактивное меню
  $(basename "$0") add <метка>         — создать нового пользователя
  $(basename "$0") list                — показать всех пользователей
  $(basename "$0") remove <метка|uuid> — удалить пользователя
EOF
    exit 1
    ;;
esac
