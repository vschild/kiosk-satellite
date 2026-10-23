"""Exercise plugin settings buttons and plugin choices in a local browser fixture.

Run with Python 3 and Playwright's Chromium installed. No device is contacted.
"""
import copy
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1] / 'remote-ui'


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(ROOT)))
Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
plugin = {
    'id': 'bridge', 'name': 'Bridge', 'version': '1.0.0', 'description': 'Lights on a bridge',
    'capabilities': [], 'enabled': True, 'running': True, 'commands': [],
    'groups': [{'title': 'Connection'}],
    'settings': [
        {'key': 'host', 'title': 'Host', 'type': 'string', 'default': '', 'group': 'Connection'},
        {'key': 'token', 'title': 'Token', 'type': 'secret', 'default': '', 'group': 'Connection'},
        {'key': 'device', 'title': 'Light', 'type': 'string', 'default': '', 'choices': 'plugin', 'group': 'Connection',
         'description': 'The light this kiosk follows.'},
    ],
    'buttons': [
        {'id': 'test', 'title': 'Test connection', 'label': 'Test', 'group': 'Connection',
         'visibleWhen': {'key': 'host', 'notEmpty': True}},
        {'id': 'pair', 'title': 'Pair with the bridge', 'label': 'Pair', 'group': 'Connection',
         'confirm': {'title': 'Pair now?', 'message': 'Press the button on the bridge first.', 'confirmLabel': 'Pair now'}},
    ],
    'values': {'host': '', 'token': '__set__', 'device': 'lamp-2'},
}
installed = [copy.deepcopy(plugin)]
setup = {'runs': {}, 'choices': {}, 'choiceRevisions': {}, 'choicesOff': []}
requests = []
served = []


def list_choices(key, choices):
    # Like the host, every new list gets a new revision.
    setup['choices'][key] = choices
    setup['choiceRevisions'][key] = setup['choiceRevisions'].get(key, 0) + 1


def api(route):
    name = route.request.url.rsplit('/', 1)[-1]
    params = route.request.post_data_json or {}
    requests.append((name, params))
    if name == 'getPluginState':
        result = {'enabled': True, 'plugins': installed}
    elif name == 'configurePlugin':
        installed[0]['values'] = {**(installed[0]['values'] if params.get('patch') else {}), **params['values']}
        result = installed
    elif name == 'getPluginSetup':
        # A caller holding a list's revision does not get it again.
        held = params.get('choiceRevisions')
        result = {'runs': setup['runs'], 'choiceRevisions': setup['choiceRevisions'], 'choicesOff': setup['choicesOff'],
                  'choices': {k: v for k, v in setup['choices'].items()
                              if held is None or held.get(k) != setup['choiceRevisions'][k]}}
        served.append(result['choices'])
    elif name == 'runPluginSetup':
        target = f"{params['target']}:{params['key']}"
        setup['runs'][target] = {'run': f'run-{len(requests)}', 'state': 'running', 'message': '', 'code': '',
                                 'origin': 'remote', 'confirm': None}
        result = {'run': setup['runs'][target]['run']}
    elif name == 'cancelPluginSetup':
        setup['runs'] = {k: v for k, v in setup['runs'].items() if v['run'] != params['run']}
        result = None
    elif name == 'answerPluginSetup':
        for run in setup['runs'].values():
            if run['run'] == params['run']:
                run['confirm'] = None
        result = None
    elif name in ('getPluginCharts', 'getPluginReadings', 'getPluginStatusTiles'):
        result = []
    else:
        result = installed
    route.fulfill(json={'ok': True, 'data': result})


def calls(name):
    return [params for call, params in requests if call == name]


try:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=['--no-sandbox'])
        page = browser.new_page(viewport={'width': 1280, 'height': 1000})
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        html = (ROOT / 'index.html').read_text().replace('<script type="module" src="static/main.js?v=__KSV__"></script>', '')
        page.route(base + '/', lambda route: route.fulfill(body=html, content_type='text/html'))
        page.route('**/api/commands/*', api)
        page.goto(base + '/')
        page.evaluate("""async () => {
          (await import('/static/core.js')).showView('app');
          await (await import('/static/plugins.js')).loadPlugins();
          (await import('/static/tabs.js')).showTab('plugins/bridge', {refresh: false});
        }""")
        root = page.locator('#tab-plugins .subpage[data-subpage="bridge"]')
        refresh_setup = lambda: page.evaluate("async () => (await import('/static/plugin_setup.js')).refreshPluginSetup('bridge')")
        expect(page.locator('#pageTitle')).to_contain_text('Bridge')

        # The test button waits for a host. The pair button closes the group.
        expect(root.get_by_text('Test connection', exact=True)).to_have_count(0)
        pair_row = root.locator('[data-setup-target="button:pair"]')
        expect(pair_row).to_contain_text('Pair with the bridge')
        assert root.locator('.card:has([data-setup-target="button:pair"]) > .row').last.get_attribute('data-setup-target') == 'button:pair'

        # A confirm block asks first. Cancel sends nothing.
        pair = pair_row.get_by_role('button', name='Pair', exact=True)
        pair.click()
        expect(page.locator('.modal-card')).to_contain_text('Press the button on the bridge first.')
        page.locator('.modal-card').get_by_role('button', name='Cancel').click()
        assert calls('runPluginSetup') == []
        pair.click()
        page.locator('.modal-card').get_by_role('button', name='Pair now').click()
        expect(pair_row.get_by_role('button', name='Cancel')).to_be_visible()
        assert calls('runPluginSetup')[-1] == {'id': 'bridge', 'target': 'button', 'key': 'pair'}

        # Progress shows under the name. A question from the plugin opens
        # here, since this page started the run.
        run = setup['runs']['button:pair']
        run['message'] = 'Waiting for the bridge'
        refresh_setup()
        expect(pair_row.locator('.plugin-setup-status')).to_have_text('Waiting for the bridge')
        run['confirm'] = {'title': 'Trust this bridge?', 'message': 'SHA-256 AB:CD', 'confirmLabel': 'Trust'}
        refresh_setup()
        question = page.locator('.modal-card').filter(has_text='SHA-256 AB:CD')
        expect(question).to_be_visible()
        question.get_by_role('button', name='Trust').click()
        expect(question).to_have_count(0)
        assert calls('answerPluginSetup')[-1] == {'id': 'bridge', 'run': run['run'], 'accepted': True}

        # A question the run moved past closes on its own.
        run['confirm'] = {'title': 'Second step?', 'message': 'Hold the button.', 'confirmLabel': 'Done'}
        refresh_setup()
        second = page.locator('.modal-card').filter(has_text='Hold the button.')
        expect(second).to_be_visible()
        run['confirm'] = None
        refresh_setup()
        expect(second).to_have_count(0)

        # Cancel ends the run. A timed out run says so in error color.
        pair_row.get_by_role('button', name='Cancel').click()
        expect(pair_row.get_by_role('button', name='Pair', exact=True)).to_be_visible()
        assert calls('cancelPluginSetup')[-1] == {'id': 'bridge', 'run': run['run']}
        setup['runs']['button:pair'] = {**run, 'state': 'error', 'message': '', 'code': 'timeout'}
        refresh_setup()
        status = pair_row.locator('.plugin-setup-status')
        expect(status).to_have_text('The plugin did not answer in time.')
        expect(status).to_have_class('desc plugin-setup-status error')

        # The choice reads its label once the plugin lists it. A saved one
        # the list lacks is flagged.
        choice_row = root.locator('[data-setup-target="choices:device"]')
        expect(choice_row).to_contain_text('No choices yet. Refresh to look for them.')
        # Before the plugin lists any, the picker says so instead of a
        # Home Assistant connection error.
        choice_row.locator('.dp-field').click()
        card = page.locator('.dash-picker-card')
        expect(card).to_contain_text('No choices yet. Refresh to look for them.')
        expect(card).not_to_contain_text('Could not reach Home Assistant')
        card.get_by_role('button', name='Cancel').click()
        list_choices('device', [{'id': 'lamp-1', 'label': 'Kitchen'}, {'id': 'lamp-3', 'label': 'lamp-3'}])
        refresh_setup()
        expect(choice_row.locator('.dp-missing')).to_be_visible()
        choice_row.get_by_role('button', name='Refresh').click()
        assert calls('runPluginSetup')[-1] == {'id': 'bridge', 'target': 'choices', 'key': 'device'}
        expect(choice_row.locator('.plugin-setup-spinning')).to_have_count(1)
        choice_row.get_by_role('button', name='Cancel').click()
        expect(choice_row.locator('.plugin-setup-spinning')).to_have_count(0)

        # Picking saves only the choice's ID. The saved secret stays out.
        choice_row.locator('.dp-field').click()
        page.locator('.dash-picker-card').get_by_text('Kitchen', exact=True).click()
        expect(choice_row.locator('.dp-field')).to_contain_text('Kitchen')
        assert calls('configurePlugin')[-1] == {'id': 'bridge', 'values': {'device': 'lamp-1'}, 'patch': True}
        expect(choice_row.locator('.dp-missing')).to_be_hidden()

        # An unchanged list is not sent again.
        refresh_setup()
        assert calls('getPluginSetup')[-1]['choiceRevisions'] == {'device': 1}, calls('getPluginSetup')[-1]
        assert served[-1] == {}, served[-1]
        expect(choice_row.locator('.dp-field')).to_contain_text('Kitchen')

        # The plugin can turn the choice off, such as while its device is
        # unreachable: the picker and Refresh stop opening, the choice stays.
        setup['choicesOff'] = ['device']
        refresh_setup()
        expect(choice_row.locator('.dp-field')).to_be_disabled()
        expect(choice_row.get_by_role('button', name='Refresh')).to_be_disabled()
        expect(choice_row.locator('.dp-field')).to_contain_text('Kitchen')
        setup['choicesOff'] = []
        refresh_setup()
        expect(choice_row.locator('.dp-field')).to_be_enabled()
        expect(choice_row.get_by_role('button', name='Refresh')).to_be_enabled()

        # Groups head their choices in the order they appear. A detail is the
        # second line and search finds it. A choice without a group has no heading.
        list_choices('device', [
            {'id': 'lamp-1', 'label': 'Kitchen', 'group': 'Downstairs', 'detail': 'On, 80%'},
            {'id': 'lamp-4', 'label': 'Bedroom', 'group': 'Upstairs', 'detail': 'Off'},
            {'id': 'lamp-5', 'label': 'Porch'},
            {'id': 'lamp-6', 'label': 'Hall', 'group': 'Downstairs'},
        ])
        refresh_setup()
        assert served[-1] == {'device': setup['choices']['device']}, served[-1]
        choice_row.locator('.dp-field').click()
        picker = page.locator('.dash-picker-card')
        expect(picker.locator('.ep-heading')).to_have_count(2)
        expect(picker.locator('.ep-heading').first).to_contain_text('Downstairs')
        text = picker.inner_text()
        assert text.index('Downstairs') < text.index('Upstairs'), text
        assert text.index('Hall') < text.index('Upstairs'), text
        expect(picker).to_contain_text('On, 80%')
        expect(picker).not_to_contain_text('lamp-4')
        picker.get_by_role('searchbox').fill('80%')
        expect(picker).to_contain_text('Kitchen')
        expect(picker).not_to_contain_text('Bedroom')
        picker.get_by_role('searchbox').fill('upstairs')
        expect(picker).to_contain_text('Bedroom')
        expect(picker).not_to_contain_text('Kitchen')
        # Picking the saved choice again saves nothing.
        picker.get_by_role('searchbox').fill('kitchen')
        picker.get_by_text('Kitchen', exact=True).click()
        expect(picker).to_have_count(0)
        assert calls('configurePlugin')[-1] == {'id': 'bridge', 'values': {'device': 'lamp-1'}, 'patch': True}

        # Filling in the host brings its button. A text edit saves before the
        # button press reaches the plugin.
        host = root.get_by_role('textbox', name='Host')
        host.fill('bridge.local')
        host.press('Tab')
        test_row = root.locator('[data-setup-target="button:test"]')
        expect(test_row).to_be_visible()
        assert installed[0]['values'] == {'host': 'bridge.local', 'token': '__set__', 'device': 'lamp-1'}
        host = root.get_by_role('textbox', name='Host')
        host.fill('bridge.lan')
        test_row.get_by_role('button', name='Test').click()
        expect(root.locator('[data-setup-target="button:test"]').get_by_role('button', name='Cancel')).to_be_visible()
        order = [call for call, _ in requests if call in ('configurePlugin', 'runPluginSetup')]
        assert order[-2:] == ['configurePlugin', 'runPluginSetup'], order
        assert installed[0]['values']['host'] == 'bridge.lan'

        # A stopped plugin cannot answer, so its buttons are off.
        installed[0]['running'] = False
        page.evaluate("""async () => {
          await (await import('/static/plugins.js')).loadPlugins();
          (await import('/static/tabs.js')).showTab('plugins/bridge', {refresh: false});
        }""")
        expect(root.locator('[data-setup-target="button:pair"] .plugin-setup-start')).to_be_disabled()
        expect(root.locator('[data-setup-target="choices:device"] .plugin-setup-start')).to_be_disabled()

        # Narrow screens keep the picker and Refresh on one line.
        page.set_viewport_size({'width': 380, 'height': 900})
        field = root.locator('[data-setup-target="choices:device"] .dp-field').bounding_box()
        button = root.locator('[data-setup-target="choices:device"] .plugin-setup-start').bounding_box()
        assert abs(field['y'] + field['height'] / 2 - (button['y'] + button['height'] / 2)) < 4, (field, button)
        assert button['x'] + button['width'] <= 380, button
        assert errors == [], errors
        browser.close()
    print('PASS: settings buttons, confirmations, plugin questions, cancel, timeouts, plugin choices, choice revisions, groups and details, patch saves and narrow layout.')
finally:
    server.shutdown()
