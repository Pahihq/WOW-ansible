# CDN и xHTTP

Этот каталог отвечает за origin-сайты, Cloudflare DNS, VK/Yandex CDN, инбаунды и хосты Remnawave, балансер, Kuma и ротацию. Базовая настройка нод находится в `../ansible/`.

## Inventory и локальные данные

`inventory.yml` — символическая ссылка на `../ansible/inventory.yml`. Изменяйте адреса и группы в `ansible/inventory.yml`. CDN-параметры находятся в местных `group_vars/`; `eu_nodes` является группой кандидатов, а перед раскаткой origin проверяется доступность портов 80 и 443.

Создайте `playbook/secrets/` и заполните нужные файлы: `.env` по `playbook/scripts/.env.example` для Cloudflare/VK/Yandex, `remnawave_token`, `kuma.env`, `telegram.env`. Если ранее использовались `playbook/state/` и секреты в старом корне репозитория, перенесите их сюда до боевой ротации. Состояние ротации необходимо для корректного продолжения и снятия прежних ресурсов. Оба каталога исключены из Git.

Для Kuma нужен Python с `python-socketio[client]` в `.venv/`; для Yandex — настроенный `yc` CLI. Установите коллекции из `requirements.yml`.

## Запуск

Работайте из `CDN/`.

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbook/rotate_cdn.yml --syntax-check
ansible-playbook playbook/rotate_cdn.yml --limit <node> -e cdn_dry_run=true
```

| Плейбук | Действие |
| --- | --- |
| `xhttp_nginx.yml` | Первичная настройка origin-сайта; при `xhttp_cdn_setup_enabled=true` также создаёт CDN и DNS. |
| `rotate_cdn.yml` | Полная ротация CDN-плеча: origin, DNS, провайдер, панель, балансер и Kuma. |
| `panel_sync.yml`, `kuma_sync.yml` | Синхронизация панели и мониторов с текущим состоянием. |
| `profile_inbounds_sync.yml`, `squads_grant_slots.yml` | Подготовка CDN-инбаундов и слотов сквадов. |
| `rotate_cleanup.yml`, `cdn_teardown.yml`, `node_inbounds_cleanup.yml` | Очистка и удаление ресурсов; проверьте предпросмотр перед `apply=true`. |
| `rotate_yandex_cdn.yml` | Точечное пересоздание Yandex CDN. |

`playbook/scripts/cdn_watchdog.py` вычисляет пути относительно этого каталога. При переносе существующего systemd-таймера сторожа обновите его путь к скрипту на новый. Плейбуки не запускаются автоматически при раскладке файлов.
