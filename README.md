# WOW Ansible

Репозиторий состоит из двух самостоятельных Ansible-проектов:

| Каталог | Назначение | Основной запуск |
| --- | --- | --- |
| [`ansible/`](ansible/) | Подготовка ОС, Docker, RemnaNode, UFW, мониторинг и отчётность | `cd ansible && ansible-playbook playbook/site.yml --limit <node>` |
| [`CDN/`](CDN/) | xHTTP-origin, Cloudflare DNS, VK/Yandex CDN, ротация, Remnawave-балансер, Kuma | `cd CDN && ansible-playbook playbook/rotate_cdn.yml --limit <node> -e cdn_dry_run=true` |

Каждый каталог содержит собственные `ansible.cfg`, `requirements.yml`, `playbook/`, `roles/`, `group_vars/` и тестовый inventory. Команды нужно выполнять **из соответствующего каталога**: пути в плейбуках и скриптах рассчитываются от него.

## Общий inventory

Рабочий список хостов хранится в `ansible/inventory.yml`. `CDN/inventory.yml` — символическая ссылка `../ansible/inventory.yml`; править список хостов нужно в одном месте. Файл игнорируется Git. Для новой установки скопируйте `ansible/inventory.yml.example` в `ansible/inventory.yml`, затем заполните реальные адреса. Оба каталога используют одни и те же имена хостов и группы `eu_nodes`, `docker_nodes` и другие, но загружают свои переменные из собственных `group_vars/`.

```bash
cp ansible/inventory.yml.example ansible/inventory.yml
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbook/site.yml --syntax-check
```

## Обычная настройка нод

Инструкции, состав плейбуков и требования к секретам: [`ansible/README.md`](ansible/README.md). Базовый `site.yml` не создаёт ресурсы CDN и не настраивает xHTTP-origin.

## CDN

Инструкции и порядок ротации: [`CDN/README.md`](CDN/README.md). Первый запуск после переноса требует перенести локальные CDN-секреты и файлы состояния в `CDN/playbook/secrets/` и `CDN/playbook/state/`, если они существуют в старом размещении. Эти файлы не хранятся в Git. Без состояния ротации запускать боевой `rotate_cdn.yml` нельзя: он не увидит прежнее активное плечо.

## Проверки

CI проверяет синтаксис всех плейбуков обоих каталогов через тестовые inventory. Эти проверки не подключаются к production. Изменения на сервере и во внешних API выполняются только при отдельном запуске соответствующего плейбука.
