"""Allowed Apps (issue #1067): a switch per launcher app, saved in the launcher's order."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from threading import Thread
from playwright.sync_api import sync_playwright, expect

APP = Path(__file__).resolve().parents[1]
ROOT = APP / 'remote-ui'
english = {k:v for p in (APP/'l10n/source').glob('*_en.arb') for k,v in json.loads(p.read_text()).items() if not k.startswith('@')}
apps = [{'package':'com.a','label':'<b>Alpha</b>'},{'package':'com.b','label':'Beta'},{'package':'com.c','label':'Gamma'}]
settings = [dict(key='ui.language',value='en',type='string',category='Device',hidden=True),
            dict(key='launcher.enabled',value=True,type='boolean',category='Launcher',hidden=True),
            dict(key='launcher.apps',value=json.dumps(apps),type='string',category='Launcher',hidden=True),
            dict(key='kiosk.allowed_apps',value='["com.c"]',type='string',category='Kiosk',
                 title='Allowed Apps',description='The launcher apps offered while kiosk mode is on.')]
writes = []
fail = False
def api(route):
    path = route.request.url.split('/api/',1)[1]
    if path == 'settings':
        if route.request.method == 'PATCH':
            if fail: return route.fulfill(status=500, json={'ok':False,'error':'nope'})
            values = route.request.post_data_json; writes.append(values)
            for item in settings:
                if item['key'] in values: item['value'] = values[item['key']]
            return route.fulfill(json={'ok':True})
        return route.fulfill(json={'settings':settings,'subpageHints':{}})
    route.fulfill(json={'ok':True,'data':{}})
class Handler(SimpleHTTPRequestHandler):
    def log_message(self,*_): pass
server = ThreadingHTTPServer(('127.0.0.1',0),partial(Handler,directory=str(ROOT)))
Thread(target=server.serve_forever,daemon=True).start(); base = f'http://127.0.0.1:{server.server_port}'
try:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True,args=['--no-sandbox']); page = browser.new_page()
        errors = []; page.on('pageerror',lambda e: errors.append(str(e)))
        html = (ROOT/'index.html').read_text().replace('<script type="module" src="static/main.js?v=__KSV__"></script>','')
        page.route(base+'/',lambda route: route.fulfill(body=html,content_type='text/html'))
        page.route('**/static/catalogs.js',lambda route: route.fulfill(body='export const catalogs = '+json.dumps({'en':english})+';',content_type='text/javascript'))
        page.route('**/api/**',api); page.goto(base+'/')
        draw = """async()=>{
          await (await import('/static/settings.js')).loadSettings();
          const {state} = await import('/static/core.js');
          const card = document.createElement('div'); card.id = 'card'; document.body.appendChild(card);
          card.appendChild((await import('/static/rows.js')).settingRow(state.settings.find((o) => o.key === 'kiosk.allowed_apps')));
        }"""
        page.evaluate(draw)
        rows = page.locator('#card .row')
        expect(rows).to_have_count(3)
        # Labels are text, never markup.
        expect(rows.nth(0)).to_contain_text('<b>Alpha</b>')
        assert page.locator('#card b').count() == 0
        boxes = page.locator('#card input[type="checkbox"]')
        assert [boxes.nth(i).is_checked() for i in range(3)] == [False, False, True]
        # Saved in the launcher's order, whatever order they are switched on.
        page.locator('#card .switch').nth(1).click()
        page.wait_for_timeout(100)
        page.locator('#card .switch').nth(0).click()
        page.wait_for_timeout(100)
        assert writes[-1] == {'kiosk.allowed_apps': '["com.a","com.b","com.c"]'}, writes
        # A failed save puts the switch back and says so on its row.
        fail = True
        page.locator('#card .switch').nth(2).click()
        expect(rows.nth(2).locator('.row-error')).to_be_visible()
        assert boxes.nth(2).is_checked()
        fail = False
        # No launcher apps: the row points at the App Launcher page.
        settings[2]['value'] = '[]'
        page.evaluate("()=>document.getElementById('card').remove()")
        page.evaluate(draw)
        expect(page.locator('#card .row')).to_have_count(1)
        expect(page.locator('#card')).to_contain_text(english['kioskAllowedAppsEmpty'])
        assert not errors, errors
        browser.close()
finally: server.shutdown()
print('Allowed Apps browser rows passed.')
