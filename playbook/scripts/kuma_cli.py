#!/usr/bin/env python3
"""Управление мониторами Uptime Kuma.

REST API для мониторов в Kuma 2.x нет — только socket.io, поэтому тонкий CLI.
Учётка берётся из playbook/secrets/kuma.env (KUMA_URL / KUMA_USER / KUMA_PASS).

  kuma_cli.py list
  kuma_cli.py upsert --name "CDN_node1_VK" --url https://front.example/ [--parent 18]
                    [--rename-from "CDN node1"]
  kuma_cli.py delete --name "CDN_node1_VK"
  kuma_cli.py status [--parent 18] [--prefix "CDN_"]   # состояние + код ответа
"""
import argparse, json, os, re, sys, time
import socketio

# Коды состояния Kuma
DOWN, UP, PENDING, MAINTENANCE = 0, 1, 2, 3

# Код ответа приходит в msg двумя формами:
#   "451 - Unavailable For Legal Reasons"  — если код входит в accepted_statuscodes
#   "Request failed with status code 451"  — если НЕ входит (axios validateStatus кидает)
# Всё прочее (SSL/EPROTO/timeout) кода не несёт вовсе — и это не блокировка.
_CODE_PATTERNS = (re.compile(r'^\s*(\d{3})\s*-'),
                  re.compile(r'status code\s+(\d{3})\b', re.I))


def parse_code(msg):
    for rx in _CODE_PATTERNS:
        m = rx.search(msg or '')
        if m:
            code = int(m.group(1))
            if 100 <= code <= 599:
                return code
    return None


def load_env(path):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def connect(env, want_heartbeats=False):
    sio = socketio.Client(ssl_verify=True)
    state = {'heartbeats': {}}

    @sio.on('monitorList')
    def _ml(data):
        state['monitors'] = data

    @sio.on('heartbeatList')
    def _hb(mid, hbs, overwrite=None):
        state['heartbeats'][str(mid)] = hbs

    sio.connect(env['KUMA_URL'], transports=['websocket'], wait_timeout=25)
    res = sio.call('login', {'username': env['KUMA_USER'],
                             'password': env['KUMA_PASS'], 'token': ''}, timeout=30)
    if not res.get('ok'):
        sys.exit('Kuma: логин не прошёл: %s' % res.get('msg'))
    for _ in range(20):
        if 'monitors' in state:
            break
        sio.sleep(0.5)
    if want_heartbeats:
        # хартбиты приезжают отдельными событиями уже после monitorList
        for _ in range(16):
            if state['heartbeats']:
                break
            sio.sleep(0.5)
        sio.sleep(2)
    return sio, state.get('monitors', {}), state['heartbeats']


def find_by_name(monitors, name):
    for mid, m in monitors.items():
        if (m.get('name') or '') == name:
            return int(mid), m
    return None, None


def http_template(monitors):
    """Берём форму существующего http-монитора, чтобы не угадывать состав полей."""
    for m in monitors.values():
        if m.get('type') == 'http':
            return dict(m)
    return {}


def host_of(url):
    m = re.match(r'^https?://([^/:]+)', url or '')
    return m.group(1) if m else ''


def do_status(monitors, heartbeats, parent, prefix):
    out = []
    for mid, m in monitors.items():
        name = m.get('name') or ''
        if m.get('type') != 'http' or not name.startswith(prefix):
            continue
        if parent is not None and m.get('parent') != parent:
            continue
        hbs = heartbeats.get(str(mid)) or []
        last = hbs[-1] if hbs else {}
        msg = last.get('msg') or ''
        suffix = name[len(prefix):].strip()
        provider_match = re.match(r'^(.*)_(VK|YANDEX)$', suffix)
        out.append({
            'monitor_id': int(mid),
            'name': name,
            'node': provider_match.group(1) if provider_match else suffix,
            'provider': provider_match.group(2).lower() if provider_match else '',
            'url': m.get('url'),
            'front': host_of(m.get('url')),
            'active': bool(m.get('active')),
            'status': last.get('status'),
            'status_name': {DOWN: 'DOWN', UP: 'UP', PENDING: 'PENDING',
                            MAINTENANCE: 'MAINTENANCE'}.get(last.get('status'), 'UNKNOWN'),
            'code': parse_code(msg),
            # последние коды — сторожу для антифлапа
            'recent_codes': [parse_code(h.get('msg') or '') for h in hbs[-5:]],
            'msg': msg[:200],
            'time': last.get('time'),
        })
    return sorted(out, key=lambda x: x['monitor_id'])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('action', choices=['list', 'upsert', 'delete', 'status'])
    ap.add_argument('--name'); ap.add_argument('--url')
    ap.add_argument('--rename-from')
    ap.add_argument('--parent', type=int, default=None)
    ap.add_argument('--prefix', default='CDN_')
    ap.add_argument('--interval', type=int, default=60)
    ap.add_argument('--retries', type=int, default=2)
    ap.add_argument('--env', default=os.path.join(os.path.dirname(__file__), '..', 'secrets', 'kuma.env'))
    a = ap.parse_args()

    env = load_env(a.env)
    for k in ('KUMA_URL', 'KUMA_USER', 'KUMA_PASS'):
        if k not in env:
            sys.exit('нет %s в %s' % (k, a.env))

    sio, monitors, heartbeats = connect(env, want_heartbeats=(a.action == 'status'))
    try:
        if a.action == 'list':
            out = [{'id': int(i), 'name': m.get('name'), 'url': m.get('url'),
                    'type': m.get('type'), 'active': m.get('active')}
                   for i, m in monitors.items()]
            print(json.dumps(sorted(out, key=lambda x: x['id']), ensure_ascii=False, indent=1))
            return

        if a.action == 'status':
            print(json.dumps(do_status(monitors, heartbeats, a.parent, a.prefix),
                             ensure_ascii=False, indent=1))
            return

        if not a.name:
            sys.exit('нужен --name')
        mid, existing = find_by_name(monitors, a.name)

        # Legacy-монитор переименовываем на том же ID: так сохраняются
        # история heartbeat, uptime и привязанные уведомления.
        if a.action == 'upsert' and existing is None and a.rename_from:
            mid, existing = find_by_name(monitors, a.rename_from)

        if a.action == 'delete':
            if mid is None:
                print(json.dumps({'changed': False, 'reason': 'нет такого монитора'}))
                return
            sio.call('deleteMonitor', mid, timeout=30)
            print(json.dumps({'changed': True, 'deleted': mid}))
            return

        if not a.url:
            sys.exit('нужен --url')

        if existing:
            if (existing.get('name') == a.name and existing.get('url') == a.url
                    and existing.get('active') and existing.get('parent') == a.parent):
                print(json.dumps({'changed': False, 'id': mid, 'url': a.url}, ensure_ascii=False))
                return
            mon = dict(existing)
            mon['name'] = a.name
            mon['url'] = a.url
            mon['active'] = True
            mon['parent'] = a.parent
            mon['interval'] = a.interval
            mon['maxretries'] = a.retries
            r = sio.call('editMonitor', mon, timeout=30)
            if not r.get('ok'):
                sys.exit('Kuma: правка монитора не прошла: %s' % r.get('msg'))
            # editMonitor НЕ снимает паузу: active в payload Kuma игнорирует, для этого
            # есть отдельный resumeMonitor (в ветке создания он и вызывается).
            # Без этого переименованный legacy-монитор остаётся на паузе, heartbeat
            # протухает, а сторож читает последний UP и считает ноду вечно здоровой.
            resumed = False
            if not existing.get('active'):
                sio.call('resumeMonitor', mid, timeout=30)
                resumed = True
            print(json.dumps({'changed': True, 'id': mid, 'url': a.url,
                              'resumed': resumed}, ensure_ascii=False))
            return

        mon = http_template(monitors)
        # Производные и read-only поля клонировать нельзя: Kuma подставляет их в INSERT
        # как есть, и пустой childrenIDs роняет запрос синтаксической ошибкой SQL.
        for k in ('id', 'includeSensitiveData', 'tags', 'maintenance', 'childrenIDs',
                  'children_i_ds', 'path', 'pathName', 'path_name', 'forceInactive',
                  'screenshot', 'uptime', 'avgPing', 'lastHeartbeat', 'parent'):
            mon.pop(k, None)
        mon.update({'type': 'http', 'name': a.name, 'url': a.url, 'active': True,
                    'interval': a.interval, 'maxretries': a.retries,
                    'retryInterval': a.interval,
                    'accepted_statuscodes': ['200-299'],
                    'parent': a.parent})
        r = sio.call('add', mon, timeout=30)
        if not r.get('ok'):
            sys.exit('Kuma: создание монитора не прошло: %s' % r.get('msg'))
        new_id = r.get('monitorID')
        sio.call('resumeMonitor', new_id, timeout=30)
        print(json.dumps({'changed': True, 'id': new_id, 'url': a.url}, ensure_ascii=False))
    finally:
        sio.disconnect()

main()
