#!/usr/bin/env bash
# Настройка ORIGIN-СЕРВЕРА (Nginx + Xray, XHTTP).
# Соответствует разделу 3 Yandex_CDN_XHTTP_универсальная_инструкция.txt
#
# Запуск на Origin-сервере (Ubuntu 22.04):
#   sudo -i
#   ./02-setup-origin-server.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

echo "============================================================"
echo " Настройка ORIGIN-СЕРВЕРА (Nginx + Xray, XHTTP)"
echo "============================================================"

ask_domain ORIGIN_HOST "Origin-домен (например origin.example.com)"
ask_domain CDN_HOST "CDN-домен для клиентов (например cdn.example.com)"
ask_domain RELAY_HOST "Relay/Exit-домен (например relay.example.com)"
ask RELAY_IP "IP Exit-сервера"
ask UUID "Единый UUID (тот же, что задавали на Exit-сервере)"
ask EMAIL "Email для Let's Encrypt"
ask XHTTP_PATH "Путь XHTTP" "/api-test"
ask PADDING_KEY "Ключ padding" "dc"
ask XRAY_VERSION "Версия Xray-core" "26.5.9"

echo
echo "Проверьте значения:"
printf '  ORIGIN_HOST  = %s\n' "$ORIGIN_HOST"
printf '  CDN_HOST     = %s\n' "$CDN_HOST"
printf '  RELAY_HOST   = %s\n' "$RELAY_HOST"
printf '  RELAY_IP     = %s\n' "$RELAY_IP"
printf '  UUID         = %s\n' "$UUID"
printf '  EMAIL        = %s\n' "$EMAIL"
printf '  XHTTP_PATH   = %s\n' "$XHTTP_PATH"
printf '  PADDING_KEY  = %s\n' "$PADDING_KEY"
printf '  XRAY_VERSION = %s\n' "$XRAY_VERSION"
echo
confirm "Продолжить установку с этими значениями?" || fail "Отменено пользователем"

step "Установка nginx, certbot, curl"
apt update
apt install -y nginx certbot curl

step "Установка Xray-core $XRAY_VERSION"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$XRAY_VERSION"

step "Временный HTTP-конфиг для выпуска сертификата"
install -d -m 755 /var/www/acme
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/xhttp-origin.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ORIGIN_HOST};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        default_type text/plain;
        return 200 "origin is ready\n";
    }
}
EOF

ln -sfn /etc/nginx/sites-available/xhttp-origin.conf /etc/nginx/sites-enabled/xhttp-origin.conf
nginx -t
systemctl enable --now nginx
systemctl reload nginx

step "Выпуск сертификата для $ORIGIN_HOST"
certbot certonly --webroot -w /var/www/acme --non-interactive --agree-tos --email "$EMAIL" -d "$ORIGIN_HOST"

step "Запись конфигурации Xray"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "from-yandex-cdn",
      "listen": "127.0.0.1",
      "port": 8003,
      "protocol": "vless",
      "settings": {
        "users": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "${XHTTP_PATH}",
          "xPaddingObfsMode": true,
          "xPaddingKey": "${PADDING_KEY}",
          "xPaddingHeader": "X-Cache",
          "xPaddingMethod": "tokenish",
          "xPaddingPlacement": "queryInHeader"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "to-exit",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${RELAY_IP}",
            "port": 10443,
            "users": [
              {
                "id": "${UUID}",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${RELAY_HOST}",
          "alpn": ["h2", "http/1.1"]
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF

step "Проверка конфигурации Xray"
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json

step "Запуск Xray"
systemctl enable xray
systemctl restart xray
systemctl --no-pager --full status xray || true
ss -lntp | grep ':8003' || warn "Xray не слушает 127.0.0.1:8003 — проверьте статус выше"

step "Map OPTIONS -> POST"
cat > /etc/nginx/conf.d/xhttp-method.conf <<'EOF'
map $request_method $xhttp_proxy_method {
    default  $request_method;
    OPTIONS  POST;
}
EOF

step "Финальная конфигурация Nginx (HTTPS + проксирование XHTTP)"
cat > /etc/nginx/sites-available/xhttp-origin.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ORIGIN_HOST};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${ORIGIN_HOST};

    ssl_certificate     /etc/letsencrypt/live/${ORIGIN_HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${ORIGIN_HOST}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 0;
    client_header_buffer_size 64k;
    large_client_header_buffers 8 128k;
    http2_max_field_size 128k;
    http2_max_header_size 128k;

    location = /cdn-check {
        add_header X-CDN-Origin "ok" always;
        add_header X-Origin-Method \$request_method always;
        add_header X-Origin-Content-Length \$http_content_length always;
        return 204;
    }

    location ${XHTTP_PATH} {
        proxy_pass http://127.0.0.1:8003;
        proxy_method \$xhttp_proxy_method;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        proxy_pass_request_headers on;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

nginx -t
systemctl reload nginx
systemctl --no-pager --full status nginx || true

step "Хук перезагрузки nginx после продления сертификата"
install -d /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

step "Самопроверка /cdn-check напрямую на Origin"
sleep 1
RESP="$(curl -sS -D - -o /dev/null -X OPTIONS --data-binary 'test' "https://${ORIGIN_HOST}/cdn-check" || true)"
echo "$RESP"
if echo "$RESP" | grep -q '204' && echo "$RESP" | grep -qi 'X-CDN-Origin: ok'; then
  ok "Origin отвечает как ожидается (204, X-CDN-Origin: ok)"
else
  warn "Ответ не соответствует ожидаемому — проверьте вывод выше"
fi

echo
ok "Origin-сервер настроен."
echo "Сохраните для следующих шагов (Certificate Manager / CDN-ресурс в Yandex Cloud):"
printf '  ORIGIN_HOST = %s\n' "$ORIGIN_HOST"
printf '  CDN_HOST    = %s\n' "$CDN_HOST"
printf '  XHTTP_PATH  = %s\n' "$XHTTP_PATH"
printf '  PADDING_KEY = %s\n' "$PADDING_KEY"

echo
warn "Firewall: разрешите входящие SSH, 80 и 443. Порт 8003 наружу не открывайте."
echo
echo "Дальше — настройка в консоли Yandex Cloud (Certificate Manager + CDN-ресурс + DNS):"
echo "  см. docs/05-yandex-cloud-checklist.md"
