import { deviceText, t } from './localization.js';
import { api, state } from './core.js';
import { cameraAction, cameraListRow } from './cameras.js';
import { cachedList, entitySpec, loadEntityList, pickEntity, pickField, pickItem } from './entity_picker.js';
import { modalShell, parseRgb, pickColor, showToast } from './widgets.js';

/* ---- Calendar ----
   Home Assistant's calendars on the kiosk. The generic renderer draws the
   Display and Kiosk cards from the definitions. This module puts the
   Calendars card above them: each calendar with its
   avatar, name and entity, a switch, a tap to edit its name, color and
   person, and Add a calendar. The list lives in calendar.calendars.
   Mirrors the device's Settings > Calendar. */

// The device's palette, in its order (calendar_model.dart).
const PALETTE = [
  ['Teal', '72,130,132', 'calendarColorTeal'], ['Rust', '192,97,58', 'calendarColorRust'],
  ['Blue', '76,111,165', 'calendarColorBlue'], ['Plum', '138,90,156', 'calendarColorPlum'],
  ['Ochre', '168,122,31', 'calendarColorOchre'], ['Sage', '86,129,79', 'calendarColorSage'],
  ['Rose', '181,87,122', 'calendarColorRose'], ['Slate', '107,114,128', 'calendarColorSlate'],
];

const byKey = (key) => (state.settings || []).find((s) => s.key === key);

function calendars() {
  try {
    const list = JSON.parse(`${byKey('calendar.calendars')?.value ?? '[]'}`);
    return Array.isArray(list) ? list.filter((c) => `${c?.entity || ''}`.startsWith('calendar.')) : [];
  } catch (_) {
    return [];
  }
}

async function save(list) {
  const value = JSON.stringify(list);
  try {
    const res = await api('/api/settings', { method: 'PATCH', body: JSON.stringify({ 'calendar.calendars': value }) });
    const result = await res.json().catch(() => ({}));
    if (!res.ok || result.ok === false || result.rejected?.includes('calendar.calendars')) {
      throw new Error(result.error || '');
    }
    const s = byKey('calendar.calendars');
    if (s) s.value = value;
    renderCalendarPage();
    return true;
  } catch (e) {
    showToast({ title: t('commonSaveFailed'), message: String(e.message || e), kind: 'error' });
    return false;
  }
}

const nextColor = (list) => {
  const used = new Set(list.map((c) => c.color));
  return (PALETTE.find(([, rgb]) => !used.has(rgb)) || PALETTE[list.length % PALETTE.length])[1];
};

// The calendar's initial on its color, the device's avatar. The disc is a
// step darker than the color so the white initial reads.
function avatar(source) {
  const disc = document.createElement('span');
  disc.className = 'calendar-avatar';
  const [r, g, b] = parseRgb(source.color);
  const dim = (c) => Math.round(c * 0.82);
  disc.style.background = `rgb(${dim(r)}, ${dim(g)}, ${dim(b)})`;
  const name = `${source.name || ''}`.trim();
  disc.textContent = name ? [...name][0].toUpperCase() : '?';
  disc.setAttribute('aria-hidden', 'true');
  return disc;
}

function switchControl(checked, label, onChange) {
  const lbl = document.createElement('label');
  lbl.className = 'switch';
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.checked = checked;
  input.setAttribute('aria-label', label);
  const slider = document.createElement('span');
  slider.className = 'slider';
  lbl.append(input, slider);
  input.addEventListener('change', () => onChange(input));
  return lbl;
}

function field(label, control) {
  const wrap = document.createElement('div');
  wrap.className = 'form-field';
  const title = document.createElement('span');
  title.className = 'desc';
  title.textContent = label;
  wrap.append(title, control);
  return wrap;
}

function button(label, cls, onClick) {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = cls;
  b.textContent = label;
  b.addEventListener('click', onClick);
  return b;
}

/* ---- the editor ----
   Name, color (the eight palette swatches and Custom) and person. Remove
   takes the calendar off the list. */
function openEditor(source) {
  const draft = { ...source };
  const shell = modalShell({ title: source.name || source.entity, width: 460, onDismiss: () => shell.close() });
  const form = document.createElement('div');
  form.className = 'modal-form';

  const name = document.createElement('input');
  name.type = 'text';
  name.className = 'field';
  name.maxLength = 40;
  name.value = source.name || '';

  const swatches = document.createElement('div');
  swatches.className = 'calendar-swatches';
  swatches.setAttribute('role', 'radiogroup');
  swatches.setAttribute('aria-label', t('calendarEditColor'));
  const paint = () => {
    for (const el of swatches.children) {
      const on = el.dataset.rgb ? el.dataset.rgb === draft.color
        : !PALETTE.some(([, rgb]) => rgb === draft.color);
      el.classList.toggle('on', on);
      el.setAttribute('aria-checked', on ? 'true' : 'false');
      if (!el.dataset.rgb) el.style.background = on ? `rgb(${parseRgb(draft.color).join(', ')})` : '';
    }
  };
  for (const [, rgb, id] of PALETTE) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'calendar-swatch';
    b.dataset.rgb = rgb;
    b.style.setProperty('--swatch', `rgb(${rgb.split(',').join(', ')})`);
    b.title = t(id);
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-label', t(id));
    b.addEventListener('click', () => { draft.color = rgb; paint(); });
    swatches.appendChild(b);
  }
  const custom = document.createElement('button');
  custom.type = 'button';
  custom.className = 'calendar-swatch custom';
  custom.title = t('calendarColorCustom');
  custom.setAttribute('role', 'radio');
  custom.setAttribute('aria-label', t('calendarColorCustom'));
  custom.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 22a10 10 0 1 1 10-10c0 2.5-2 3.5-4 3.5h-2a2 2 0 0 0-1.5 3.3A2 2 0 0 1 12 22z"/><circle cx="7.5" cy="10.5" r="1"/><circle cx="12" cy="7.5" r="1"/><circle cx="16.5" cy="10.5" r="1"/></svg>';
  custom.addEventListener('click', async () => {
    const picked = await pickColor({ title: t('calendarColorCustom'), rgb: draft.color });
    if (picked == null) return;
    draft.color = picked;
    paint();
  });
  swatches.appendChild(custom);
  paint();

  // The person, picked from Home Assistant's people, with the hint under
  // the field.
  const people = entitySpec({ domains: ['person'] });
  const person = pickField({
    spec: people,
    value: source.person || '',
    placeholder: t('calendarEditPersonNone'),
    onClick: async () => {
      const out = await pickItem({ title: t('calendarPickPerson'), spec: people,
        selected: draft.person || null, allowClear: true });
      if (!out) return;
      draft.person = out.id || '';
      person.setValue(draft.person);
    },
  });
  const personField = field(t('calendarEditPerson'), person.el);
  const personHint = document.createElement('span');
  personHint.className = 'desc';
  personHint.textContent = t('calendarEditPersonHint');
  personField.appendChild(personHint);

  form.append(field(t('calendarEditName'), name), field(t('calendarEditColor'), swatches), personField);
  shell.body.appendChild(form);

  const remove = button(t('commonRemove'), 'btn-text danger', async () => {
    remove.disabled = true;
    if (await save(calendars().filter((c) => c.entity !== source.entity))) shell.close();
    else remove.disabled = false;
  });
  const cancel = button(t('commonCancel'), 'btn-text', () => shell.close());
  const ok = button(t('commonSave'), 'btn-primary', async () => {
    ok.disabled = true;
    const edited = { ...source, name: name.value.trim() || source.name, color: draft.color };
    if (draft.person) edited.person = draft.person; else delete edited.person;
    const list = calendars().map((c) => (c.entity === source.entity ? edited : c));
    if (await save(list)) shell.close();
    else ok.disabled = false;
  });
  shell.card.classList.add('calendar-editor');
  shell.foot.append(remove, cancel, ok);
}

async function addCalendar() {
  const out = await pickEntity({ title: t('calendarPickCalendar'), domains: ['calendar'] });
  const id = out?.id;
  if (!id) return;
  const list = calendars();
  if (list.some((c) => c.entity === id)) {
    showToast({ title: t('calendarAlreadyAdded'), kind: 'info' });
    return;
  }
  await loadEntityList().catch(() => {});
  const item = (cachedList('entities')?.items || []).find((e) => e.id === id);
  const source = { entity: id, name: item?.name || id.slice('calendar.'.length), color: nextColor(list), on: true };
  if (await save([...list, source])) openEditor(source);
}

/* ---- the page ---- */

function calendarRow(source) {
  const toggle = switchControl(source.on !== false, source.name || source.entity, async (input) => {
    input.disabled = true;
    const list = calendars().map((c) => (c.entity === source.entity ? { ...c, on: input.checked } : c));
    if (!(await save(list))) input.checked = !input.checked;
    input.disabled = false;
  });
  const edit = cameraAction(t('commonEdit'), () => openEditor(source), false, 'pencil');
  edit.classList.add('calendar-action');
  const row = cameraListRow(source.name || source.entity, source.entity, [edit, toggle],
    { onClick: () => openEditor(source) });
  row.classList.add('calendar-row');
  row.querySelector('.camera-row-main').prepend(avatar(source));
  return row;
}

// Above the definition rows, under any fleet banner.
function putTop(tab, nodes) {
  const banners = tab.querySelectorAll(':scope > .fleet-banner');
  const after = banners.length ? banners[banners.length - 1] : null;
  if (after) after.after(...nodes); else tab.prepend(...nodes);
}

export function renderCalendarPage() {
  const tab = document.getElementById('tab-calendar');
  if (!tab) return;
  tab.querySelectorAll('.calendar-built').forEach((n) => n.remove());

  const heading = document.createElement('h2');
  heading.className = 'card-title calendar-built';
  heading.textContent = t('calendarCalendarsSection');
  const card = document.createElement('div');
  card.className = 'card calendar-built';
  const list = calendars();
  if (!list.length) {
    const empty = document.createElement('div');
    empty.className = 'row';
    empty.innerHTML = '<div class="info"><div class="desc"></div></div>';
    empty.querySelector('.desc').textContent = t('calendarEmptyTitle');
    card.appendChild(empty);
  }
  for (const source of list) card.appendChild(calendarRow(source));
  const add = document.createElement('div');
  add.className = 'row';
  add.dataset.searchId = 'x:calendar_add';
  add.appendChild(button(t('calendarAdd'), 'btn-ghost', addCalendar));
  card.appendChild(add);
  putTop(tab, [heading, card]);
  tab.append(...voiceCards());
}

// The calendar by voice lives in Home Assistant (the blueprint), so this
// group only points at the guide. Last on the page, as on the device and
// as Voice Alarms on the Alarms page.
const VOICE_DOCS_URL = 'https://kiosksatellite.com/docs/calendar/#managing-the-calendar-by-voice';

function voiceCards() {
  const heading = document.createElement('h2');
  heading.className = 'card-title calendar-built';
  heading.textContent = t('calendarVoiceSection');
  const card = document.createElement('div');
  card.className = 'card calendar-built';
  const row = document.createElement('div');
  row.className = 'row';
  row.dataset.searchId = 'x:calendar_voice';
  const info = document.createElement('div');
  info.className = 'info';
  info.innerHTML = '<div class="name"></div><div class="desc"></div>';
  info.querySelector('.name').textContent = t('calendarVoiceManage');
  info.querySelector('.desc').textContent = t('calendarVoiceHint');
  const link = document.createElement('a');
  link.className = 'btn-ghost';
  link.textContent = deviceText('Open guide');
  link.href = VOICE_DOCS_URL;
  link.target = '_blank';
  link.rel = 'noreferrer';
  row.append(info, link);
  card.appendChild(row);
  return [heading, card];
}

export function calendarShown() {
  renderCalendarPage();
}
