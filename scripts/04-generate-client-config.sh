#!/usr/bin/env bash
# Генератор клиентского профиля VLESS (XHTTP + padding) для Happ / v2rayNG.
# Соответствует разделу 9 инструкции.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ask_domain CDN_HOST "CDN-домен (например cdn.example.com)"
ask UUID "Единый UUID"
ask XHTTP_PATH "Путь XHTTP" "/api-test"
ask PADDING_KEY "Ключ padding" "dc"
ask REMARK "Название профиля (remark)" "$CDN_HOST"

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

ENC_PATH="$(urlencode "$XHTTP_PATH")"
ENC_REMARK="$(urlencode "$REMARK")"

VLESS_URI="vless://${UUID}@${CDN_HOST}:443?encryption=none&security=tls&sni=${CDN_HOST}&host=${CDN_HOST}&type=xhttp&path=${ENC_PATH}#${ENC_REMARK}"

echo
echo "=== Ссылка профиля (базовые параметры транспорта/TLS) ==="
echo "$VLESS_URI"
echo
warn "Не все клиенты читают параметры padding из ссылки. После импорта профиля"
warn "вставьте JSON ниже в поле 'XHTTP extra / Raw JSON':"
echo
# Однострочный (minified) JSON: многие клиенты (HAPP, V2RayTun) держат поле
# "XHTTP extra / Raw JSON" как однострочное, и при вставке из терминала
# многострочный JSON с отступами обрывается/ломается по переносам строк,
# из-за чего клиент выдаёт ошибку парсинга JSON.
printf '{"mode":"packet-up","scMaxEachPostBytes":1000000,"scMinPostsIntervalMs":30,"scMaxBufferedPosts":30,"xPaddingObfsMode":true,"xPaddingKey":"%s","xPaddingHeader":"X-Cache","xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","uplinkHTTPMethod":"OPTIONS"}\n' "$PADDING_KEY"
echo
echo "Проверьте вручную в клиенте: Allow insecure = выключено, Address/SNI/Host = ${CDN_HOST}"
