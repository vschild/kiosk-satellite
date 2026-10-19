import { deviceText, pluginError, pluginText } from './localization.js';
import { cmd } from './core.js';
import { loadList, pickField, pickItem } from './entity_picker.js';
import { messageBox, modalShell, showToast } from './widgets.js';

/* Settings page buttons and plugin choices, the browser's side of
   plugin_setup.dart. The host owns each run: Start asks the plugin to work,
   the plugin reports progress or an outcome, and this page paints what the
   host says. Questions a plugin asks during a run started here open as a
   dialog. A row carries its run target in data-setup-target. */

const REFRESH = 'M21 12a9 9 0 1 1-2.64-6.36M21 3v6h-6';
const states = new Map();
const choiceLists = new Map();
const asked = new Set();

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function info(title, description = '') {
  const node = element('div', undefined, 'info'); node.append(element('div', title, 'name'));
  if (description) node.append(element('div', description, 'desc'));
  return node;
}

const pageOf = (id) => [...document.querySelectorAll('#tab-plugins > .subpage')].find((el) => el.dataset.subpage === id);
const runOf = (id, target) => states.get(id)?.runs?.[target] || null;

async function start(plugin, target, key, settled) {
  // A text field saves as it loses focus, so the plugin sees it first.
  await settled();
  const result = await cmd('runPluginSetup', { id: plugin.id, target, key }, { timeoutMs: 15000 });
  if (!result.ok) {
    showToast({ title: pluginText('Plugin'), message: pluginError(result.error), kind: 'error' });
    return;
  }
  await refreshPluginSetup(plugin.id);
}

async function cancel(plugin, target) {
  const run = runOf(plugin.id, target);
  if (!run) return;
  await cmd('cancelPluginSetup', { id: plugin.id, run: run.run }, { timeoutMs: 15000 });
  await refreshPluginSetup(plugin.id);
}

// A manifest button: the title and description, the run's progress or
// outcome below, and the button, which reads Cancel while it runs.
export function setupButtonRow(plugin, button, settled) {
  const target = `button:${button.id}`;
  const row = element('div', undefined, 'row plugin-setup-row');
  row.dataset.searchId = `plugin:${plugin.id}:button:${button.id}`;
  row.dataset.setupTarget = target;
  const text = info(button.title, button.description || '');
  text.append(element('div', undefined, 'desc plugin-setup-status'));
  const press = element('button', button.label, 'btn-ghost plugin-setup-start'); press.type = 'button';
  press.dataset.label = button.label;
  press.onclick = async () => {
    if (row.dataset.running === 'true') { await cancel(plugin, target); return; }
    const confirm = button.confirm;
    if (confirm) {
      const answer = await messageBox({ title: confirm.title, message: confirm.message,
        buttons: ['Cancel', confirm.confirmLabel], buttonText: (label) => (label === 'Cancel' ? pluginText('Cancel') : label) });
      if (answer !== confirm.confirmLabel) return;
    }
    await start(plugin, 'button', button.id, settled);
  };
  row.append(text, press);
  paint(row, plugin.id, plugin.running === true);
  if (!states.has(plugin.id)) refreshPluginSetup(plugin.id);
  return row;
}

// The picked choice by its label and Refresh beside it, which spins and
// cancels while the plugin looks.
export function choiceControl(plugin, setting, value, settled, onPick) {
  const spec = choiceSpec(plugin.id, setting.key);
  let picked = value;
  const field = pickField({
    spec, value, placeholder: deviceText('Not set'), enabled: plugin.running === true || !!value,
    onClick: async () => {
      const out = await pickItem({ title: setting.title, spec, selected: picked || null, allowClear: true });
      if (!out || (out.id ?? '') === picked) return;
      picked = out.id ?? '';
      await onPick(picked, field.el);
      field.setValue(picked);
    },
  });
  const target = `choices:${setting.key}`;
  const refresh = element('button', undefined, 'icon-btn plugin-setup-start'); refresh.type = 'button';
  refresh.title = pluginText('Refresh'); refresh.setAttribute('aria-label', refresh.title);
  // Only application-owned SVG paths reach innerHTML.
  refresh.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="${REFRESH}"/></svg>`;
  const control = element('div', undefined, 'plugin-choice');
  control.append(field.el, refresh);
  const status = element('div', undefined, 'desc plugin-setup-status');
  const missing = element('div', pluginText('This choice is no longer listed.'), 'desc dp-missing'); missing.hidden = true;
  field.el.addEventListener('dp-painted', (event) => { missing.hidden = !event.detail.missing; });
  return {
    control,
    // Placed under the row's name and description.
    lines: [missing, status],
    attach(row) {
      row.dataset.setupTarget = target;
      refresh.onclick = async () => {
        if (row.dataset.running === 'true') await cancel(plugin, target);
        else await start(plugin, 'choices', setting.key, settled);
      };
      paint(row, plugin.id, plugin.running === true);
      if (!states.has(plugin.id)) refreshPluginSetup(plugin.id);
    },
  };
}

function choiceSpec(id, key) {
  return {
    key: `pluginChoices:${id}:${key}`,
    loader: async () => {
      const choices = states.get(id)?.choices?.[key];
      if (!choices) return null;
      return { items: choices.map((choice) => ({ id: choice.id, name: choice.label, sub: choice.label === choice.id ? '' : choice.id,
        subMono: true, group: '', available: true })), notes: {} };
    },
    searchHint: pluginText('Search'),
    noGroup: '', chips: false, headings: false, byGroupName: false, keep: null,
  };
}

function paint(row, id, running) {
  const state = states.get(id) || {};
  const target = row.dataset.setupTarget;
  const run = state.runs?.[target] || null;
  const busy = run?.state === 'running';
  row.dataset.running = String(busy);
  const start = row.querySelector('.plugin-setup-start');
  if (start) {
    start.dataset.pluginDisabled = String(!running);
    start.disabled = !running;
    if (start.dataset.label) {
      start.textContent = busy ? pluginText('Cancel') : start.dataset.label;
      start.classList.toggle('plugin-setup-running', busy);
    } else {
      start.classList.toggle('plugin-setup-spinning', busy);
      start.title = pluginText(busy ? 'Cancel' : 'Refresh');
      start.setAttribute('aria-label', start.title);
    }
  }
  const status = row.querySelector('.plugin-setup-status');
  if (!status) return;
  let text = run?.code === 'timeout' ? pluginText('The plugin did not answer in time.') : (run?.message || '');
  if (!text && running && target.startsWith('choices:') && !state.choices?.[target.slice('choices:'.length)]?.length) {
    text = pluginText('No choices yet. Refresh to look for them.');
  }
  status.textContent = text;
  status.hidden = !text;
  status.classList.toggle('error', run?.state === 'error');
}

// Reads one plugin's runs and choices and paints its open page.
export async function refreshPluginSetup(id) {
  const result = await cmd('getPluginSetup', { id }, { timeoutMs: 5000 }).catch(() => null);
  if (!result?.ok) return;
  states.set(id, result.data || { runs: {}, choices: {} });
  applyPluginSetup(id);
}

export function applyPluginSetup(id) {
  const page = pageOf(id);
  const state = states.get(id) || { runs: {}, choices: {} };
  if (page) {
    const running = page.dataset.pluginRunning === 'true';
    for (const row of page.querySelectorAll('[data-setup-target]')) paint(row, id, running);
  }
  for (const [key, choices] of Object.entries(state.choices || {})) {
    const listKey = `${id}:${key}`;
    const json = JSON.stringify(choices);
    if (choiceLists.get(listKey) === json) continue;
    choiceLists.set(listKey, json);
    loadList(choiceSpec(id, key));
  }
  for (const run of Object.values(state.runs || {})) {
    if (run.origin !== 'remote' || !run.confirm) continue;
    const question = `${run.run}/${run.confirm.title}/${run.confirm.message}`;
    if (asked.has(question)) continue;
    asked.add(question);
    ask(id, run.run, run.confirm);
  }
}

// The plugin's question. It closes without an answer once the run moves on.
function ask(id, run, confirm) {
  const shell = modalShell({ title: confirm.title });
  const message = element('p', confirm.message);
  message.style.cssText = 'margin:0; color:var(--muted); font-size:15px; line-height:1.5; white-space:pre-line;';
  shell.body.append(message);
  let open = true;
  const answer = async (accepted) => {
    if (!open) return;
    open = false; shell.close();
    await cmd('answerPluginSetup', { id, run, accepted }, { timeoutMs: 15000 });
    await refreshPluginSetup(id);
  };
  const no = element('button', pluginText('Cancel'), 'btn-text'); no.type = 'button'; no.onclick = () => answer(false);
  const yes = element('button', confirm.confirmLabel, 'btn-primary'); yes.type = 'button'; yes.onclick = () => answer(true);
  shell.foot.append(no, yes);
  const watch = setInterval(() => {
    const current = Object.values(states.get(id)?.runs || {}).find((entry) => entry.run === run);
    if (!open || !current?.confirm) { clearInterval(watch); if (open) { open = false; shell.close(); } }
  }, 500);
}
