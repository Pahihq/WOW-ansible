# Обычная настройка нод

Этот каталог отвечает за ОС, Docker, RemnaNode, UFW, мониторинг и отчётность. CDN-ресурсы и xHTTP-origin находятся в соседнем каталоге `../CDN/`.

## Подготовка

Работайте из `ansible/`. Рабочий inventory — `inventory.yml`; он также используется CDN через символическую ссылку. Для новой установки скопируйте `inventory.yml.example` в `inventory.yml` и заполните адреса. Установите коллекции из `requirements.yml`.

Секреты кладутся в `playbook/secrets/` и не коммитятся: `remnawave_token`, `root_authorized_keys.pub`, `vmagent.yml`, `google_sheet_id`, `google_credentials.json`. При первой установке RemnaNode получает `SECRET_KEY` через API панели и сохраняет его на ноде в `/opt/remnanode/.secret_key`; при повторных запусках использует сохранённый ключ. Настройки IP панелей для UFW задаются в локальном `group_vars/docker_nodes.yml` по образцу `group_vars/docker_nodes.yml.example`.

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbook/site.yml --syntax-check
ansible-playbook playbook/ufw.yml --limit <node> --check --diff
```

`--check` не моделирует все действия Docker и shell; перед боевым запуском проверьте порт API и текущий Compose-файл конкретной ноды. `playbook/remnanode.yml` создаёт Compose-файл по шаблону и может изменить уже настроенный `NODE_PORT`.

## Плейбуки

| Плейбук | Действие |
| --- | --- |
| `site.yml` | Последовательно запускает bootstrap, RemnaNode, UFW, регистрацию нод в Remnawave, monitoring и reporting. |
| `bootstrap.yml` | Подготовка ОС, Docker, SSH, zsh, swap и sysctl. |
| `remnanode.yml`, `update_remnanode.yml` | Установка и обновление RemnaNode. |
| `remnawave_nodes.yml` | Регистрация и синхронизация обычных нод с панелью Remnawave. |
| `ufw.yml` | Firewall и доступ панели к API ноды. |
| `monitoring.yml`, `reporting.yml` | Метрики и отчёт в Google Sheets. |
| `multitest.yml`, `torrent-block.yml` | Нагрузочная диагностика и блокировка торрентов. |

Запускайте плейбуки из этого каталога и сначала ограничивайте выполнение одной нодой через `--limit`.
