"""Exercise plugin list settings and the picker setting types in a local browser fixture.

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
entries = {
    'key': 'entries', 'title': 'Entries', 'type': 'list', 'addTitle': 'Add entry', 'minItems': 1,
    'visibleWhen': {'key': 'opens', 'equals': 'Menu'},
    'fields': [
        {'key': 'label', 'title': 'Label', 'type': 'string', 'required': True},
        {'key': 'url', 'title': 'Address', 'type': 'string'},
    ],
}
plugin = {
    'id': 'navbar', 'name': 'Navbar', 'version': '1.0.0', 'description': 'A navigation bar',
    'capabilities': ['overlay'], 'enabled': True, 'running': True, 'commands': [],
    'groups': [{'title': 'Behavior'}, {'title': 'Items'}],
    'settings': [
        {'key': 'collapse', 'title': 'Collapse', 'type': 'select', 'options': ['Off', 'On'], 'default': 'Off', 'group': 'Behavior'},
        {'key': 'after', 'title': 'Collapse after', 'type': 'number', 'min': 0, 'max': 60, 'default': 0, 'group': 'Behavior',
         'visibleWhen': {'key': 'collapse', 'notEquals': 'Off'}},
        {'key': 'tabIcon', 'title': 'Tab icon', 'type': 'icon', 'default': '', 'group': 'Behavior'},
        {'key': 'items', 'title': 'Items', 'type': 'list', 'group': 'Items', 'addTitle': 'Add item', 'default': [],
         'row': {'title': 'label', 'subtitle': ['url', 'camera', 'opens'], 'icon': 'icon'},
         'fields': [
             {'key': 'label', 'title': 'Label', 'type': 'string', 'required': True},
             {'key': 'icon', 'title': 'Icon', 'type': 'icon'},
             {'key': 'opens', 'title': 'Opens', 'type': 'select', 'options': ['Web address', 'Camera view', 'Menu']},
             {'key': 'url', 'title': 'Address', 'type': 'string', 'required': True,
              'visibleWhen': {'key': 'opens', 'equals': 'Web address'}},
             {'key': 'camera', 'title': 'Camera view', 'type': 'cameraView', 'required': True,
              'visibleWhen': {'key': 'opens', 'equals': 'Camera view'}},
             entries,
         ]},
    ],
    'values': {
        'collapse': 'Off', 'after': 0, 'tabIcon': '',
        'items': [{'label': 'Home', 'icon': 'mdi:home', 'opens': 'Web address', 'url': 'https://example.com', 'camera': '', 'entries': []}],
    },
}
sensors = {
    'id': 'sensors', 'name': 'Sensors', 'version': '1.0.0', 'description': 'Entity lists',
    'capabilities': [], 'enabled': True, 'running': True, 'commands': [], 'groups': [],
    'settings': [
        {'key': 'sensors', 'title': 'Sensors', 'type': 'list', 'default': [], 'row': {'title': 'entity'},
         'fields': [{'key': 'entity', 'title': 'Entity', 'type': 'entity'}]},
        {'key': 'buttons', 'title': 'Buttons', 'type': 'list', 'default': [], 'row': {'title': 'label', 'subtitle': 'target'},
         'fields': [{'key': 'label', 'title': 'Label', 'type': 'string'}, {'key': 'target', 'title': 'Target', 'type': 'entity'}]},
    ],
    'values': {
        'sensors': [{'entity': 'sensor.room'}, {'entity': 'sensor.gone'}],
        'buttons': [{'label': 'Porch', 'target': 'light.porch'}],
    },
}
entities = [
    {'entity_id': 'sensor.room', 'name': 'Room temperature', 'state': '21 °C', 'domain': 'sensor', 'icon_path': 'M15,13V5A3,3 0 0,0 9,5V13A5,5 0 1,0 15,13M12,4A1,1 0 0,1 13,5V8H11V5A1,1 0 0,1 12,4Z'},
    {'entity_id': 'light.porch', 'name': 'Porch light', 'state': 'On', 'domain': 'light'},
]
installed = [copy.deepcopy(plugin), sensors]
icons = {'mdi:home': 'M10,20V14H14V20H19V12H22L12,3L2,12H5V20H10Z', 'mdi:garage': 'M19,20H17V11H7V20H5V9L12,5L19,9V20Z',
         'mdi:garage-open': 'M19,20H17V11H7V20H5V9L12,5L19,9V20M8,12H16V14H8Z', 'mdi:cctv': 'M18.15,4.94L4,6Z'}
saved = []


def api(route):
    name = route.request.url.rsplit('/', 1)[-1]
    params = route.request.post_data_json or {}
    if name == 'getPluginState':
        result = {'enabled': True, 'plugins': installed}
    elif name == 'configurePlugin':
        # A patch writes over the saved values, like the host.
        installed[0]['values'] = {**(installed[0]['values'] if params.get('patch') else {}), **copy.deepcopy(params['values'])}
        saved.append(copy.deepcopy(params['values']))
        result = installed
    elif name == 'searchIcons':
        if 'names' in params:
            result = [{'name': n, 'path': icons[n]} for n in params['names'] if n in icons]
        else:
            words = params.get('query', '').split()
            result = [{'name': n, 'path': p} for n, p in icons.items() if all(w in n for w in words)]
    elif name == 'haListEntities':
        result = entities
    elif name == 'cameraGetConfig':
        result = {'cameras': [], 'views': [{'id': 'a1b2c3d4e5f60718293a4b5c6d7e8f90', 'name': 'Front door', 'cameraIds': ['c1']},
                                           {'id': 'default', 'name': 'Default', 'cameraIds': []}]}
    elif name in ('getPluginCharts', 'getPluginReadings', 'getPluginStatusTiles'):
        result = []
    else:
        result = installed
    route.fulfill(json={'ok': True, 'data': result})


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
          (await import('/static/tabs.js')).showTab('plugins/navbar', {refresh: false});
        }""")
        root = page.locator('#tab-plugins > .subpage[data-subpage="navbar"]')
        expect(page.locator('#pageTitle')).to_contain_text('Navbar')
        # A setting whose condition fails stays off the page. The list,
        # alone in its group, has no title row of its own.
        expect(root.get_by_text('Collapse after', exact=True)).to_have_count(0)
        expect(root.locator('.plugin-list > .row:not(.plugin-list-row)')).to_have_count(0)
        rows = root.locator('.plugin-list-row')
        expect(rows).to_have_count(1)
        expect(rows.first).to_contain_text('Home')
        expect(rows.first).to_contain_text('https://example.com')
        expect(rows.first.locator('.camera-row-icon svg path')).to_have_attribute('d', icons['mdi:home'])

        # Editing a row saves the whole list.
        rows.first.click()
        modal = page.locator('.modal-card')
        expect(modal.locator('.modal-title')).to_have_text('Home')
        modal.locator('.form-field:has-text("Label") input').fill('House')
        modal.get_by_role('button', name='Save', exact=True).click()
        expect(modal).to_have_count(0)
        assert saved[-1]['items'][0]['label'] == 'House', saved[-1]
        expect(rows.first).to_contain_text('House')

        # A new row waits for its required fields, a nested row included.
        root.get_by_text('Add item', exact=True).click()
        save = modal.get_by_role('button', name='Save', exact=True)
        expect(save).to_be_disabled()
        expect(modal.get_by_role('button', name='Delete', exact=True)).to_have_count(0)
        modal.locator('.form-field:has-text("Label") input').fill('Cameras')
        modal.locator('.form-field:has-text("Opens") select').select_option('Menu')
        expect(modal.get_by_text('Address', exact=True)).to_have_count(0)
        expect(modal.locator('.form-field:has-text("Entries") .plugin-required')).to_be_visible()
        expect(save).to_be_disabled()
        modal.get_by_text('Add entry', exact=True).click()
        expect(modal.locator('.modal-title')).to_contain_text('Add entry')
        expect(modal.get_by_role('button', name='Back', exact=True)).to_be_visible()
        modal.locator('.form-field:has-text("Label") input').fill('Front door')
        modal.get_by_role('button', name='Done', exact=True).click()
        expect(modal.locator('.modal-title')).to_have_text('Add item')
        expect(modal.locator('.plugin-list-box')).to_contain_text('Front door')
        # The icon picker searches the kiosk's icons as you type.
        modal.locator('.form-field:has-text("Icon") .dp-field').click()
        picker = page.locator('.modal-card').last
        picker.get_by_role('searchbox').fill('garage open')
        expect(picker.locator('.plugin-icon-cell')).to_have_count(1)
        picker.locator('.plugin-icon-cell').click()
        expect(modal.locator('.form-field:has-text("Icon") .dp-field')).to_contain_text('mdi:garage-open')
        expect(save).to_be_enabled()
        save.click()
        expect(modal).to_have_count(0)
        assert saved[-1]['items'][1] == {'label': 'Cameras', 'icon': 'mdi:garage-open', 'opens': 'Menu', 'url': '', 'camera': '',
                                         'entries': [{'label': 'Front door', 'url': ''}]}, saved[-1]

        # Arrows move a row for screens without drag.
        rows.nth(1).get_by_role('button', name='Move up', exact=True).click()
        expect(rows.first).to_contain_text('Cameras')
        assert [i['label'] for i in saved[-1]['items']] == ['Cameras', 'House']

        # A camera view row shows the view's name.
        rows.nth(1).click()
        modal.locator('.form-field:has-text("Opens") select').select_option('Camera view')
        modal.locator('.form-field:has-text("Camera view") .ep-field').click()
        page.locator('.dash-picker-card').get_by_text('Front door', exact=True).click()
        save.click()
        assert saved[-1]['items'][1]['camera'] == 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        expect(rows.nth(1)).to_contain_text('Front door')

        # Delete takes the row out.
        rows.nth(1).click()
        modal.get_by_role('button', name='Delete', exact=True).click()
        expect(rows).to_have_count(1)
        assert [i['label'] for i in saved[-1]['items']] == ['Cameras']

        # A top-level icon setting saves on pick.
        root.locator('.row:has-text("Tab icon") .dp-field').click()
        page.locator('.modal-card').get_by_role('searchbox').fill('garage')
        page.locator('.plugin-icon-cell[title="mdi:garage"]').click()
        expect(root.locator('.row:has-text("Tab icon") .dp-field')).to_contain_text('mdi:garage')
        assert saved[-1]['tabIcon'] == 'mdi:garage'

        # Turning the condition's setting on brings its dependent back.
        root.locator('.row:has-text("Collapse") select').first.select_option('On')
        expect(root.get_by_text('Collapse after', exact=True)).to_be_visible()
        page.screenshot(path='/tmp/kiosk-plugin-list-settings.png', full_page=True)

        # Entity fields show the entity's name, icon and state, and an
        # entity Home Assistant lacks keeps its id with a warning.
        page.evaluate("(async () => (await import('/static/tabs.js')).showTab('plugins/sensors', {refresh: false}))()")
        expect(page.locator('#pageTitle')).to_contain_text('Sensors')
        rows = page.locator('#tab-plugins > .subpage[data-subpage="sensors"] .plugin-list-row')
        expect(rows).to_have_count(3)
        expect(rows.nth(0).locator('.name')).to_have_text('Room temperature')
        expect(rows.nth(0).locator('.desc')).to_have_text('21 °C · sensor.room')
        expect(rows.nth(0).locator('.camera-row-main .camera-row-icon svg path')).to_have_attribute('d', entities[0]['icon_path'])
        expect(rows.nth(1).locator('.name')).to_have_text('sensor.gone')
        expect(rows.nth(1).locator('.desc')).to_have_count(0)
        expect(rows.nth(1).locator('.plugin-row-missing')).to_have_count(1)
        expect(rows.nth(2).locator('.name')).to_have_text('Porch')
        expect(rows.nth(2).locator('.desc')).to_have_text('Porch light · On')
        expect(rows.nth(2).locator('.camera-row-main .camera-row-icon')).to_have_count(0)
        page.screenshot(path='/tmp/kiosk-plugin-list-entities.png', full_page=True)
        assert not errors, errors
        browser.close()
finally:
    server.shutdown()
print('plugin list remote UI test passed')
