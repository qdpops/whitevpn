#!/usr/bin/env bash
# Проверка прохождения OPTIONS через Yandex Cloud CDN до Origin.
# Соответствует разделу 8 инструкции. Можно запускать с любой Linux-машины
# (не обязательно с Origin/Exit-сервера) уже после настройки CDN-ресурса.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ask_domain CDN_HOST "CDN-домен (например cdn.example.com)"

step "Запрос OPTIONS через $CDN_HOST"
RESP="$(curl -sS -D - -o /dev/null -X OPTIONS --data-binary 'test' \
  "https://${CDN_HOST}/cdn-check?nocache=$(date +%s)")"

echo "$RESP"
echo

PASS=1
echo "$RESP" | grep -q '204' || { warn "Нет HTTP 204"; PASS=0; }
echo "$RESP" | grep -qi 'X-CDN-Origin: ok' || { warn "Нет заголовка X-CDN-Origin: ok"; PASS=0; }
echo "$RESP" | grep -qi 'X-Origin-Method: OPTIONS' || { warn "Нет заголовка X-Origin-Method: OPTIONS"; PASS=0; }
echo "$RESP" | grep -qi 'X-Origin-Content-Length: 4' || { warn "Нет заголовка X-Origin-Content-Length: 4"; PASS=0; }

if [ "$PASS" -eq 1 ]; then
  ok "CDN -> Origin работает корректно"
else
  echo
  warn "Проверьте по порядку (раздел 8 инструкции):"
  cat <<'EOF'
  1. CNAME CDN-домена:      dig +short CNAME cdn.example.com
  2. Статус CDN-ресурса в консоли Yandex Cloud
  3. Разрешен ли метод OPTIONS в настройках CDN-ресурса
  4. Протокол источника в CDN-ресурсе = HTTPS
  5. Host источника в CDN-ресурсе = ваш origin-домен
  6. Доступность TCP-порта 443 на Origin-сервере
  7. Валидность сертификата Origin-домена
EOF
  exit 1
fi
