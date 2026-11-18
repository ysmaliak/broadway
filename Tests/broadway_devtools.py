#!/usr/bin/env python3
import json
import os
import re
import select
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BROADWAY = str(ROOT / 'build/Broadway.app/Contents/Helpers/broadway')
WORLD = f'broadway-devtools-{os.getpid()}'
FOLDER = Path.home() / f'Library/Application Support/Broadway ({WORLD})'
SUITE = f'com.ysmaliak.broadway.test.{WORLD}'
ENV = dict(os.environ, BROADWAY_AGENT=f'devtools-{os.getpid()}')
PAGE = b'''<!doctype html><title>Developer probe</title>
<style>#hover{width:200px;height:70px}#menu{display:none}#hover:hover #menu{display:block}</style>
<button id="hover" onmouseover="document.querySelector('#state').textContent='hovered'">Hover here<span id="menu">Hover menu</span></button>
<select aria-label="Colour" onchange="document.querySelector('#state').textContent='selected '+this.value"><option value="red">Red</option><option value="blue">Blue</option><option disabled value="blocked">Blocked</option></select>
<select aria-label="Many options"></select>
<select aria-label="Verification code" autocomplete="one-time-code"><option value="123456">Code</option></select>
<button onclick="alert('Hello agent');document.querySelector('#state').textContent='alert answered'">Alert</button>
<button onclick="document.querySelector('#state').textContent='confirm '+confirm('Continue the probe?')">Check choice</button>
<button onclick="document.querySelector('#state').textContent='prompt '+prompt('Your name?')">Prompt</button>
<button onclick="document.querySelector('#state').textContent='secret '+prompt('Password?')">Secret prompt</button>
<button onclick="console.warn('fresh warning')">More logs</button>
<p id="state">Ready</p><input type="password" value="pdf-private-secret"><iframe src="/frame"></iframe>
<script>
var many=document.querySelector('[aria-label=\"Many options\"]');for(var i=0;i<110;i++){var option=document.createElement('option');option.value=i===0?'v'.repeat(240):String(i);option.label=i===0?'l'.repeat(150):'Option '+i;many.appendChild(option);}
console.error('probe error token=console-private-secret');console.warn('probe warning');console.log('probe log');console.info('probe info');console.debug('probe debug');
fetch('/api?access_token=query-private-secret&page=2',{method:'POST',headers:{Authorization:'Bearer header-private-secret'},body:'body-private-secret'});
var xhr=new XMLHttpRequest();xhr.open('GET','/missing');xhr.send();
</script>'''


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'frame-private-secret' if self.path == '/frame' else b'missing' if self.path == '/missing' else PAGE
        self.send_response(404 if self.path == '/missing' else 200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.send_response(201)
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'ok')

    def log_message(self, *_):
        pass


def check(name, condition):
    print(('ok   ' if condition else 'FAIL ') + name, flush=True)
    if not condition:
        raise AssertionError(name)


def bench(*words):
    result = subprocess.run([str(ROOT / 'bench'), '--world', WORLD, *words], capture_output=True, text=True, timeout=20)
    return result.stdout.strip()


def cli(*words, agent=None, raw=False):
    env = dict(ENV)
    if agent:
        env['BROADWAY_AGENT'] = agent
    result = subprocess.run([BROADWAY, '--world', WORLD, *words, *([] if raw else ['--json'])], env=env, capture_output=True, timeout=25)
    if raw:
        return result
    return json.loads(result.stdout)


class MCP:
    def __init__(self):
        self.process = subprocess.Popen([BROADWAY, '--world', WORLD, 'mcp'], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.number = 0
        self.rpc('initialize', {'protocolVersion': '2025-06-18'})

    def rpc(self, method, params=None):
        self.number += 1
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.number, 'method': method, 'params': params or {}}) + '\n')
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 25)[0]:
            raise TimeoutError(method)
        return json.loads(self.process.stdout.readline())['result']

    def call(self, name, **arguments):
        result = self.rpc('tools/call', {'name': name, 'arguments': arguments})
        text = ''.join(part.get('text', '') for part in result['content'])
        if result.get('isError'):
            return {'ok': False, 'text': text}
        if name == 'snapshot':
            elements = []
            for line in text.splitlines():
                match = re.match(r'(e\d+) (\w+) "([^"]*)"', line)
                if match:
                    item = dict(zip(['ref', 'role', 'name'], match.groups()))
                    if ' options=' in line:
                        item['options'] = json.loads(line.split(' options=', 1)[1])
                    elements.append(item)
            return {'ok': True, 'data': {'elements': elements}}
        return {'ok': True, 'data': json.loads('\n'.join(text.splitlines()[2:-1])) if text.splitlines()[2:3] and text.splitlines()[2].startswith('{') else {'text': text}}

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)


def start():
    for key in ['bench', 'agents.on']:
        subprocess.run(['defaults', 'write', SUITE, key, '-bool', 'true'], check=True)
    subprocess.run(['open', '-n', '-g', '-j', '--env', f'SEARCH_PROBE={WORLD}', str(ROOT / 'build/Broadway.app')], check=True)
    for _ in range(100):
        if (FOLDER / 'broadway.sock').exists():
            bench('window')
            check('test pages stay off screen', json.loads(bench('pages', 'on')).get('pages') is True)
            return
        time.sleep(.2)
    raise TimeoutError('world startup')


def exercise(call, base, label):
    opened = call('open', url=base)
    check(label + ' open', opened['ok'])
    tab = opened['data']['id']
    check(label + ' wait', call('wait', tab=tab)['ok'])
    time.sleep(.5)
    shot = call('snapshot', tab=tab)['data']
    refs = {item['name']: item['ref'] for item in shot['elements']}
    colour = next(item for item in shot['elements'] if item['name'] == 'Colour')
    check(label + ' select options', [option['value'] for option in colour['options']] == ['red', 'blue', 'blocked'])
    many = next(item for item in shot['elements'] if item['name'] == 'Many options')
    check(label + ' options have shared bounds', len(many['options']) == 100 and len(many['options'][0]['value']) == 200 and len(many['options'][0]['label']) == 120)
    secret = next(item for item in shot['elements'] if item['name'] == 'Verification code')
    check(label + ' secret options omitted', 'options' not in secret)
    if label == 'CLI':
        plain = cli('snapshot', '--tab', tab, raw=True).stdout.decode()
        colour_line = next(line for line in plain.splitlines() if '"Colour"' in line)
        many_line = next(line for line in plain.splitlines() if '"Many options"' in line)
        check('CLI plain options match JSON', json.loads(colour_line.split(' options=', 1)[1]) == colour['options'])
        check('CLI plain option bounds match JSON', json.loads(many_line.split(' options=', 1)[1]) == many['options'])
        check('CLI plain secret options omitted', ' options=' not in next(line for line in plain.splitlines() if '"Verification code"' in line) and '123456' not in plain)
    logs = call('console', tab=tab)['data']
    check(label + ' captures all console levels', {row['level'] for row in logs['messages']} == {'error', 'warning', 'log', 'info', 'debug'})
    check(label + ' console scrub', 'console-private-secret' not in json.dumps(logs))
    filtered = call('console', tab=tab, level='error', limit=1)['data']
    check(label + ' level and limit', len(filtered['messages']) == 1 and filtered['messages'][0]['level'] == 'error')
    call('click', tab=tab, ref=refs['More logs'])
    time.sleep(.2)
    recent = call('console', tab=tab, since=logs['cursor'])['data']['messages']
    check(label + ' cursor advances', len(recent) == 1 and recent[0]['message'] == 'fresh warning')
    check(label + ' empty cursor result', call('console', tab=tab, since=call('console', tab=tab)['data']['cursor'])['data']['messages'] == [])
    net = call('network', tab=tab)['data']
    requests = net['requests']
    check(label + ' network summaries', any(row['method'] == 'POST' and row['status'] == 201 and row['type'] == 'fetch' and row.get('bytes') == 2 for row in requests) and any(row['status'] == 404 and row['failed'] for row in requests))
    check(label + ' network cursor empty', call('network', tab=tab, since=net['cursor'])['data']['requests'] == [])
    check(label + ' rejects foreign cursor', not call('console', tab=tab, since='another-tab:1')['ok'])
    check(label + ' rejects excessive limit', not call('console', tab=tab, limit=101)['ok'])
    check(label + ' network scrub and omission', not any(secret in json.dumps(net) for secret in ['query-private-secret', 'header-private-secret', 'body-private-secret', 'headers', 'body']))
    check(label + ' menu starts hidden', 'Hover menu' not in call('text', tab=tab)['data'].get('text', ''))
    check(label + ' hover', call('hover', tab=tab, ref=refs['Hover here'])['ok'])
    time.sleep(.2)
    hover = json.loads(bench('eval', tab, "JSON.stringify({hover:document.querySelector('#hover').matches(':hover'),display:getComputedStyle(document.querySelector('#menu')).display,visible:document.visibilityState})"))
    print(label + ' hover evidence: ' + json.dumps(hover), flush=True)
    check(label + ' hover CSS menu rendered', hover['hover'] and hover['display'] == 'block')
    check(label + ' choose', call('choose', tab=tab, ref=refs['Colour'], value='blue')['ok'])
    check(label + ' select changed', 'selected blue' in call('text', tab=tab)['data'].get('text', ''))
    check(label + ' disabled option refuses', not call('choose', tab=tab, ref=refs['Colour'], value='blocked')['ok'])
    check(label + ' secret select refuses', not call('choose', tab=tab, ref=refs['Verification code'], value='123456')['ok'])
    call('click', tab=tab, ref=refs['Alert'])
    check(label + ' a click answers a plain alert itself', not call('dialog', tab=tab)['data'].get('pending') and 'alert answered' in call('text', tab=tab)['data'].get('text', ''))
    for name, action, expected in [('Confirm', 'dismiss', 'confirm false'), ('Prompt', 'accept', 'prompt Robin'), ('Secret prompt', 'dismiss', 'secret null')]:
        call('click', tab=tab, ref=refs['Check choice' if name == 'Confirm' else name])
        for _ in range(30):
            pending = call('dialog', tab=tab)['data']
            if pending.get('pending'):
                break
            time.sleep(.1)
        check(label + ' ' + name + ' pending', pending.get('pending'))
        check(label + ' stale dialog id refuses', not call('dialog', tab=tab, action='accept', id='old')['ok'])
        if name == 'Secret prompt':
            check(label + ' secret prompt refuses', not call('dialog', tab=tab, action='accept', id=pending['id'], text='never type this')['ok'])
        check(label + ' answer ' + name, call('dialog', tab=tab, action=action, id=pending['id'], text='Robin')['ok'])
        time.sleep(.2)
        check(label + ' ' + name + ' result', expected in call('text', tab=tab)['data'].get('text', ''))
    pdf = call('pdf', tab=tab)['data']
    path = Path(pdf['path'])
    check(label + ' PDF file', path.read_bytes().startswith(b'%PDF') and path.stat().st_mode & 0o777 == 0o600)
    check(label + ' PDF private directory', path.parent.stat().st_mode & 0o777 == 0o700)
    extracted = subprocess.run(['/usr/bin/swift', '-e', 'import PDFKit; import Foundation; print(PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))?.string ?? "")', str(path)], capture_output=True, text=True, timeout=40)
    check(label + ' PDF redaction', extracted.returncode == 0 and 'Developer probe' not in extracted.stdout and 'pdf-private-secret' not in extracted.stdout and 'frame-private-secret' not in extracted.stdout and 'secret null' in extracted.stdout)
    shutil.rmtree(path.parent)
    check(label + ' wrong agent dialog refuses', not cli('dialog', '--tab', tab, agent='another-devtools-agent')['ok'])
    call('click', tab=tab, ref=refs['Check choice'])
    time.sleep(.2)
    check(label + ' pending before navigation', call('dialog', tab=tab)['data'].get('pending'))
    check(label + ' navigate', call('navigate', tab=tab, url=base)['ok'])
    check(label + ' navigation dismissed dialog', not call('dialog', tab=tab)['data'].get('pending'))
    call('wait', tab=tab)
    check(label + ' stale ref refuses', not call('choose', tab=tab, ref=refs['Colour'], value='blue')['ok'])
    return tab


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}/'
    client = None
    try:
        start()
        help_text = cli('help', raw=True).stdout.decode()
        check('generated help', all(name in help_text for name in ['console', 'network', 'pdf', 'hover', 'choose', 'dialog']))
        for name in ['console', 'network', 'pdf', 'hover', 'choose', 'dialog']:
            help_page = cli('help', name, raw=True)
            check('help ' + name, help_page.returncode == 0 and name in help_page.stdout.decode())
        snapshot_help = cli('help', 'snapshot', raw=True).stdout.decode()
        check('snapshot help says options are shown and secrets never', all(words in snapshot_help for words in ['Select options, values and states are shown', 'password and card values never']))
        choose_help = cli('help', 'choose', raw=True).stdout.decode()
        check('choose help explains opaque final effects', 'Set final for opaque' in choose_help)
        def command(name, **args):
            words = ['go' if name == 'navigate' else 'read' if name == 'text' else name]
            for key, value in args.items():
                words.extend(['--' + key, str(value)])
            return cli(*words)
        tab = exercise(command, base, 'CLI')
        out = Path(tempfile.mkdtemp()) / 'export.pdf'
        check('CLI PDF -o', cli('pdf', '--tab', tab, '-o', str(out))['ok'] and out.read_bytes().startswith(b'%PDF'))
        check('CLI PDF pipe compatibility', cli('pdf', '--tab', tab, raw=True).stdout.startswith(b'%PDF'))
        shutil.rmtree(out.parent)
        client = MCP()
        names = {tool['name'] for tool in client.rpc('tools/list')['tools']}
        check('MCP catalog', {'console', 'network', 'pdf', 'hover', 'choose', 'dialog'} <= names)
        exercise(client.call, base, 'MCP')
        private = bench('open', base, 'private')
        for name in ['console', 'network', 'pdf', 'dialog']:
            check(name + ' private tab excluded', not client.call(name, tab=private[:8])['ok'])
        print('all good', flush=True)
    finally:
        if client:
            client.close()
        pids = subprocess.run(['lsof', '-t', '--', str(FOLDER / 'broadway.sock')], capture_output=True, text=True).stdout.split()
        for pid in pids:
            try:
                os.kill(int(pid), signal.SIGTERM)
            except ProcessLookupError:
                pass
        server.shutdown()
        time.sleep(.5)
        shutil.rmtree(FOLDER, ignore_errors=True)
        subprocess.run(['defaults', 'delete', SUITE], capture_output=True)


if __name__ == '__main__':
    main()
