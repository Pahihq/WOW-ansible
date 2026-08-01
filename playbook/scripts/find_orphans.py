#!/usr/bin/env python3
"""Ищет A-записи брошенных ротаций: те, что не упомянуты ни в одном файле состояния."""
import json, os, sys, urllib.request

ENV = '/root/ansible/playbook/secrets/.env'
STATE = '/root/ansible/playbook/state'
tok = None
for line in open(ENV):
    if line.startswith('CLOUDFLARE_API_TOKEN='):
        tok = line.split('=', 1)[1].strip().strip('"').strip("'")
assert tok, 'нет CLOUDFLARE_API_TOKEN'

DELETE = set(sys.argv[1:])


def cf(path, method='GET'):
    req = urllib.request.Request('https://api.cloudflare.com/client/v4' + path, method=method)
    req.add_header('Authorization', 'Bearer ' + tok)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


# домены, которые сейчас в работе
live = set()
for f in os.listdir(STATE):
    if f.endswith('.json'):
        d = json.load(open(os.path.join(STATE, f)))
        for k in ('origin_domain', 'front_domain'):
            if d.get(k):
                live.add(d[k])
        prev = d.get('prev') or {}
        for k in ('origin_domain', 'front_domain'):
            if prev.get(k):
                live.add(prev[k])

print('в работе по файлам состояния:', len(live))
for z in cf('/zones?per_page=50')['result']:
    for r in cf('/zones/%s/dns_records?per_page=200' % z['id'])['result']:
        if r['type'] not in ('A', 'CNAME'):
            continue
        name = r['name']
        mark = 'ЖИВОЙ ' if name in live else 'СИРОТА'
        if name in DELETE:
            cf('/zones/%s/dns_records/%s' % (z['id'], r['id']), method='DELETE')
            print('УДАЛЕНО  %-40s %-6s %s' % (name, r['type'], r['content']))
        elif mark == 'СИРОТА':
            print('%s   %-40s %-6s %s' % (mark, name, r['type'], r['content']))
