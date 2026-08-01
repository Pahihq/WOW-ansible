#!/usr/bin/env python3
"""Управление мониторами Uptime Kuma.

REST API для мониторов в Kuma 2.x нет — только socket.io, поэтому тонкий CLI.
Учётка берётся из playbook/secrets/kuma.env (KUMA_URL / KUMA_USER / KUMA_PASS).

  kuma_cli.py list
  kuma_cli.py upsert --name "CDN SW-2" --url https://front.example/ [--parent 18]
  kuma_cli.py delete --name "CDN SW-2"
"""
import argparse, json, os, sys, time
import socketio

def load_env(path):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env

def connect(env):
    sio = socketio.Client(ssl_verify=True)
    state = {}
    @sio.on('monitorList')
    def _ml(data):
        state['monitors'] = data
    sio.connect(env['KUMA_URL'], transports=['websocket'], wait_timeout=25)
    res = sio.call('login', {'username': env['KUMA_USER'],
                             'password': env['KUMA_PASS'], 'token': ''}, timeout=30)
    if not res.get('ok'):
        sys.exit('Kuma: логин не прошёл: %s' % res.get('msg'))
    for _ in range(20):
        if 'monitors' in state:
            break
        sio.sleep(0.5)
    return sio, state.get('monitors', {})

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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('action', choices=['list', 'upsert', 'delete'])
    ap.add_argument('--name'); ap.add_argument('--url')
    ap.add_argument('--parent', type=int, default=None)
    ap.add_argument('--interval', type=int, default=60)
    ap.add_argument('--retries', type=int, default=2)
    ap.add_argument('--env', default=os.path.join(os.path.dirname(__file__), '..', 'secrets', 'kuma.env'))
    a = ap.parse_args()

    env = load_env(a.env)
    for k in ('KUMA_URL', 'KUMA_USER', 'KUMA_PASS'):
        if k not in env:
            sys.exit('нет %s в %s' % (k, a.env))

    sio, monitors = connect(env)
    try:
        if a.action == 'list':
            out = [{'id': int(i), 'name': m.get('name'), 'url': m.get('url'),
                    'type': m.get('type'), 'active': m.get('active')}
                   for i, m in monitors.items()]
            print(json.dumps(sorted(out, key=lambda x: x['id']), ensure_ascii=False, indent=1))
            return

        if not a.name:
            sys.exit('нужен --name')
        mid, existing = find_by_name(monitors, a.name)

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
            if existing.get('url') == a.url and existing.get('active'):
                print(json.dumps({'changed': False, 'id': mid, 'url': a.url}, ensure_ascii=False))
                return
            mon = dict(existing)
            mon['url'] = a.url
            mon['active'] = True
            r = sio.call('editMonitor', mon, timeout=30)
            if not r.get('ok'):
                sys.exit('Kuma: правка монитора не прошла: %s' % r.get('msg'))
            print(json.dumps({'changed': True, 'id': mid, 'url': a.url}, ensure_ascii=False))
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
