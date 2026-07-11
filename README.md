# WOW-ansible

Основная точка входа:

```bash
ansible-playbook -i inventory.yml playbook/site.yml
```

Порядок выполнения:

- `playbook/bootstrap.yml` - обновляет хосты, затем настраивает zsh и SSH-доступ.
- `playbook/remnanode.yml` - подготавливает RemnaNode-хост, затем настраивает nginx, TLS и файлы сайта.
- `playbook/monitoring.yml` - устанавливает cAdvisor, node_exporter, vmagent и метрики speedtest.
- `playbook/reporting.yml` - собирает данные inventory/speedtest и обновляет Google Sheets.

Используй `inventory.yml.example` как шаблон для локального `inventory.yml`.

Запуск полного Multitest на всех хостах:

```bash
ansible-playbook -i inventory.yml playbook/multitest.yml
```

На каждом сервере отчёт сохраняется в `/var/log/multitest/<inventory_hostname>.txt`.
Копии отчётов Ansible забирает на управляющую машину в
`reports/multitest/<inventory_hostname>.txt`. Для запуска только на части хостов
используй, например, `--limit docker_nodes` или `--limit node_ru1`.

## UFW

Playbook `playbook/ufw.yml` настраивает firewall на хостах группы
`docker_nodes`. Он сохраняет доступ к обнаруженному SSH-порту, открывает
клиентские порты VPN, а `NODE_PORT` разрешает только с IP-адресов панелей.

Перед первым запуском создай локальный файл переменных и укажи реальные IP
Remnawave-панелей:

```bash
cp group_vars/docker_nodes.yml.example group_vars/docker_nodes.yml
```

```yaml
ufw_panel_ips:
  - "198.51.100.10"
  - "198.51.100.11"
```

Запуск на всех VPN-нодах:

```bash
ansible-playbook -i inventory.yml playbook/ufw.yml
```

Для проверки одной ноды используй ограничение:

```bash
ansible-playbook -i inventory.yml playbook/ufw.yml --limit node_ru1
```

Дополнительные клиентские порты можно задать для конкретного хоста в
`inventory.yml`; они добавляются к стандартному профилю:

```yaml
ufw_client_ports_override:
  - 1080
```

Ноды из группы `ru_nodes` автоматически получают отдельный RU-профиль портов.

Для RU-ноды можно переключить сбор speedtest-метрик на Яндекс:

```yaml
speedtest_provider: yandex
```

RemnaNode поддерживает два режима установки:

```yaml
remnanode_profile: plain        # обычный контейнер remnanode
remnanode_profile: trojan_grpc  # remnanode + nginx + TLS + Trojan gRPC
```

Если `remnanode_profile` не указан, используется `plain`.
