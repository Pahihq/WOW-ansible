#!/usr/bin/env python3
"""Сторож 451: ловит блокировку CDN-фронта в Uptime Kuma и запускает ротацию ноды.

Запускается таймером systemd раз в минуту. Решение принимается по КОДУ ОТВЕТА,
а не по факту падения монитора: свежий фронт всегда некоторое время лежит с
SSL-ошибкой, пока VK-edge выпускает сертификат, и ротировать его нельзя.

  cdn_watchdog.py --dry-run     решение печатается, ничего не запускается
  cdn_watchdog.py               боевой режим

Стоп-кран: создать playbook/state/AUTOROTATE_OFF — авто выключено,
ручные запуски rotate_cdn.yml при этом работают как обычно.
"""
import argparse, fcntl, json, os, re, subprocess, sys, time, urllib.request
from datetime import datetime, timezone

ANSIBLE_DIR = '/root/ansible'
PLAYBOOK_DIR = os.path.join(ANSIBLE_DIR, 'playbook')
STATE_DIR = os.path.join(PLAYBOOK_DIR, 'state')
WD_STATE = os.path.join(STATE_DIR, '.watchdog.json')
KILL_SWITCH = os.path.join(STATE_DIR, 'AUTOROTATE_OFF')
LOCK_FILE = '/run/cdn-autorotate.lock'
KUMA_CLI = os.path.join(PLAYBOOK_DIR, 'scripts', 'kuma_cli.py')
KUMA_ENV = os.path.join(PLAYBOOK_DIR, 'secrets', 'kuma.env')
TG_ENV = os.path.join(PLAYBOOK_DIR, 'secrets', 'telegram.env')
VENV_PY = os.path.join(ANSIBLE_DIR, '.venv', 'bin', 'python')

KUMA_GROUP = 18            # группа «💫CDN + БС»
MONITOR_PREFIX = 'CDN_'    # CDN_node_ch1_VK / CDN_node_ch1_YANDEX

# Точка обзора из РФ: 451 отдаёт ТСПУ, из ЕС его не видно.
# Это та же московская машина, на которой живёт сама Kuma (ru_monitoring1).
RU_PROBE = os.environ.get('CDN_RU_PROBE', 'root@45.150.37.205')

TRIGGER_CODES = {451}      # строго блокировка; всё прочее — только алерт
# Kuma не получает HTTP-код, когда edge Yandex отдаёт свой wildcard-сертификат
# вместо сертификата фронта. Это известный сбой свежего CDN-ресурса, а не ошибка
# origin: его лечим узким пересозданием Yandex CDN, без полной ротации плеча.
YANDEX_SAN_ERROR = re.compile(r'hostname/ip does not match certificate.?s altnames', re.I)
STRIKES_REQUIRED = 2       # подряд идущих тиков сторожа с 451
COOLDOWN_H = 6             # не ротировать одну ноду чаще
# Сколько минут непрерывного 451 перекрывают cooldown. Смысл: cooldown защищает от
# карусели, когда новый фронт ложится сразу. Но если фронт прожил своё и лёг «по-честному»,
# ждать полный cooldown — значит держать ноду мёртвой дольше, чем живёт домен:
# 2026-08-02 node_ch1 словил 451 через 3 ч после ротации и завис на 3 ч ожидания.
# От петли по-прежнему страхует DAILY_BUDGET.
COOLDOWN_OVERRIDE_MIN = 15
# Авторотаций в сутки на весь флот. Было 3 — на шести нодах не хватило: 2026-08-03 лимит
# съели nl2+fr1+ee1, и node_ch1 простояла под 451 14 минут без права на ротацию
# (сторож каждый тик писал «исчерпан суточный лимит»). Считать по одной на ноду.
DAILY_BUDGET = 6
ALERT_COOLDOWN_H = 3       # как часто повторять алерт по одной ноде
FRESH_GRACE_MIN = 45       # свежий фронт не трогаем и не алертим: edge дозревает

DOWN, UP, PENDING = 0, 1, 2


def log(msg):
    print('%s %s' % (datetime.now().strftime('%Y-%m-%d %H:%M:%S'), msg), flush=True)


def now_ts():
    return int(time.time())


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save_wd(data):
    tmp = WD_STATE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, WD_STATE)


def load_env(path):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def telegram(text, dry=False):
    if dry:
        log('TG (dry-run): ' + text.replace('\n', ' | '))
        return
    env = load_env(TG_ENV)
    tok, chat = env.get('TELEGRAM_BOT_TOKEN'), env.get('TELEGRAM_CHAT_ID')
    if not tok or not chat:
        log('TG: нет credentials в %s' % TG_ENV)
        return
    body = {'chat_id': chat, 'text': text, 'parse_mode': 'HTML',
            'disable_web_page_preview': True}
    thread = env.get('TELEGRAM_THREAD_ID')
    if thread:
        # без этого сообщение уходит в General, а не в топик
        body['message_thread_id'] = int(thread)
    req = urllib.request.Request(
        'https://api.telegram.org/bot%s/sendMessage' % tok,
        data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            ok = json.load(r).get('ok')
        log('TG: отправлено' if ok else 'TG: отказ')
    except Exception as e:
        log('TG: ошибка отправки: %s' % e)


def http_code(argv, timeout=40):
    """Возвращает код ответа целым числом либо None."""
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        m = re.search(r'(\d{3})\s*$', (out.stdout or '').strip())
        return int(m.group(1)) if m else None
    except Exception as e:
        log('проба не выполнилась (%s): %s' % (' '.join(argv[:3]), e))
        return None


def probe_from_ru(front):
    return http_code(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                      '-o', 'StrictHostKeyChecking=no', RU_PROBE,
                      "curl -sS -o /dev/null -w '%%{http_code}' --max-time 20 https://%s/" % front])


def probe_origin(origin, node_ip):
    """Origin дёргаем напрямую по IP ноды, минуя CDN: жив ли сам декой."""
    return http_code(['curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}',
                      '--max-time', '20', '--resolve', '%s:443:%s' % (origin, node_ip),
                      'https://%s/' % origin])


def kuma_status():
    out = subprocess.run([VENV_PY, KUMA_CLI, 'status', '--parent', str(KUMA_GROUP),
                          '--prefix', MONITOR_PREFIX, '--env', KUMA_ENV],
                         capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError('kuma_cli status: %s' % (out.stderr or '')[:300])
    return json.loads(out.stdout)


def node_state(node):
    return load_json(os.path.join(STATE_DIR, '%s.json' % node), {})


def age_minutes(iso):
    if not iso:
        return None
    try:
        t = datetime.fromisoformat(iso.replace('Z', '+00:00'))
        return (datetime.now(timezone.utc) - t).total_seconds() / 60.0
    except Exception:
        return None


def rotation_running():
    out = subprocess.run(['pgrep', '-f', 'ansible-playbook.*rotate(_yandex)?_cdn.yml'],
                         capture_output=True, text=True)
    return out.returncode == 0


def fire_rotation(node, provider_mode, dry):
    cmd = ['ansible-playbook', 'playbook/rotate_cdn.yml', '--limit', node,
           '-e', 'auto_trigger=true', '-e', 'cdn_provider=%s' % provider_mode]
    if dry:
        log('ЗАПУСК (dry-run, не выполняю): %s' % ' '.join(cmd))
        return True, 'dry-run'
    log('ЗАПУСК РОТАЦИИ: %s' % ' '.join(cmd))
    out = subprocess.run(cmd, cwd=ANSIBLE_DIR, capture_output=True, text=True, timeout=3600)
    tail = '\n'.join((out.stdout or '').strip().split('\n')[-25:])
    log('ротация %s завершилась rc=%s\n%s' % (node, out.returncode, tail))
    return out.returncode == 0, tail


def fire_yandex_recreate(node, front, dry):
    """Пересоздаёт только Yandex CDN текущего фронта и сверяет его CNAME."""
    cmd = ['ansible-playbook', 'playbook/rotate_yandex_cdn.yml', '--limit', node,
           '-e', 'apply=true', '-e', 'yandex_cdn_front_domain=%s' % front]
    if dry:
        log('Yandex CDN (dry-run, не выполняю): %s' % ' '.join(cmd))
        return True, 'dry-run'
    log('ПЕРЕСОЗДАНИЕ YANDEX CDN: %s' % ' '.join(cmd))
    out = subprocess.run(cmd, cwd=ANSIBLE_DIR, capture_output=True, text=True, timeout=3600)
    tail = '\n'.join((out.stdout or '').strip().split('\n')[-25:])
    log('пересоздание Yandex CDN rc=%s\n%s' % (out.returncode, tail))
    return out.returncode == 0, tail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--verbose', action='store_true')
    a = ap.parse_args()

    if os.path.exists(KILL_SWITCH):
        log('стоп-кран %s на месте — авторотация выключена' % KILL_SWITCH)
        return 0

    lock = open(LOCK_FILE, 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log('предыдущий тик ещё работает — пропускаю')
        return 0

    wd = load_json(WD_STATE, {})
    monitors = kuma_status()
    fired = []

    for m in monitors:
        node, front = m['node'], m['front']
        provider = m.get('provider') or 'vk'
        rec_key = '%s:%s' % (node, provider)
        rec = wd.setdefault(rec_key, {'strikes': 0, 'last_rotation': 0, 'last_alert': 0,
                                   'first_451': 0, 'san_strikes': 0,
                                   'last_yandex_recreate': 0})
        st = node_state(node)

        if a.verbose:
            log('%s: %s code=%s front=%s' % (node, m['status_name'], m['code'], front))

        # Монитор поднялся — счётчик сбрасываем
        if m['status'] == UP:
            if rec['strikes']:
                log('%s: фронт снова отвечает, счётчик сброшен' % node)
            rec['strikes'] = 0
            rec['first_451'] = 0
            rec['san_strikes'] = 0
            continue

        # Ротация ноды не завершена или монитор ещё не переехал на новый фронт —
        # состояние противоречиво, решений не принимаем.
        state_front = (st.get('front_domains') or {}).get(provider, st.get('front_domain'))
        if (st.get('status') != 'active') or (state_front != front):
            log('%s/%s: пропуск — состояние %s, фронт в state=%s, в мониторе=%s'
                % (node, provider, st.get('status'), state_front, front))
            continue

        # Kuma формирует это сообщение до HTTP-запроса; FRESH_GRACE_MIN здесь
        # намеренно не применяется — именно после создания CDN ошибка и проявляется.
        san_error = provider == 'yandex' and m['status'] == DOWN and YANDEX_SAN_ERROR.search(m.get('msg') or '')
        if san_error:
            rec['san_strikes'] = rec.get('san_strikes', 0) + 1
            if rec['san_strikes'] < STRIKES_REQUIRED:
                log('%s/Yandex: SAN-ошибка (%d/%d), жду подтверждения'
                    % (node, rec['san_strikes'], STRIKES_REQUIRED))
                continue
            if now_ts() - rec.get('last_yandex_recreate', 0) < COOLDOWN_H * 3600:
                log('%s/Yandex: SAN-ошибка, но пересоздание уже было менее %d ч назад'
                    % (node, COOLDOWN_H))
                continue
            if rotation_running():
                log('%s/Yandex: другая CDN-операция уже идёт — отложено' % node)
                continue
            telegram('<b>Yandex CDN: сертификат edge не соответствует фронту</b>\n'
                     'нода: <code>%s</code>\nфронт: <code>%s</code>\n'
                     'Kuma: <code>%s</code>\n'
                     'Запускаю пересоздание только Yandex CDN и проверку CNAME.'
                     % (node, front, (m.get('msg') or '')[:180]), a.dry_run)
            rec['last_yandex_recreate'] = now_ts()
            rec['san_strikes'] = 0
            save_wd(wd)
            ok, tail = fire_yandex_recreate(node, front, a.dry_run)
            fired.append(node)
            if not ok:
                telegram('<b>Пересоздание Yandex CDN упало</b>\nнода: <code>%s</code>\n'
                         '<code>%s</code>' % (node, tail[-500:].replace('<', '&lt;')), a.dry_run)
            break
        rec['san_strikes'] = 0

        fresh = age_minutes(st.get('finished_at'))
        if fresh is not None and fresh < FRESH_GRACE_MIN:
            log('%s: пропуск — ротация закончилась %d мин назад, edge дозревает'
                % (node, fresh))
            continue

        # --- Класс «не блокировка»: только алерт, ротацию не запускаем ---
        if m['code'] not in TRIGGER_CODES:
            if now_ts() - rec['last_alert'] > ALERT_COOLDOWN_H * 3600:
                rec['last_alert'] = now_ts()
                telegram(
                    '<b>CDN-фронт лежит (не 451)</b>\n'
                    'нода: <code>%s</code>\nфронт: <code>%s</code>\n'
                    'состояние: %s, код: %s\n<code>%s</code>\n'
                    'Ротация НЕ запускалась — это не похоже на блокировку.'
                    % (node, front, m['status_name'], m['code'] or '—', (m['msg'] or '')[:180]),
                    a.dry_run)
            rec['strikes'] = 0
            rec['first_451'] = 0
            continue

        # --- Класс «451» ---
        if not rec['strikes']:
            rec['first_451'] = now_ts()
        rec['strikes'] += 1
        blocked_min = (now_ts() - rec['first_451']) / 60.0
        log('%s: 451 на фронте %s (подряд: %d/%d, под блоком %d мин)'
            % (node, front, rec['strikes'], STRIKES_REQUIRED, blocked_min))
        if m['status'] != DOWN or rec['strikes'] < STRIKES_REQUIRED:
            continue

        cooldown_left = COOLDOWN_H * 3600 - (now_ts() - rec['last_rotation'])
        if cooldown_left > 0:
            # Ждём подтверждения, что фронт лёг всерьёз, а не мигнул сразу после ротации.
            if blocked_min < COOLDOWN_OVERRIDE_MIN:
                log('%s: cooldown — ротация была менее %d ч назад; блокировка держится '
                    '%d из %d мин, нужных чтобы его перекрыть'
                    % (node, COOLDOWN_H, blocked_min, COOLDOWN_OVERRIDE_MIN))
                continue
            log('%s: cooldown (оставалось %.1f ч) перекрыт — 451 непрерывно %d мин'
                % (node, cooldown_left / 3600.0, blocked_min))

        day_ago = now_ts() - 86400
        used = sum(1 for r in wd.values() if r.get('last_rotation', 0) > day_ago)
        if used >= DAILY_BUDGET:
            log('исчерпан суточный лимит авторотаций (%d)' % DAILY_BUDGET)
            telegram('<b>451 на <code>%s</code>, но суточный лимит авторотаций '
                     'исчерпан (%d)</b>\nРотацию нужно запустить руками.'
                     % (node, DAILY_BUDGET), a.dry_run)
            break

        if rotation_running():
            log('%s: другая ротация уже идёт — отложено до следующего тика' % node)
            continue

        # Подтверждение 1: 451 виден с московской точки
        ru = probe_from_ru(front)
        if ru not in TRIGGER_CODES:
            log('%s: РФ-проба вернула %s, а не 451 — не подтверждено' % (node, ru))
            rec['strikes'] = 0
            continue

        # Подтверждение 2: origin жив (значит дело не в ноде, а во фронте)
        org = probe_origin(st.get('origin_domain'), st.get('node_ip'))
        if org != 200:
            log('%s: origin отдал %s — это проблема ноды, не ТСПУ' % (node, org))
            telegram('<b>451 на фронте, но и origin лежит</b>\n'
                     'нода: <code>%s</code>\nфронт: <code>%s</code> → 451\n'
                     'origin: <code>%s</code> → %s\n'
                     'Ротация НЕ запускалась: сначала чинить ноду.'
                     % (node, front, st.get('origin_domain'), org), a.dry_run)
            rec['strikes'] = 0
            continue

        telegram('<b>451 подтверждён — запускаю ротацию</b>\n'
                 'нода: <code>%s</code>\nфронт: <code>%s</code>\n'
                 'под блоком %d мин · Kuma: DOWN %d тика подряд · '
                 'проба из Москвы: 451 · origin: 200%s'
                 % (node, front, blocked_min, rec['strikes'],
                    '\ncooldown перекрыт: блокировка держится дольше %d мин'
                    % COOLDOWN_OVERRIDE_MIN if cooldown_left > 0 else ''), a.dry_run)

        rec['last_rotation'] = now_ts()
        rec['strikes'] = 0
        rec['first_451'] = 0
        save_wd(wd)                      # фиксируем ДО запуска: падение не должно снять cooldown
        ok, tail = fire_rotation(node, st.get('cdn_provider') or provider, a.dry_run)
        fired.append(node)
        if not ok:
            telegram('<b>Авторотация упала</b>\nнода: <code>%s</code>\n'
                     'Разбирать: <code>journalctl -u cdn-watchdog</code> и '
                     '<code>/var/log/cdn-autorotate.log</code>\n'
                     '<code>%s</code>' % (node, tail[-500:].replace('<', '&lt;')), a.dry_run)
        break                            # одна ротация за тик

    save_wd(wd)
    if not fired:
        log('ротаций не требуется (проверено мониторов: %d)' % len(monitors))
    return 0


if __name__ == '__main__':
    sys.exit(main())
