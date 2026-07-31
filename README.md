# WOW Ansible

Набор Ansible playbook для управления Debian/Ubuntu-серверами: подготовка системы, RemnaNode, UFW, мониторинг, отчётность, диагностика и xHTTP/nginx-ноды.

## Быстрый старт

На управляющей машине нужны Ansible, Python 3 и SSH-доступ к серверам от пользователя с `sudo` (в примере — `root`). Подготовьте рабочие файлы:

```bash
cd /home/user/Documents/WOW-ansible
cp inventory.yml.example inventory.yml
cp group_vars/docker_nodes.yml.example group_vars/docker_nodes.yml
mkdir -p logs reports/multitest
```

`inventory.yml` и `group_vars/docker_nodes.yml` содержат инфраструктурные данные и не должны попадать в Git. Перед запуском проверьте подключение:

```bash
ansible all -m ping
```

Все команды ниже запускаются из корня репозитория и используют стандартный `inventory.yml` из `ansible.cfg`. Для одной ноды добавляйте `--limit <inventory_hostname>`.

## Inventory и группы

| Группа | Назначение | Основные переменные хоста |
| --- | --- | --- |
| `docker_panel` | Панели и вспомогательные Docker-хосты | `ansible_host`, `ansible_user`, `monitoring_instance_name` |
| `docker_nodes` | VPN-ноды с RemnaNode | `monitoring_instance_name`, `remnanode_profile`, `domain`, `speedtest_provider` |
| `ru_nodes` | Подмножество VPN-нод с RU UFW-профилем | ссылка на хост из `docker_nodes` |
| `eu_nodes` | Подмножество европейских VPN-нод | ссылка на хост из `docker_nodes` |
| `xhttp_nodes` | Ноды с отдельным nginx/xHTTP cover-сайтом | `domain: primary, cdn` |

Пример xHTTP-ноды:

```yaml
xhttp_nodes:
  hosts:
    node_usa2:
      ansible_host: 92.118.112.150
      ansible_user: root
      monitoring_instance_name: node_usa2
      domain: arch.wowsecure.ru, edge.wowsecure.ru
```

Для `xhttp_nodes` первое имя в `domain` — основной домен и имя каталога сертификата Let's Encrypt; второе — CDN-домен. У каждой xHTTP-ноды должна быть уникальная пара доменов.

## Секреты и локальные файлы

Не храните секреты в inventory или Git. Перед связанными сценариями создайте локальные файлы:

| Сценарий | Локальный файл | Содержимое |
| --- | --- | --- |
| RemnaNode | `playbook/secrets/remnanode_secret_key` | ключ ноды Remnawave |
| Мониторинг | `playbook/secrets/vmagent.yml` | `vmagent_remote_write_url`, `vmagent_remote_write_username`, `vmagent_remote_write_password` |
| Отчётность | `playbook/secrets/google_sheet_id` | ID Google Sheets, одна строка |
| Отчётность | `playbook/secrets/google_credentials.json` | JSON service account Google |
| VK Cloud CDN | `playbook/scripts/.env` | OpenStack/VK Cloud и Cloudflare credentials |

Для отправки отчётов в Google Sheets на управляющей машине также требуются пакеты Python:

```bash
python3 -m pip install --user google-api-python-client google-auth
```

## Playbook

### Полная настройка

```bash
ansible-playbook playbook/site.yml
```

`site.yml` запускает последовательность: `bootstrap.yml` → `remnanode.yml` → `ufw.yml` → `monitoring.yml` → `reporting.yml`. Используйте его только после подготовки всех перечисленных секретов и переменных.

### Базовая подготовка хостов

```bash
ansible-playbook playbook/bootstrap.yml
```

Работает на всех хостах: обновляет Debian/Ubuntu без перезагрузки, устанавливает общие пакеты, настраивает локаль `en_US.UTF-8`, устанавливает Docker Engine и Docker Compose v2 из официального репозитория Docker. Если требуется reboot, playbook только сообщит об этом.

### RemnaNode

```bash
ansible-playbook playbook/remnanode.yml --limit docker_nodes
```

Профиль задаётся на хосте в inventory:

```yaml
remnanode_profile: plain        # стандартный Remnawave Node
remnanode_profile: trojan_grpc  # RemnaNode + nginx, TLS и Trojan gRPC
```

Для `trojan_grpc` обязательны `domain`, файл `playbook/secrets/remnanode_secret_key` и архив `playbook/files/site.zip`. Playbook сохраняет стек в `/opt/remnanode`, загружает `zapret.dat` и запускает Compose.

### Firewall UFW

```bash
ansible-playbook playbook/ufw.yml --limit docker_nodes
```

Перед первым запуском укажите реальные адреса панелей Remnawave в `group_vars/docker_nodes.yml`:

```yaml
ufw_panel_ips:
  - "198.51.100.10"
  - "198.51.100.11"
```

Роль определяет SSH и `NODE_PORT`, открывает SSH и клиентские порты, разрешает `NODE_PORT` только с IP панелей, включает `default deny incoming`. Дополнительные клиентские порты задаются на хосте через `ufw_client_ports_override`; для `ru_nodes` применяется отдельный профиль.

### Мониторинг

```bash
ansible-playbook playbook/monitoring.yml
```

Устанавливает и включает cAdvisor, node_exporter, vmagent и systemd timer для метрик speedtest. Каталоги: `/opt/monitoring` и `/var/lib/node_exporter/textfile_collector`. Значение `monitoring_instance_name` используется как имя хоста; если оно не задано, берётся `inventory_hostname`. `speedtest_provider: yandex` переключает сбор speedtest на Яндекс, иначе используется Ookla.

### Отчётность в Google Sheets

```bash
ansible-playbook playbook/reporting.yml
```

Собирает публичный IP, ОС, ядро, CPU, память, размер root-раздела и результаты speedtest, затем отправляет строки в Google Sheets. По умолчанию вкладка называется `ansible_inventory`; её можно изменить переменной окружения `GOOGLE_SHEET_TAB`. Вместо файлов допускаются `GOOGLE_SHEET_ID` и `GOOGLE_CREDENTIALS_FILE` в окружении.

### Обновление RemnaNode

```bash
ansible-playbook playbook/update_remnanode.yml --limit docker_nodes
```

Обновляет Compose-образы последовательно, по умолчанию пачками до трёх хостов, ждёт 15 секунд и показывает состояние сервисов. Неиспользуемые Docker-образы удаляются только с `-e prune_images=true`.

### Multitest

```bash
ansible-playbook playbook/multitest.yml --limit docker_nodes
```

Запускает нагрузочный Multitest строго по одной ноде за раз. Отчёт остаётся на сервере в `/var/log/multitest/<host>.txt` и копируется на управляющую машину в `reports/multitest/<host>.txt`.

### xHTTP/nginx cover-ноды

```bash
ansible-playbook playbook/xhttp_nginx.yml --limit xhttp_nodes
```

Этот playbook не устанавливает Docker, Docker Compose или Git: они должны быть на ноде заранее. Он выбирает разные статические витрины из `Pahihq/xhttp-selfsteal` автоматически по порядку нод в группе, получает сертификат Let's Encrypt через webroot и настраивает продление дважды в сутки.

После успешного развёртывания ноды playbook локально запускает
`playbook/scripts/setup-cdn.sh`. Первый домен из inventory передаётся как origin,
второй — как CDN-домен. Остальные параметры читаются только из локального
`playbook/scripts/.env`; секреты на управляемую ноду не копируются. Вызовы для
нескольких нод выполняются последовательно.

Подготовьте `.env` перед запуском:

```bash
cp playbook/scripts/.env.example playbook/scripts/.env
chmod 600 playbook/scripts/.env
```

В `.env` заполните OpenStack/VK Cloud и Cloudflare credentials. Скрипт ничего
не запрашивает интерактивно. `CDN_DOMAIN` и `ORIGIN` вычисляются из
`domain: primary, cdn` в inventory, протокол источника всегда `MATCH`, а CNAME
и Let's Encrypt настраиваются автоматически. Чтобы временно отключить
автоматическую настройку CDN, передайте `-e xhttp_cdn_setup_enabled=false`.

Стек размещается в `/opt/remnanode/nginx`. Nginx использует `network_mode: host`, поэтому одновременно принимает внешние подключения на 80/443 и передаёт `/api/stream/room` в xray на `127.0.0.1:10085`. Перед запуском основной домен должен указывать на ноду для прохождения ACME-проверки, а порты 80 и 443 должны быть свободны и доступны извне. CNAME второго домена создаётся автоматически после развёртывания. E-mail Let's Encrypt задан в `group_vars/xhttp_nodes.yml`.

## Проверки и безопасный запуск

Проверка синтаксиса:

```bash
ansible-playbook playbook/site.yml --syntax-check
ansible-playbook playbook/xhttp_nginx.yml --syntax-check
```

Предварительный просмотр изменений для большинства задач:

```bash
ansible-playbook playbook/ufw.yml --check --diff --limit node_usa2
```

`--check` не выполняет реальные операции, необходимые для выпуска сертификата Let's Encrypt, загрузки образов и некоторых shell/command-задач. Для UFW сначала используйте `--limit` на одной ноде и сохраняйте доступный SSH-сеанс до подтверждения правил.
