#!/usr/bin/env bash
# Настройка EXIT-СЕРВЕРА (Xray + TLS, порт 10443).
# Соответствует разделу 2 Yandex_CDN_XHTTP_универсальная_инструкция.txt
#
# Запуск на Exit-сервере (Ubuntu 22.04):
#   sudo -i
#   ./01-setup-exit-server.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

echo "============================================================"
echo " Настройка EXIT-СЕРВЕРА (Xray, TLS, порт 10443)"
echo "============================================================"

ask_domain RELAY_HOST "Relay/Exit-домен (например relay.example.com)"
ask EMAIL "Email для Let's Encrypt"

if confirm "Сгенерировать новый UUID автоматически?"; then
  UUID="$(gen_uuid)"
  ok "Сгенерирован UUID: $UUID"
else
  ask UUID "Вставьте единый UUID (тот же будет использован на Origin-сервере)"
fi

ask XRAY_VERSION "Версия Xray-core" "26.5.9"

echo
echo "Проверьте значения:"
printf '  RELAY_HOST   = %s\n' "$RELAY_HOST"
printf '  EMAIL        = %s\n' "$EMAIL"
printf '  UUID         = %s\n' "$UUID"
printf '  XRAY_VERSION = %s\n' "$XRAY_VERSION"
echo
confirm "Продолжить установку с этими значениями?" || fail "Отменено пользователем"

step "Установка curl и certbot"
apt update
apt install -y curl certbot

step "Установка Xray-core $XRAY_VERSION"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$XRAY_VERSION"

step "Проверка порта 80 (нужен для выпуска сертификата)"
if ss -lntp | grep -q ':80 '; then
  warn "Порт 80 уже занят. certbot --standalone не сможет запуститься."
  confirm "Продолжить всё равно?" || fail "Освободите порт 80 и запустите скрипт снова"
fi

step "Выпуск сертификата для $RELAY_HOST"
certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$RELAY_HOST"

step "Копирование сертификата для Xray (доступ для группы nogroup)"
install -d -m 750 -o root -g nogroup /usr/local/etc/xray/tls
install -m 640 -o root -g nogroup "/etc/letsencrypt/live/${RELAY_HOST}/fullchain.pem" /usr/local/etc/xray/tls/fullchain.pem
install -m 640 -o root -g nogroup "/etc/letsencrypt/live/${RELAY_HOST}/privkey.pem" /usr/local/etc/xray/tls/privkey.pem

step "Запись конфигурации Xray"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "from-origin",
      "listen": "0.0.0.0",
      "port": 10443,
      "protocol": "vless",
      "settings": {
        "users": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h2", "http/1.1"],
          "certificates": [
            {
              "certificateFile": "/usr/local/etc/xray/tls/fullchain.pem",
              "keyFile": "/usr/local/etc/xray/tls/privkey.pem"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "internet",
      "protocol": "freedom"
    }
  ]
}
EOF

step "Проверка конфигурации"
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json

step "Запуск Xray"
systemctl enable xray
systemctl restart xray
systemctl --no-pager --full status xray || true

step "Хук перевыпуска сертификата (копирование + restart xray)"
install -d /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/restart-xray.sh <<'EOF'
#!/bin/sh
set -eu
install -m 640 -o root -g nogroup "${RENEWED_LINEAGE}/fullchain.pem" /usr/local/etc/xray/tls/fullchain.pem
install -m 640 -o root -g nogroup "${RENEWED_LINEAGE}/privkey.pem" /usr/local/etc/xray/tls/privkey.pem
systemctl restart xray
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/restart-xray.sh

step "Проверка порта 10443"
ss -lntp | grep ':10443' || warn "Порт 10443 не найден в списке — проверьте статус xray выше"

echo
ok "Exit-сервер настроен."
echo "Сохраните эти значения — они понадобятся при настройке Origin-сервера:"
printf '  RELAY_HOST = %s\n' "$RELAY_HOST"
printf '  UUID       = %s\n' "$UUID"

echo
warn "Firewall: разрешите входящие SSH, 80 (выпуск/продление сертификата) и 10443."
warn "Рекомендуется ограничить 10443 только IP Origin-сервера, например:"
echo "  ufw allow from <IP_ORIGIN_СЕРВЕРА> to any port 10443 proto tcp"
if confirm "Есть IP Origin-сервера и хотите добавить это правило ufw сейчас? (ufw НЕ будет включаться)"; then
  ask ORIGIN_IP "IP Origin-сервера"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow from "$ORIGIN_IP" to any port 10443 proto tcp
    ok "Правило добавлено. ufw enable нужно выполнить отдельно, предварительно разрешив SSH-порт."
  else
    warn "ufw не установлен — добавьте правило вашим firewall-инструментом вручную."
  fi
fi
