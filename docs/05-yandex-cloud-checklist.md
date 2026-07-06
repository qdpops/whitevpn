# Чек-лист: DNS + Yandex Cloud (Certificate Manager + CDN)

Эти шаги выполняются в веб-панели вашего DNS-регистратора и в консоли Yandex
Cloud, поэтому не автоматизированы скриптом. Отмечайте по мере выполнения.
Соответствие разделам `Yandex_CDN_XHTTP_универсальная_инструкция.txt` указано
в скобках.

Перед началом подготовьте:

- [ ] `ORIGIN_HOST` (например `origin.example.com`)
- [ ] `CDN_HOST` (например `cdn.example.com`)
- [ ] `RELAY_HOST` (например `relay.example.com`)
- [ ] IP Origin-сервера и IP Exit-сервера

## 1. DNS до настройки серверов (раздел 1)

- [ ] Создана A-запись `origin` -> IP Origin-сервера
- [ ] Создана A-запись `relay` -> IP Exit-сервера
- [ ] Проверено: `getent ahostsv4 origin.example.com`
- [ ] Проверено: `getent ahostsv4 relay.example.com`
- [ ] CDN-запись пока НЕ создана (её значение выдаст Yandex Cloud CDN на шаге 3)

Дальше запустите `scripts/01-setup-exit-server.sh` на Exit-сервере и
`scripts/02-setup-origin-server.sh` на Origin-сервере.

## 2. Сертификат для CDN-домена в Certificate Manager (раздел 4)

Этот сертификат — между клиентом и Yandex Cloud CDN. Он не тот, что
получает certbot на Origin.

- [ ] Открыт нужный каталог Yandex Cloud (тот же, где будет CDN-ресурс)
- [ ] Certificate Manager -> «Добавить сертификат» -> «Сертификат от Let's Encrypt»
- [ ] Имя: любое понятное (например `xhttp-cdn-cert`)
- [ ] Домены: только `CDN_HOST` (например `cdn.example.com`)
- [ ] Тип проверки прав: DNS (предпочтительно DNS_CNAME — для автопродления)
- [ ] Скопирована запись проверки прав из Certificate Manager
- [ ] В DNS-панели создана ровно та запись (CNAME/TXT), которую показал Certificate Manager
- [ ] У `_acme-challenge` нет одновременно TXT и второго CNAME (иначе выпуск не пройдёт)
- [ ] Дождались статуса сертификата «Issued» / «Выпущен»

## 3. Создание CDN-ресурса (раздел 5)

Cloud CDN -> CDN-ресурсы -> «Создать ресурс».

Основные настройки / Контент:

- [ ] «Доступ конечных пользователей к контенту» включён
- [ ] «Запрос контента» = «Из одного источника»
- [ ] «Тип источника» = «Сервер»
- [ ] «Доменное имя источника» = `ORIGIN_HOST`
- [ ] «Протокол для запросов к источнику» = HTTPS
- [ ] «Доменное имя» (для клиентов) = `CDN_HOST`

Дополнительные настройки:

- [ ] «Перенаправление клиентов» = «Не использовать» (пока — включим на шаге 6)
- [ ] «Тип сертификата» = «Использовать из Certificate Manager»
- [ ] Выбран сертификат для `CDN_HOST` со статусом «Выпущен»
- [ ] «Заголовок Host» = «Своё значение» = `ORIGIN_HOST` (обязательно!)

Кеширование:

- [ ] «Кеширование на CDN» выключено
- [ ] «Кеширование в браузере» выключено
- [ ] Игнорирование query-параметров НЕ включено
- [ ] Игнорирование Cookie НЕ включено

HTTP-заголовки и методы:

- [ ] Разрешённые методы: GET, HEAD, OPTIONS (POST/PUT/PATCH/DELETE не нужны)
- [ ] Нет правил, удаляющих/заменяющих заголовок `X-Cache`
- [ ] CORS отдельно не включён

Расширенные настройки:

- [ ] Сжатие выключено
- [ ] Сегментация контента выключена
- [ ] Origin shielding выключен
- [ ] Следование редиректам источника выключено
- [ ] WebSocket не требуется

- [ ] Ресурс создан, дождались применения настроек (до ~15 минут)

## 4. CNAME для CDN-домена (раздел 6)

- [ ] Открыт CDN-ресурс -> вкладка «Обзор» -> «Настройки DNS»
- [ ] Скопировано служебное имя вида `СЛУЧАЙНЫЙ_ID.topology.gslb.yccdn.ru`
- [ ] В DNS-панели создана запись: CNAME `cdn` -> `СЛУЧАЙНЫЙ_ID.topology.gslb.yccdn.ru.`
      (не ANAME; точку в конце ставить только если панель сама её не добавляет)
- [ ] Проверено: `getent hosts cdn.example.com` (или `dig +short CNAME cdn.example.com`)

## 5. Включение HTTP -> HTTPS (раздел 7)

Только после того как сертификат подключён и CNAME работает:

- [ ] CDN-ресурс -> изменить -> «Перенаправление клиентов» = «С HTTP на HTTPS»
- [ ] Сохранено, подождали применения (до ~15 минут)

## 6. Проверка (раздел 8)

- [ ] Запущен `scripts/03-verify-cdn.sh` и получен ожидаемый ответ
      (204, `X-CDN-Origin: ok`, `X-Origin-Method: OPTIONS`, `X-Origin-Content-Length: 4`)

Если запрос не проходит — по порядку:

1. CNAME CDN-домена
2. Статус CDN-ресурса
3. Разрешён ли метод OPTIONS
4. Протокол источника = HTTPS
5. Host источника = `ORIGIN_HOST`
6. Доступность TCP 443 на Origin
7. Сертификат Origin-домена

## 7. Клиентский профиль (раздел 9)

- [ ] Сгенерирован профиль: `scripts/04-generate-client-config.sh`
- [ ] Импортирован в Happ/v2rayNG, вставлен JSON padding в «XHTTP extra / Raw JSON»
- [ ] Address/SNI/Host клиента = `CDN_HOST` (не origin- и не `*.yccdn.ru`)
- [ ] Allow insecure выключено

## 8. Финальная проверка серверов (раздел 10)

На Origin-сервере:

```
systemctl is-active nginx xray
nginx -t
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
certbot certificates
```

На Exit-сервере:

```
systemctl is-active xray
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
certbot certificates
```

## Типовые ошибки (раздел 11)

| Симптом | Причина | Решение |
|---|---|---|
| 405 Method Not Allowed | OPTIONS не разрешён в CDN-ресурсе | Разрешить OPTIONS в «HTTP-заголовки и методы» |
| 502 / 504 от CDN | CDN не может достучаться до Origin | Проверить HTTPS источника, Host, DNS, firewall, nginx, сертификат Origin |
| Ошибка TLS на клиенте | Address/SNI/Host клиента не совпадают с CDN-доменом сертификата | Выставить все три в `CDN_HOST`, Allow insecure выключить |
| Ошибка TLS между Origin и Exit | Неверный RELAY_IP/RELAY_HOST, сертификат Relay или порт 10443 | Проверить все четыре |
| Xray не запускается | Ошибка конфигурации | `xray run -test -config ...`, `journalctl -u xray -n 100` |
| Nginx не запускается | Ошибка конфигурации | `nginx -t`, `journalctl -u nginx -n 100` |
| 400 / 414 на Origin | Урезаны буферы заголовков Nginx | Проверить `client_header_buffer_size`, `large_client_header_buffers`, `http2_max_field_size`, `http2_max_header_size` |
| Сертификат Certificate Manager не выпускается | Конфликт `_acme-challenge` | Убрать лишний TXT/CNAME у `_acme-challenge` |
