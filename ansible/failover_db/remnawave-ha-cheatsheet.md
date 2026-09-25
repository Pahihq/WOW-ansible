# Шпаргалка Remnawave PostgreSQL HA

Нормальное рабочее состояние:

```text
10.66.66.1 germany-back-panel  primary, основная база
10.66.66.2 poland-panel-rezerv standby, реплика
```

Скопируй все файлы `remnawave-*.sh` в `/opt/remnawave` на оба сервера и сделай их исполняемыми:

```bash
chmod +x /opt/remnawave/remnawave-*.sh
```

## Упал Germany primary

Запускать на Poland:

```bash
cd /opt/remnawave
CONFIRM_FAILOVER=PROMOTE ./remnawave-failover-germany-to-poland.sh
```

Потом переключи DNS/proxy/трафик на `10.66.66.2`.

Когда Germany вернется, запускать на Germany:

```bash
cd /opt/remnawave
CONFIRM_REJOIN=YES CONFIRM_DESTROY_VOLUME=remnawave-db-data REPL_PASSWORD='YOUR_REPLICATION_PASSWORD' ./remnawave-rejoin-germany-as-replica.sh
```

## Упал Poland primary после предыдущего failover

Запускать на Germany:

```bash
cd /opt/remnawave
CONFIRM_FAILOVER=PROMOTE ./remnawave-failover-poland-to-germany.sh
```

Потом переключи DNS/proxy/трафик на `10.66.66.1`.

Когда Poland вернется, запускать на Poland:

```bash
cd /opt/remnawave
CONFIRM_REJOIN=YES CONFIRM_DESTROY_VOLUME=remnawave-db-data REPL_PASSWORD='YOUR_REPLICATION_PASSWORD' ./remnawave-rejoin-poland-as-replica.sh
```

## Проверки

На primary:

```bash
docker compose exec remnawave-db sh -lc '
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select client_addr, state, sync_state from pg_stat_replication;"
'
```

На standby:

```bash
docker compose exec remnawave-db sh -lc '
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select pg_is_in_recovery();"
'
```

Standby должен вернуть `t`.

## Важное правило

После failover старую primary нельзя просто включать обратно как была. Ее нужно пересоздать как standby через соответствующий `remnawave-rejoin-...-as-replica.sh`, иначе можно получить две разные primary-базы.
