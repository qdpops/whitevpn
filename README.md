# XHTTP + Padding через Yandex Cloud CDN — деплой

Автоматизация настройки из `Yandex_CDN_XHTTP_универсальная_инструкция.txt`.
Серверные шаги (Exit, Origin) выполняются интерактивными bash-скриптами.
Шаги в веб-панелях (DNS-регистратор, Yandex Certificate Manager, Yandex Cloud
CDN) вынесены в чек-лист, так как это UI-действия, а не команды.

Архитектура:

```
Клиент -> Yandex Cloud CDN -> Origin-сервер (Nginx + Xray) -> Exit-сервер (Xray) -> Интернет
```

## Порядок действий

1. **DNS (раздел 1)** — создать A-записи `origin` и `relay` на IP серверов.
   См. `docs/05-yandex-cloud-checklist.md`, пункт 1.

2. **Exit-сервер** — по SSH зайти на Exit-сервер (Ubuntu 22.04), скопировать
   папку `scripts/` и выполнить:

   ```
   sudo -i
   ./01-setup-exit-server.sh
   ```

   Скрипт спросит `RELAY_HOST`, email для Let's Encrypt, предложит
   сгенерировать UUID (сохраните его — он нужен на Origin-сервере).

3. **Origin-сервер** — по SSH зайти на Origin-сервер, скопировать `scripts/`
   и выполнить:

   ```
   sudo -i
   ./02-setup-origin-server.sh
   ```

   Спросит `ORIGIN_HOST`, `CDN_HOST`, `RELAY_HOST`, IP Exit-сервера, тот же
   UUID, email, путь XHTTP и ключ padding (по умолчанию `/api-test` и `dc`).

4. **Yandex Cloud (Certificate Manager + CDN-ресурс + CNAME + редирект)** —
   выполнить по пунктам `docs/05-yandex-cloud-checklist.md` (разделы 4–7
   исходной инструкции). Это единственная часть, которую нужно делать в
   консоли Yandex Cloud вручную.

5. **Проверка** — с любой Linux-машины:

   ```
   ./scripts/03-verify-cdn.sh
   ```

   Проверяет прохождение OPTIONS через CDN до Origin (раздел 8).

6. **Клиентский профиль** — сгенерировать VLESS-ссылку и JSON для
   Happ/v2rayNG:

   ```
   ./scripts/04-generate-client-config.sh
   ```

## Файлы

- `scripts/lib/common.sh` — общие функции (ask/confirm/gen_uuid/валидация домена)
- `scripts/01-setup-exit-server.sh` — раздел 2 инструкции
- `scripts/02-setup-origin-server.sh` — раздел 3 инструкции
- `scripts/03-verify-cdn.sh` — раздел 8 инструкции
- `scripts/04-generate-client-config.sh` — раздел 9 инструкции
- `docs/05-yandex-cloud-checklist.md` — разделы 1, 4–7, 10, 11 инструкции

## Важно

- Скрипты 01/02 идемпотентны частично: их можно перезапускать, но они
  перезаписывают `config.json` и конфиги nginx каждый раз с введёнными
  значениями.
- UUID должен быть **одинаковым** на Exit- и Origin-серверах.
- Порт 8003 на Origin и открытие 10443 на Exit наружу — только с IP
  Origin-сервера (скрипты не включают `ufw enable` автоматически, чтобы не
  заблокировать SSH-доступ; правило `ufw allow` можно добавить по запросу
  скрипта).
