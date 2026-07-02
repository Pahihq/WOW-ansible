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
