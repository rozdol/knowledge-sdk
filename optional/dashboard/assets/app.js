import { API } from "./api.js";
import { element, button, Widget, Drawer, pagination, timestamp } from "./widgets.js";

const PAGES = {
  '/': ['Home', 'Your knowledge, in view.', 'Browse what is recorded. Keep the wider picture clear.'],
  '/search': ['Search', 'Find a record.', 'Search by exact name, alias or immutable ID.'],
  '/agenda': ['Agenda', 'Make room for what matters.', 'Calendar, reminders and automation, with their sources kept distinct.'],
  '/finance': ['Finance', 'See the financial picture.', 'Owner-scoped investment reports, with exact values and clear coverage.'],
  '/medical': ['Medical', 'Keep the history together.', 'Laboratory observations and their original context.'],
  '/contacts': ['Contacts', 'Stay close to your network.', 'People, relationships and the evidence behind them.'],
  '/memory': ['Memory & lifestyle', 'Keep the useful things.', 'Captures and knowledge changes, without confusing them with personal events.'],
  '/learning': ['Learning & research', 'Follow your questions.', 'Existing topics and resources, with progress grounded in recorded milestones.']
};
const NAV = [['/', 'Home', '⌂'], ['/agenda', 'Agenda', '01'], ['/finance', 'Finance', '02'], ['/medical', 'Medical', '03'],
  ['/contacts', 'Contacts', '04'], ['/memory', 'Memory & lifestyle', '05'], ['/learning', 'Learning & research', '06']];
const PLACEHOLDERS = {
  '/agenda': [['Calendar & reminders', 'No calendar or reminder service is connected.'], ['KG automation', 'Schedule and run summaries are not available yet. Configured schedules will not be presented as proof that a worker is running.']],
  '/medical': [['Laboratory history', 'Laboratory rows and analyte trends are not available yet.'], ['Diagnoses', 'Diagnosis management is not connected. Laboratory flags will not be treated as diagnoses.']],
  '/contacts': [['Contact summaries', 'Contact ranking, profiles and relationship views are not available yet. You can search existing graph identities.']],
  '/memory': [['Capture inbox', 'Capture lists and detail views are not available yet.'], ['Knowledge activity', 'The knowledge-change timeline is not available yet. Capture creation time is not a personal occurrence date.']],
  '/learning': [['Topics & resources', 'Use identity search to find existing records when your Vault has matching metadata.'], ['Learning progress', 'Milestones and assessments are not connected. Activity alone does not establish mastery.']]
};
const root = document.querySelector('#app');
const drawer = new Drawer();
let context = null;
let epoch = 0;
let expiryTimer = null;
let expiresAt = null;
let lastInput = '';
let main = null;
const api = new API({ onExpired: () => lock('Your session expired. Sign in again to continue.'), onExpiry: scheduleExpiry });

function message(error) {
  return ({ authentication_required: 'The secret was not accepted. Please try again.', rate_limited: 'Too many requests. Wait a minute and try again.',
    request_forbidden: 'The request could not be verified. Reload this page and try again.', timeout: 'This view took too long to respond. Try again.',
    network_error: 'The local host could not be reached. Check that it is running, then try again.',
    context_changed: 'The source or page context changed. Start this query again.', not_found: 'This record is not available.',
    invalid_arguments: 'Check your search text and filters, then try again.' })[error?.code] || 'This view could not be loaded. Try again.';
}
function scheduleExpiry(value) {
  clearTimeout(expiryTimer); expiresAt = Date.parse(value);
  if (!Number.isFinite(expiresAt)) return;
  expiryTimer = setTimeout(async () => {
    if (!context) return;
    try { const session = await api.session(); if (!session.authenticated) lock('Your session expired. Sign in again to continue.'); }
    catch (error) { if (error.name !== 'AbortError') lock('Sign in again to verify your session.'); }
  }, expiresAt <= Date.now() ? 30000 : expiresAt - Date.now() + 100);
}
function link(path, label, className = '') {
  const node = element('a', className, label); node.href = path;
  node.addEventListener('click', event => {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); navigate(path);
  });
  return node;
}
function lock(notice = '') {
  epoch += 1; context = null; lastInput = ''; main = null;
  clearTimeout(expiryTimer); expiresAt = null; drawer.close(); api.clear();
  root.replaceChildren(); root.setAttribute('aria-busy', 'false');
  const page = element('main', 'auth-page'); page.id = 'main';
  const frame = element('div', 'auth-frame');
  const story = element('section', 'auth-story');
  story.append(element('div', 'wordmark', 'KNOWLEDGE'), element('p', 'auth-eyebrow', 'A LOCAL VIEW'),
    element('h1', '', 'Keep the picture clear.'), element('p', '', 'A quiet place to browse the knowledge in your Vault.'),
    element('p', 'auth-trust', 'Read only · One Vault · On your device'));
  const panel = element('section', 'auth-panel'); panel.setAttribute('aria-labelledby', 'login-title');
  const heading = element('h2', '', 'Open your dashboard'); heading.id = 'login-title';
  panel.append(element('span', 'eyebrow', 'WELCOME BACK'), heading, element('p', 'muted', 'Enter the local access secret configured for this host.'));
  const alert = element('p', 'form-notice', notice); alert.setAttribute('role', 'status');
  const form = element('form', 'auth-form'); form.method = 'post'; form.action = '/api/v1/session/login';
  const label = element('label', '', 'Access secret'); label.htmlFor = 'access-secret';
  const input = element('input'); input.id = 'access-secret'; input.type = 'password'; input.name = 'secret';
  input.required = true; input.maxLength = 128; input.autocomplete = 'off'; input.spellcheck = false;
  input.setAttribute('aria-describedby', 'secret-help');
  const help = element('p', 'small muted', 'The secret stays out of URLs and browser storage.'); help.id = 'secret-help';
  const submit = element('button', 'button primary', 'Sign in'); submit.type = 'submit'; submit.disabled = true;
  form.append(label, input, help, submit); panel.append(alert, form, element('p', 'auth-footer', 'Browsing does not change your Vault or initialize Dataset storage.'));
  frame.append(story, panel); page.append(frame); root.append(page);
  const generation = epoch;
  api.session().then(session => {
    if (generation !== epoch) return;
    if (session.authenticated) { context = session; renderPage(); return; }
    submit.disabled = false;
  }).catch(error => {
    if (generation !== epoch || error.name === 'AbortError') return;
    alert.textContent = message(error); panel.append(button('Reconnect', () => lock(notice)));
  });
  form.addEventListener('submit', async event => {
    event.preventDefault(); if (submit.disabled) return;
    const secret = input.value; input.value = ''; submit.disabled = true; alert.textContent = 'Verifying your session…';
    try {
      const session = await api.login(secret);
      if (generation !== epoch) return;
      context = session; alert.textContent = ''; renderPage();
    } catch (error) {
      if (generation !== epoch || error.name === 'AbortError') return;
      alert.textContent = message(error); input.focus();
    } finally { if (generation === epoch) submit.disabled = false; }
  });
}
function navigate(path, replace = false) {
  if (!PAGES[path]) path = '/';
  if (replace) history.replaceState(null, '', path); else if (location.pathname !== path) history.pushState(null, '', path);
  if (context) renderPage();
}
function renderPage() {
  api.cancelAll(); drawer.close(); epoch += 1;
  const path = PAGES[location.pathname] ? location.pathname : '/';
  if (location.pathname !== path || location.search || location.hash) history.replaceState(null, '', path);
  document.title = `${PAGES[path][0]} · Knowledge`;
  root.replaceChildren(); root.setAttribute('aria-busy', 'false');
  const shell = element('div', 'app-shell');
  const aside = element('aside', 'sidebar');
  const brand = link('/', '', 'brand');
  const mark = element('span', 'brand-mark', 'K'); mark.setAttribute('aria-hidden', 'true');
  const brandText = element('span'); brandText.append(element('strong', '', 'Knowledge'), element('small', '', 'Your local workspace'));
  brand.append(mark, brandText); aside.append(brand);
  const nav = element('nav', 'navigation'); nav.setAttribute('aria-label', 'Main navigation');
  for (const [href, label, icon] of NAV) {
    const item = link(href, '', 'nav-link');
    const symbol = element('span', 'nav-symbol', icon); symbol.setAttribute('aria-hidden', 'true');
    item.append(symbol, element('span', '', label)); if (path === href) item.setAttribute('aria-current', 'page'); nav.append(item);
  }
  aside.append(nav);
  const foot = element('div', 'sidebar-foot'); foot.append(element('span', 'connection-dot'), element('span', '', 'Local connection'), element('p', '', 'Your records stay in your Vault.'));
  aside.append(foot);
  const content = element('div', 'workspace');
  const top = element('header', 'topbar');
  const label = element('div', 'context-label'); label.append(element('span', 'eyebrow', 'WORKSPACE'), element('span', '', context.display_label));
  const controls = element('div', 'topbar-controls');
  controls.append(element('span', 'read-only', 'Read only'), link('/search', 'Search', 'text-button'), button('Sign out', signOut, 'text-button'));
  top.append(label, controls); content.append(top);
  main = element('main', 'page'); main.id = 'main';
  const intro = element('header', 'page-intro');
  const heading = element('h1', '', PAGES[path][1]); heading.tabIndex = -1;
  intro.append(element('p', 'eyebrow', PAGES[path][0]), heading, element('p', 'intro-copy', PAGES[path][2])); main.append(intro);
  if (path === '/') home();
  else if (path === '/search') {
    searchPanel(main);
    main.append(element('p', 'scope-notice', 'Each source reports its own state. Counts are not combined across graph identities, Contacts, Captures and change history.'));
    domainList(main, { id: 'search-contacts', title: 'Contact matches', path: '/api/v1/contacts', fields: ['Contact', 'Status'], open: item => contactDetail(item, displayDate()), initial: false, shared: true });
    captureList(main, false);
    activityList(main, false, true);
  }
  else if (path === '/contacts') contactsPage();
  else if (path === '/finance') financePage();
  else if (path === '/medical') medicalPage();
  else if (path === '/memory') memoryPage();
  else if (path === '/learning') learningPage();
  else {
    const cards = element('div', 'widget-grid');
    for (const [title, copy] of PLACEHOLDERS[path]) {
      const widget = new Widget(title); widget.render({ status: 'unavailable' }, { message: copy }); cards.append(widget.node);
    }
    main.append(cards, link('/search', 'Search existing records →', 'inline-link'));
  }
  content.append(main);
  const footer = element('footer', 'page-footer'); footer.append(element('span', '', 'KNOWLEDGE SDK'), element('span', '', `Display timezone: ${context.timezone}`)); content.append(footer);
  shell.append(aside, content); root.append(shell); heading.focus({ preventScroll: true });
}
async function signOut() {
  const generation = ++epoch;
  context = null; clearTimeout(expiryTimer); expiresAt = null;
  api.cancelAll(); drawer.close(); root.setAttribute('aria-busy', 'true');
  // Remove private DOM immediately, even when the network is slow.
  root.replaceChildren(element('main', 'initial', 'Signing out…')); lastInput = '';
  try { await api.logout(); if (generation === epoch) lock('You have signed out.'); }
  catch (error) {
    if (generation !== epoch || error.name === 'AbortError') return;
    // Do not silently sign in again while the server cookie may still be valid.
    context = null; api.clear(); clearTimeout(expiryTimer); epoch += 1;
    root.replaceChildren();
    const panel = element('main', 'initial'); panel.id = 'main';
    panel.append(element('h1', '', 'Your local view is cleared.'), element('p', 'muted', 'Sign-out could not be confirmed. Keep this page open and retry to end the server session.'),
      button('Retry sign out', async () => {
        try { await api.session(); await api.logout(); lock('You have signed out.'); }
        catch (retryError) { panel.querySelector('p').textContent = message(retryError); }
      })); root.append(panel); root.setAttribute('aria-busy', 'false');
  }
}
function home() {
  const strip = element('div', 'trust-strip');
  for (const [label, copy] of [['A read-only view', 'Browse without changing records'], ['Local by default', 'No external fetching or model calls'], ['Evidence in context', 'Unknown values stay unknown']]) {
    const item = element('div'); item.append(element('strong', '', label), element('span', '', copy)); strip.append(item);
  }
  main.append(strip);
  const grid = element('div', 'home-grid'); main.append(grid);
  searchPanel(grid);
  const available = new Widget('Available views', 'What this host can show right now.'); grid.append(available.node);
  const generation = epoch;
  async function load() {
    available.render({ status: 'loading' }, { message: 'Checking available reads…' });
    try {
      const result = await api.get('/api/v1/dashboard/availability', {}, 'availability');
      if (generation !== epoch) return;
      const list = element('ul', 'feature-list');
      const labels = { search: 'Identity search', contacts: 'Contact summaries', memory: 'Captures & activity', finance: 'Finance reports', medical: 'Laboratory history', automation: 'KG automation', calendar: 'Calendar', learning: 'Learning progress', hermes: 'Hermes jobs', os: 'System jobs' };
      for (const feature of (result.data?.features || []).slice(0, 10)) {
        const row = element('li');
        row.append(element('span', '', labels[feature.feature] || 'Other read'), element('span', feature.state === 'available' || feature.state === 'empty' ? 'feature-ready' : 'muted', feature.state === 'available' ? 'Ready' : feature.state === 'empty' ? 'Ready · empty' : 'Not available yet')); list.append(row);
      }
      available.render(result, { content: list, timezone: context.timezone, message: result.status === 'unavailable' ? 'This view is not available with the current access permissions.' : null });
    } catch (error) { if (generation === epoch && error.name !== 'AbortError') available.render({ status: 'error' }, { message: message(error), retry: load }); }
  }
  load();
}
function searchPanel(parent) {
  const area = element('div', 'search-area');
  const form = element('form', 'search-form'); form.method = 'post'; form.action = '/';
  const label = element('label', '', 'Search records'); label.htmlFor = 'record-query';
  const input = element('input'); input.id = 'record-query'; input.type = 'search'; input.name = 'q'; input.required = true; input.maxLength = 200; input.value = lastInput;
  input.placeholder = 'Exact name, alias or ID'; input.autocomplete = 'off'; input.spellcheck = false;
  const row = element('div', 'search-input-row');
  const submit = element('button', 'button primary', 'Search'); submit.type = 'submit'; row.append(input, submit);
  const filters = element('div', 'search-filters');
  function select(id, title, options) {
    const field = element('div'); const caption = element('label', 'small', title); caption.htmlFor = id;
    const menu = element('select'); menu.id = id;
    for (const [value, name] of options) { const item = element('option', '', name); item.value = value; menu.append(item); }
    field.append(caption, menu); filters.append(field); return menu;
  }
  const type = select('record-type', 'Record type', [['', 'All types'], ['person', 'People'], ['organization', 'Organizations'], ['project', 'Projects']]);
  const limit = select('record-limit', 'Result limit', [['25', '25 records'], ['50', '50 records'], ['100', '100 records']]);
  form.append(label, row, filters, element('p', 'small muted', 'Exact identity matches only. This does not search Capture bodies or Dataset rows.'));
  const results = new Widget('Identity search', 'Policy-visible records from the current Vault.');
  results.render({ status: 'empty' }, { message: 'Enter a name, alias or ID to begin.' });
  area.append(form, results.node); parent.append(area);
  const generation = epoch;
  let requestGeneration = 0;
  async function run() {
    const query = input.value.trim();
    if (!query || query.length > 200 || new TextEncoder().encode(query).length > 800) { input.setCustomValidity('Use 1–200 characters and at most 800 UTF-8 bytes.'); input.reportValidity(); return; }
    input.setCustomValidity(''); lastInput = query;
    const current = ++requestGeneration;
    results.render({ status: 'loading' }, { message: 'Looking for permitted identity matches…' });
    const params = { q: query, limit: limit.value }; if (type.value) params.entity_type = type.value;
    try {
      const result = await api.get('/api/v1/search', params, 'search');
      if (generation !== epoch || current !== requestGeneration) return;
      const records = result.data?.items || [];
      const body = element('div');
      if (records.length) {
        const scroll = element('div', 'table-scroll');
        const table = element('table', 'results-table');
        const caption = element('caption', 'sr-only', 'Permitted identity search results'); table.append(caption);
        const head = element('thead'); const tr = element('tr');
        for (const title of ['Record', 'Type', 'Matched by']) { const th = element('th', '', title); th.scope = 'col'; tr.append(th); } head.append(tr); table.append(head);
        const rows = element('tbody');
        for (const record of records.slice(0, 100)) {
          const recordRow = element('tr'); const name = element('td');
          name.append(button(record.name || record.id, () => drawer.show(record.name || 'Record', [
            ['Identity', record.id], ['Record type', record.type], ['Status', record.record_status], ['Aliases', record.aliases || []], ['Matched by', record.signals || []]
          ], result.evidence || []), 'record-link'));
          name.append(element('span', 'record-id mono', record.id));
          recordRow.append(name, element('td', '', record.type), element('td', '', (record.signals || []).join(', '))); rows.append(recordRow);
        }
        table.append(rows); scroll.append(table); body.append(scroll, pagination(result.data?.page));
      }
      const statusText = { empty: 'No permitted identity matches were found. Try an exact name or alias.', unavailable: 'Search is not available with the current access permissions.', partial: 'This is a partial result. Refine the filters if the result limit was reached.', stale: 'The source has changed or is out of date. Refresh before relying on this view.', error: 'The search could not be completed.' };
      results.render(result, { content: body, message: statusText[result.status], retry: result.status === 'error' || result.status === 'stale' ? run : undefined,
        timezone: context.timezone, openEvidence: refs => drawer.show('Source references', [], refs) });
    } catch (error) { if (generation === epoch && current === requestGeneration && error.name !== 'AbortError') results.render({ status: 'error' }, { message: message(error), retry: run }); }
  }
  form.addEventListener('submit', event => { event.preventDefault(); run(); if (input.checkValidity()) main.dispatchEvent(new CustomEvent('search-sources', { detail: input.value.trim() })); });
  function changed() {
    input.setCustomValidity(''); requestGeneration += 1; api.cancel('search');
    main.dispatchEvent(new CustomEvent('search-sources-reset'));
    results.render({ status: 'empty' }, { message: 'Search again with the updated text and filters.' });
  }
  input.addEventListener('input', changed);
  for (const control of [type, limit]) control.addEventListener('change', changed);
}
// Domain reads share bounded controls, while each widget owns its request/state.
let detailGeneration = 0;
drawer.node.addEventListener('close', () => { if (!drawer.node.open) invalidateDetails(); });
function invalidateDetails() { detailGeneration += 1; api.cancel('domain-detail'); api.cancel('domain-relations'); drawer.close(); }
function queryForm(id, title, options = [], window = false) {
  const form = element('form', 'domain-filters'); form.method = 'post'; form.action = '/';
  const caption = element('label', '', title); caption.htmlFor = id;
  const input = element('input'); input.type = 'search'; input.id = id; input.maxLength = 200; input.autocomplete = 'off';
  const row = element('div', 'search-input-row'); const submit = element('button', 'button primary', 'Apply filters'); submit.type = 'submit';
  row.append(input, submit); form.append(caption, row);
  const controls = {};
  for (const [key, label, values] of options) {
    const field = element('div'); const name = element('label', 'small', label); name.htmlFor = id + '-' + key;
    const select = element('select'); select.id = name.htmlFor;
    for (const [value, text] of values) { const choice = element('option', '', text); choice.value = value; select.append(choice); }
    controls[key] = select; field.append(name, select); form.append(field);
  }
  if (window) {
    for (const [key, label] of [['from', 'From (include timezone offset)'], ['to', 'To (exclusive, include timezone offset)']]) {
      const caption = element('label', 'small', label); caption.htmlFor = id + '-' + key;
      const value = element('input'); value.id = caption.htmlFor; value.type = 'text'; value.maxLength = 40; value.placeholder = '2026-10-01T00:00:00+03:00';
      controls[key] = value; form.append(caption, value);
    }
  }
  return { form, input, controls };
}
function domainList(parent, { id, title, description, path, options = [], extra = () => ({}), open, fields, initial = true, shared = false, window = false }) {
  const area = element('section', 'domain-list');
  const filter = queryForm(id, 'Search ' + title.toLowerCase(), options, window);
  const widget = new Widget(title, description); area.append(filter.form, widget.node); parent.append(area);
  let pageIndex = 0, cursors = [null], filters = {}, serial = 0;
  const generation = epoch;
  function reset() { pageIndex = 0; cursors = [null]; }
  async function load(restart = false) {
    if (restart) reset();
    const current = ++serial; invalidateDetails();
    widget.render({ status: 'loading' }, { message: 'Reading permitted records…' });
    try {
      const params = { ...filters, ...extra(), limit: '25' };
      if (cursors[pageIndex]) params.cursor = cursors[pageIndex];
      const result = await api.get(path, params, id);
      if (generation !== epoch || current !== serial) return;
      const items = result.data?.items || [];
      const body = element('div');
      if (items.length) {
        const scroll = element('div', 'table-scroll'); const table = element('table', 'results-table');
        table.append(element('caption', 'sr-only', title + ' permitted records'));
        const head = element('thead'); const header = element('tr');
        for (const label of fields) { const cell = element('th', '', label); cell.scope = 'col'; header.append(cell); } head.append(header); table.append(head);
        const rows = element('tbody');
        for (const item of items) {
          const row = element('tr'); const name = element('td');
          name.append(button(item.name || item.title || item.summary, () => open(item), 'record-link'));
          const values = path.includes('captures') ? [item.kind, item.status, timestamp(item.captured_at, context.timezone)]
            : path.includes('activity') ? [item.type.replaceAll('_', ' '), timestamp(item.created_at, context.timezone)] : [item.record_status];
          row.append(name, ...values.map(value => element('td', '', value))); rows.append(row);
        }
        table.append(rows); scroll.append(table); body.append(scroll);
      }
      const pager = pagination(result.data?.page, { index: pageIndex + 1,
        back: pageIndex > 0 ? () => { pageIndex -= 1; load(); } : null,
        next: cursor => { if (pageIndex >= 4) return; cursors[++pageIndex] = cursor; load(); } });
      body.append(pager);
      if (pageIndex >= 4 && result.data?.page?.next_cursor) body.append(element('p', 'muted', 'Five-page browsing limit reached. Refine the filters to continue.'));
      widget.render(result, { content: body, timezone: context.timezone,
        message: result.status === 'empty' ? 'No permitted records match these filters.' : result.status === 'unavailable' ? 'This source is not available with the current permissions or schema.' : null,
        openEvidence: refs => drawer.show('Source references', [], refs) });
    } catch (error) {
      if (generation === epoch && current === serial && error.name !== 'AbortError') widget.render({ status: 'error' }, { message: message(error), retry: () => load(true) });
    }
  }
  function changed() { serial += 1; api.cancel(id); invalidateDetails(); reset(); widget.render({ status: 'empty' }, { message: 'Apply the updated filters to read this source.' }); }
  filter.input.addEventListener('input', changed);
  Object.values(filter.controls).forEach(control => control.addEventListener('change', changed));
  if (shared) {
    parent.addEventListener('search-sources', event => { filter.input.value = event.detail; filters = { q: event.detail }; for (const control of Object.values(filter.controls)) control.value = ''; load(true); });
    parent.addEventListener('search-sources-reset', changed);
  }
  filter.form.addEventListener('submit', event => {
    event.preventDefault(); filters = {};
    const query = filter.input.value.trim(); if (query) filters.q = query;
    for (const [key, control] of Object.entries(filter.controls)) if (control.value) filters[key] = control.value;
    load(true);
  });
  if (initial) load(); else widget.render({ status: 'empty' }, { message: 'Enter a query and apply filters to search this source.' });
  return () => load(true);
}
async function contactDetail(item, asOf) {
  const generation = epoch, current = ++detailGeneration;
  drawer.show(item.name, [['State', 'Loading permitted profile and relations…']]);
  const reads = await Promise.allSettled([
    api.get('/api/v1/contacts/' + item.id, {}, 'domain-detail'),
    api.get('/api/v1/contacts/' + item.id + '/relations', { depth: '2', as_of: asOf }, 'domain-relations')
  ]);
  if (generation !== epoch || current !== detailGeneration) return;
  const [profile, network] = reads;
  const fields = [];
  if (profile.status === 'fulfilled') {
    const record = profile.value.data?.item;
    if (record) {
      fields.push(['Identity', record.id], ['Status', record.record_status], ['Aliases', record.aliases],
        ['Emails', record.emails || 'Private contact access not enabled'], ['Phones', record.phones || 'Private contact access not enabled']);
      if (record.interaction) fields.push(['Ranking formula', record.interaction.formula], ['Score', record.interaction.score ?? 'Unknown'],
        ['Recorded interactions', record.interaction.interaction_count ?? 'Unknown'], ['Latest substantive interaction', record.interaction.latest_at ? timestamp(record.interaction.latest_at, context.timezone) : 'Unknown'],
        ['Ranking reasons', record.interaction.reasons]);
      if (record.relationship_strength) fields.push(['Relationship strength', record.relationship_strength.score ?? 'Unknown'], ['Strength calculation', record.relationship_strength.explanation]);
    } else fields.push(['Profile', 'Unavailable']);
  } else fields.push(['Profile', message(profile.reason)]);
  if (network.status === 'fulfilled') {
    const data = network.value.data;
    if (data) {
      const labels = new Map(data.nodes.map(node => [node.id, node.name]));
      fields.push(['Relationship scope', 'Policy-visible recorded relationships · depth 2 · as of ' + asOf]);
      fields.push(['Relationships', data.edges.length ? data.edges.map(edge => `${labels.get(edge.source) || edge.source} → ${edge.predicate} → ${labels.get(edge.target) || edge.target}`).join('\n') : 'No permitted recorded relationships.']);
      if (network.value.status === 'partial') fields.push(['Coverage', 'Traversal bound reached; this network is partial.']);
    } else fields.push(['Relationships', 'Unavailable']);
  } else fields.push(['Relationships', message(network.reason)]);
  drawer.show(item.name, fields, profile.status === 'fulfilled' ? profile.value.data?.item?.interaction?.evidence || [] : []);
}
function displayDate() {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: context.timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
  const part = type => parts.find(item => item.type === type).value;
  return `${part('year')}-${part('month')}-${part('day')}`;
}
function contactsPage() {
  const dateForm = element('form', 'domain-filters'); const label = element('label', '', 'Ranking and relationship date'); label.htmlFor = 'contacts-date';
  const date = element('input'); date.id = 'contacts-date'; date.type = 'date'; date.required = true;
  date.value = displayDate();
  const apply = element('button', 'button secondary', 'Update ranking'); apply.type = 'submit'; dateForm.append(label, date, apply); main.append(dateForm);
  const top = new Widget('Top recorded contacts', 'interaction-v1 · 60% recency + 40% interaction frequency. Signals use permitted recorded interactions only.'); main.append(top.node);
  const generation = epoch;
  let serial = 0;
  async function loadTop() {
    const current = ++serial; invalidateDetails(); top.render({ status: 'loading' }, { message: 'Computing visible interaction signals…' });
    try {
      const result = await api.get('/api/v1/contacts/top', { as_of: date.value }, 'top');
      if (generation !== epoch || current !== serial) return;
      const list = element('ol', 'ranking-list');
      for (const item of result.data?.items || []) {
        const row = element('li'); row.append(button(item.name, () => contactDetail(item, date.value), 'record-link'),
          element('span', 'rank-score', String(item.interaction.score)), element('p', 'muted small', item.interaction.reasons.join(' '))); list.append(row);
      }
      top.render(result, { content: list, timezone: context.timezone, message: result.status === 'unavailable' ? 'Ranking is unavailable without permitted recorded interaction signals and Intelligence access. Contacts remain browsable below.' : null });
    } catch (error) { if (generation === epoch && current === serial && error.name !== 'AbortError') top.render({ status: 'error' }, { message: message(error), retry: loadTop }); }
  }
  date.addEventListener('input', () => { serial += 1; api.cancel('top'); invalidateDetails(); top.render({ status: 'empty' }, { message: 'Update ranking for the selected date.' }); });
  dateForm.addEventListener('submit', event => { event.preventDefault(); loadTop(); }); loadTop();
  domainList(main, { id: 'contacts-list', title: 'Contacts', description: 'Browse recorded people by name or alias.', path: '/api/v1/contacts', fields: ['Contact', 'Status'], open: item => contactDetail(item, date.value) });
}
async function captureDetail(item) {
  const generation = epoch, current = ++detailGeneration;
  drawer.show(item.title, [['State', 'Loading permitted Capture…']]);
  try {
    const result = await api.get('/api/v1/captures/' + item.id, {}, 'domain-detail');
    if (generation !== epoch || current !== detailGeneration) return;
    const record = result.data?.item;
    if (!record) { drawer.show(item.title, [['State', 'Capture unavailable']]); return; }
    const fields = [['Kind', record.kind], ['Status', record.status], ['Captured at (recorded time)', timestamp(record.captured_at, context.timezone)],
      ['Text', record.text], ['Text coverage', record.text_truncated ? 'Truncated to 10,000 characters' : 'Complete plain-text rendition'], ['Topics', record.topics], ['Tags', record.tags], ['Permitted links', record.links]];
    for (const [key, value] of Object.entries(record.bookmark || {})) fields.push([key.replaceAll('_', ' '), value]);
    drawer.show(record.title, fields, result.evidence || []);
  } catch (error) { if (generation === epoch && current === detailGeneration && error.name !== 'AbortError') drawer.show(item.title, [['State', message(error)]]); }
}
function captureList(parent, initial = true, bookmarks = false) {
  return domainList(parent, { id: bookmarks ? 'research-captures' : 'capture-list', shared: !initial, window: true, title: bookmarks ? 'Saved resources' : 'Captures', path: '/api/v1/captures',
    description: 'Capture creation time is recorded time, not a personal occurrence. Search words are literal; filters select kind and lifecycle.',
    options: [...(bookmarks ? [] : [['kind', 'Capture kind', [['', 'All kinds'], ...['thought', 'idea', 'note', 'question', 'lesson', 'decision', 'observation', 'bookmark', 'reference', 'quote', 'hypothesis'].map(value => [value, value])]]]),
      ['status', 'Lifecycle', [['', 'All states'], ...['inbox', 'reviewed', 'linked', 'promoted', 'archived'].map(value => [value, value])]]],
    extra: () => bookmarks ? { kind: 'bookmark' } : {}, fields: ['Capture', 'Kind', 'Status', 'Captured at'], open: captureDetail, initial });
}
function memoryPage() {
  main.append(element('p', 'scope-notice', 'Personal occurrences are not connected. The sources below describe saved knowledge and knowledge changes separately.'));
  captureList(main);
  activityList(main);
}
function activityList(parent, initial = true, shared = false) {
  domainList(parent, { id: 'activity-list', initial, shared, window: true, title: 'Knowledge activity', description: 'Existing change-history projection. Last 30 calendar days through today, in your configured timezone.',
    path: '/api/v1/activity', fields: ['Change', 'Type', 'Recorded at'], open: item => drawer.show('Knowledge change', [['Summary', item.summary], ['Type', item.type], ['Recorded at', timestamp(item.created_at, context.timezone)], ['Source', item.source], ['Permitted objects', item.objects.map(object => object.name)]], item.objects.map(object => ({ record_id: object.id, role: 'affected_record' }))) });
}
function learningPage() {
  const unavailable = new Widget('Learning progress'); unavailable.render({ status: 'unavailable' }, { message: 'Milestones and assessments are not connected. Recorded resources and activity do not establish mastery.' }); main.append(unavailable.node);
  main.append(element('p', 'scope-notice', 'Search graph names/aliases and saved bookmark metadata as separate sources. Their result counts are not combined into a unique total.'));
  searchPanel(main); captureList(main, true, true);
}

function financePage() {
  const generation = epoch;
  const scopes = new Widget('Finance scope', 'Choose an explicit visible owner. Account filters apply to positions, transactions and investment P&L.');
  main.append(scopes.node);
  let sequence = 0;
  async function loadScopes() {
    const current = ++sequence;
    scopes.render({ status: 'loading' }, { message: 'Reading permitted financial scopes…' });
    try {
      const result = await api.get('/api/v1/finance/scopes', {}, 'finance-scopes');
      if (generation !== epoch || current !== sequence) return;
      if (!result.data?.owners?.length) {
        scopes.render(result, { message: result.status === 'empty' ? 'No visible financial owners are recorded.' : 'Finance is unavailable. It requires an explicitly installed Finance plugin and Finance, graph and Dataset read access.', retry: loadScopes });
        return;
      }
      financeControls(result, scopes, generation);
    } catch (error) {
      if (generation === epoch && current === sequence && error.name !== 'AbortError') scopes.render({ status: 'error' }, { message: message(error), retry: loadScopes });
    }
  }
  loadScopes();
}
function financeControls(scopeResult, scopeWidget, generation) {
  const catalog = scopeResult.data;
  const form = element('form', 'domain-filters finance-filters'); form.method = 'post'; form.action = '/';
  const fields = {};
  function menu(key, title, options) {
    const field = element('div'); const label = element('label', 'small', title); label.htmlFor = 'finance-' + key;
    const control = element('select'); control.id = label.htmlFor;
    field.append(label, control); form.append(field); fields[key] = control;
    setOptions(control, options); return control;
  }
  function setOptions(control, options) {
    control.replaceChildren();
    for (const [value, label] of options) { const option = element('option', '', label); option.value = value; control.append(option); }
  }
  menu('owner_id', 'Financial owner', [['', 'Choose an owner'], ...catalog.owners.map(item => [item.id, item.name])]).required = true;
  menu('account_id', 'Financial account', [['', 'All visible owner accounts']]);
  menu('asset_id', 'Financial instrument', [['', 'All visible owner instruments']]);
  const today = displayDate();
  for (const [key, title, value] of [['as_of', 'Valuation date (UTC)', today], ['from', 'Period from (UTC)', today.slice(0, 8) + '01'], ['to', 'Period through (UTC)', today]]) {
    const field = element('div'); const label = element('label', 'small', title); label.htmlFor = 'finance-' + key;
    const input = element('input'); input.type = 'date'; input.id = label.htmlFor; input.required = true; input.value = value;
    fields[key] = input; field.append(label, input); form.append(field);
  }
  menu('currency', 'Net worth reporting currency', ['EUR', 'USD', 'GBP', ...catalog.assets.map(item => item.currency)].filter((value, index, all) => value && all.indexOf(value) === index).map(value => [value, value]));
  menu('period', 'Investment P&L period', [['total', 'Period total'], ['monthly', 'Monthly']]);
  menu('direction', 'Debt direction', [['', 'Receivables and payables'], ['payable', 'Payables'], ['receivable', 'Receivables']]);
  const submit = element('button', 'button primary', 'Load financial reports'); submit.type = 'submit'; form.append(submit);
  form.append(element('p', 'small muted', 'Inclusive UTC accounting dates. Net worth and debts cover the selected owner across visible accounts. Native P&L currencies remain separate. No live prices or news are fetched.'));
  scopeWidget.render(scopeResult, { content: form, timezone: context.timezone });
  const grid = element('div', 'widget-grid finance-grid'); main.append(grid);
  let queryVersion = 0;
  const definitions = [
    ['net-worth', 'Owner net worth', 'Recorded assets, cash and debt, with explicit FX coverage.', ['Kind', 'Currency', 'Native value', 'Reporting value'], item => [item.kind, item.currency, item.value, item.reporting_value]],
    ['positions', 'Positions', 'Complete owner replay before account selection and display paging.', ['Instrument', 'Currency', 'Quantity', 'Unit', 'FIFO basis', 'Market value'], item => [item.instrument || item.asset_id, item.currency, item.quantity, item.unit, item.cost_basis, item.market_value]],
    ['liabilities', 'Receivables & liabilities', 'Recorded principal and explicit accrued interest; no automatic accrual.', ['Counterparty', 'Direction', 'Currency', 'Principal', 'Interest', 'Overdue'], item => [item.counterparty, item.direction, item.currency, item.outstanding_principal, item.accrued_interest, item.overdue_principal]],
    ['transactions', 'Immutable transactions', 'The selected period limits display only. Reversals retain the original events.', ['Effective at (UTC)', 'Operation', 'Currency', 'Quantity', 'Price', 'Amount', 'Fees'], item => [item.effective_at, item.operation, item.currency, item.quantity, item.price, item.amount, item.fees]],
    ['pnl', 'Investment P&L', 'FIFO gross gains and fees at event date. Household, business and tax P&L are unavailable.', ['Period', 'Currency', 'Realized', 'Variation margin', 'Income', 'Expense', 'Fees', 'Unrealized change', 'Net P&L'], item => [item.month || 'Total', item.currency, item.realized, item.variation_margin, item.income, item.expense, item.fees, item.unrealized_change, item.net_pnl]]
  ];
  const views = definitions.map(([id, title, description, headings, cells]) => {
    const widget = new Widget(title, description); grid.append(widget.node);
    let history = [null], index = 0, args = null, requestSequence = 0;
    function reset() {
      requestSequence += 1; api.cancel('finance-' + id); args = null; history = [null]; index = 0;
      widget.render({ status: 'empty' }, { message: 'Select an owner and load reports for this scope.' });
    }
    async function load(cursor = history[index]) {
      if (!args) return;
      const version = queryVersion, serial = ++requestSequence;
      widget.render({ status: 'loading' }, { message: 'Reading permitted financial history…' });
      try {
        const result = await api.get('/api/v1/finance/' + id, { ...args, ...(cursor ? { cursor } : {}) }, 'finance-' + id);
        if (generation !== epoch || version !== queryVersion || serial !== requestSequence) return;
        const data = result.data;
        const body = element('div');
        if (data) {
          if (id === 'net-worth') {
            body.append(element('p', 'scope-notice', `Net worth: ${data.net_worth ?? 'Unavailable'} ${data.currency} · Known subtotal: ${data.known_subtotal} ${data.currency}`), element('p', 'small muted', `Valuation: ${data.valuation_status}. ${data.coverage}.`));
          }
          for (const limitation of data.limitations || []) body.append(element('p', 'warning', limitation));
          const rows = data.items || data.debts || (id === 'net-worth' ? data.components : data.months ? data.months.flatMap(month => month.totals.map(total => ({ ...total, month: month.from.slice(0, 7) }))) : data.totals) || [];
          if (data.months) body.append(financeChart(rows));
          if (rows.length) {
            const scroll = element('div', 'table-scroll'), table = element('table', 'results-table');
            table.append(element('caption', 'sr-only', title + ' — exact decimal values'));
            const head = element('thead'), tr = element('tr');
            for (const heading of [...headings, 'Details']) { const th = element('th', '', heading); th.scope = 'col'; tr.append(th); }
            head.append(tr); table.append(head); const tbody = element('tbody');
            for (const item of rows) {
              const row = element('tr');
              for (const value of cells(item)) row.append(element('td', '', value ?? 'Unknown'));
              const detail = element('td'); detail.append(button('View details', () => drawer.show(title, Object.entries(item).map(([key, value]) => [key.replaceAll('_', ' '), value && typeof value === 'object' ? JSON.stringify(value) : value]), result.evidence || []), 'record-link'));
              row.append(detail); tbody.append(row);
            }
            table.append(tbody); scroll.append(table); body.append(scroll);
          } else body.append(element('p', 'muted', 'No permitted recorded items in this scope and period.'));
          if (data.page) body.append(pagination(data.page, { index: index + 1,
            next: next => { history = history.slice(0, index + 1); history.push(next); index += 1; load(next); },
            back: () => { index -= 1; load(); } }));
        }
        widget.render(result, { content: body, timezone: 'Etc/UTC', message: result.status === 'unavailable' ? 'This report is unavailable. Check its source limitations.' : null,
          openEvidence: refs => drawer.show('Finance source references', [], refs) });
      } catch (error) {
        if (generation === epoch && version === queryVersion && serial === requestSequence && error.name !== 'AbortError') widget.render({ status: 'error' }, { message: message(error), retry: () => { history = [null]; index = 0; load(); } });
      }
    }
    reset();
    return { reset, run(parameters) {
      const keys = id === 'net-worth' ? ['owner_id', 'as_of', 'currency'] : id === 'liabilities' ? ['owner_id', 'as_of', 'direction'] : id === 'positions' ? ['owner_id', 'account_id', 'asset_id', 'as_of'] : id === 'transactions' ? ['owner_id', 'account_id', 'asset_id', 'from', 'to'] : ['owner_id', 'account_id', 'asset_id', 'from', 'to', 'period'];
      args = Object.fromEntries(keys.filter(key => parameters[key]).map(key => [key, parameters[key]]));
      if (id === 'positions' || id === 'transactions') args.limit = 25;
      return load();
    } };
  });
  function changed() {
    queryVersion += 1; drawer.close(); views.forEach(view => view.reset());
  }
  fields.owner_id.addEventListener('change', () => {
    for (const [key, collection, title] of [['account_id', catalog.accounts, 'All visible owner accounts'], ['asset_id', catalog.assets, 'All visible owner instruments']]) {
      setOptions(fields[key], [['', title], ...collection.filter(item => item.owner_ids?.includes(fields.owner_id.value)).map(item => [item.id, item.name])]);
    }
  });
  for (const field of Object.values(fields)) { field.addEventListener('input', changed); field.addEventListener('change', changed); }
  form.addEventListener('submit', async event => {
    event.preventDefault(); if (!form.reportValidity()) return;
    changed(); const version = queryVersion;
    const parameters = Object.fromEntries(Object.entries(fields).map(([key, field]) => [key, field.value]));
    await Promise.all(views.slice(0, 3).map(view => view.run(parameters)));
    if (generation === epoch && version === queryVersion) await Promise.all(views.slice(3).map(view => view.run(parameters)));
  });
}
function financeChart(rows) {
  const figure = element('figure'); figure.append(element('figcaption', 'small muted', 'Monthly investment P&L by native currency. Bar lengths are approximate; the table retains exact values. Missing P&L has no bar.'));
  const ns = 'http://www.w3.org/2000/svg';
  for (const currency of [...new Set(rows.map(row => row.currency))]) {
    const group = rows.filter(row => row.currency === currency);
    const maximum = Math.max(...group.map(row => Math.abs(Number(row.net_pnl ?? 0))), 1);
    const svg = document.createElementNS(ns, 'svg'); svg.setAttribute('viewBox', `0 0 600 ${group.length * 35 + 35}`); svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', 'Monthly investment P&L in ' + currency); svg.setAttribute('width', '100%');
    group.forEach((row, index) => {
      const y = index * 35 + 25;
      const label = document.createElementNS(ns, 'text'); label.setAttribute('x', '0'); label.setAttribute('y', String(y)); label.setAttribute('fill', '#3f514a'); label.setAttribute('font-size', '13'); label.textContent = `${row.month} · ${row.net_pnl ?? 'Unknown'} ${currency}`; svg.append(label);
      if (row.net_pnl !== null && Number.isFinite(Number(row.net_pnl))) {
        const bar = document.createElementNS(ns, 'rect'); bar.setAttribute('x', '300'); bar.setAttribute('y', String(y - 13)); bar.setAttribute('height', '17'); bar.setAttribute('width', String(Math.abs(Number(row.net_pnl)) / maximum * 280)); bar.setAttribute('fill', Number(row.net_pnl) < 0 ? '#d79778' : '#8fc1a7'); svg.append(bar);
      }
    });
    figure.append(svg);
  }
  return figure;
}
function medicalPage() {
  const generation = epoch;
  const scope = new Widget('Laboratory subject', 'Choose a recorded subject explicitly. No ownership is inferred from filenames or the current user.'); main.append(scope.node);
  const diagnosis = new Widget('Diagnoses'); diagnosis.render({ status: 'unavailable' }, { message: 'Diagnosis and treatment recommendations are unavailable. Laboratory flags retain their report-supplied meaning.' }); main.append(diagnosis.node);
  async function loadScopes() {
    scope.render({ status: 'loading' }, { message: 'Reading permitted laboratory subjects…' });
    try {
      const result = await api.get('/api/v1/health/labs', { scopes: 'true' }, 'lab-scopes');
      if (generation !== epoch) return;
      if (!result.data?.subjects?.length) { scope.render(result, { message: 'No supported, explicitly scoped laboratory history is available with the current Health, Dataset and graph permissions.', retry: loadScopes }); return; }
      medicalControls(result, scope, generation);
    } catch (error) { if (generation === epoch && error.name !== 'AbortError') scope.render({ status: 'error' }, { message: message(error), retry: loadScopes }); }
  }
  loadScopes();
}
function medicalControls(scopeResult, scope, generation) {
  const form = element('form', 'domain-filters medical-filters'); form.method = 'post'; form.action = '/';
  const controls = {};
  function field(key, title, type = 'text', value = '') {
    const group = element('div'), label = element('label', 'small', title); label.htmlFor = 'lab-' + key;
    const input = element(key === 'subject_id' ? 'select' : 'input'); input.id = label.htmlFor;
    if (key !== 'subject_id') { input.type = type; input.maxLength = 200; input.value = value; }
    group.append(label, input); form.append(group); controls[key] = input; return input;
  }
  const subject = field('subject_id', 'Laboratory subject'); subject.required = true;
  for (const item of [{ id: '', name: 'Choose a subject' }, ...scopeResult.data.subjects]) { const option = element('option', '', item.name); option.value = item.id; subject.append(option); }
  field('panel', 'Laboratory panel'); field('analyte', 'Analyte (exact recorded name)');
  const today = displayDate(), start = new Date(today + 'T00:00:00Z'); start.setUTCDate(start.getUTCDate() - 29);
  field('from', 'Test date from', 'date', start.toISOString().slice(0, 10)).required = true;
  field('to', 'Test date through', 'date', today).required = true;
  for (const [key, title] of [['unit', 'Series unit'], ['method', 'Series method'], ['specimen', 'Series specimen'], ['laboratory', 'Series laboratory']]) field(key, title);
  const submit = element('button', 'button primary', 'Load laboratory history'); submit.type = 'submit'; form.append(submit);
  form.append(element('p', 'small muted', 'Inclusive test dates. Enter an exact analyte to read trends. Series filters affect trends only; each unit, method, specimen and laboratory stays separate. Text results remain text.'));
  scope.render(scopeResult, { content: form, timezone: context.timezone });
  let version = 0;
  const historyWidget = new Widget('Laboratory history', 'Original observations, report-supplied reference intervals and flags. No invented clinical ranges.');
  const trendWidget = new Widget('Analyte trends', 'Raw points with original units. Unknown method or specimen stays separate from known values.');
  main.insertBefore(historyWidget.node, main.lastChild); main.insertBefore(trendWidget.node, main.lastChild);
  let history = [null], index = 0, args = null, listSerial = 0, seriesSerial = 0;
  function reset() {
    version += 1; listSerial += 1; seriesSerial += 1; args = null; history = [null]; index = 0; drawer.close(); api.cancel('lab-list'); api.cancel('lab-series');
    historyWidget.render({ status: 'empty' }, { message: 'Select a subject and load laboratory history.' });
    trendWidget.render({ status: 'empty' }, { message: 'Choose a subject and enter an analyte to view its trends.' });
  }
  async function loadList() {
    if (!args) return;
    const current = version, serial = ++listSerial;
    const params = Object.fromEntries(['subject_id', 'panel', 'analyte', 'from', 'to'].filter(key => args[key]).map(key => [key, args[key]]));
    if (history[index]) params.cursor = history[index]; params.limit = 25;
    historyWidget.render({ status: 'loading' }, { message: 'Reading permitted observations…' });
    try {
      const result = await api.get('/api/v1/health/labs', params, 'lab-list');
      if (generation !== epoch || current !== version || serial !== listSerial) return;
      const body = element('div'), rows = result.data?.items || [];
      if (rows.length) {
        body.append(labTable(rows));
        const timeline = element('details', 'lab-timeline'); timeline.append(element('summary', '', 'Timeline of this page'));
        const list = element('ol');
        for (const row of rows) list.append(element('li', '', `${row.test_date} · ${row.panel ?? 'Unknown panel'} · ${row.analyte}: ${row.value} ${row.unit ?? 'Unknown unit'} · Flag: ${row.flag ?? 'Unknown'}`));
        timeline.append(list); body.append(timeline);
      }
      body.append(pagination(result.data?.page, { index: index + 1, next: cursor => { history = history.slice(0, index + 1); history.push(cursor); index += 1; loadList(); }, back: () => { index -= 1; loadList(); } }));
      if (index >= 4 && result.data?.page?.next_cursor) body.append(element('p', 'muted', 'Five-page browsing limit reached. Refine the dates, panel or analyte.'));
      historyWidget.render(result, { content: body, timezone: context.timezone, message: result.status === 'empty' ? 'No permitted observations match these filters.' : result.status === 'unavailable' ? 'Laboratory history is unavailable. Check its source limitations.' : null, openEvidence: refs => drawer.show('Laboratory source references', [], refs) });
    } catch (error) { if (generation === epoch && current === version && serial === listSerial && error.name !== 'AbortError') historyWidget.render({ status: 'error' }, { message: message(error), retry: () => { history = [null]; index = 0; loadList(); } }); }
  }
  async function loadSeries() {
    if (!args?.analyte) return;
    const current = version, serial = ++seriesSerial;
    trendWidget.render({ status: 'loading' }, { message: 'Reading separate raw analyte series…' });
    try {
      const result = await api.get('/api/v1/health/labs/series', args, 'lab-series');
      if (generation !== epoch || current !== version || serial !== seriesSerial) return;
      const body = element('div', 'lab-series');
      for (const group of result.data?.series || []) {
        const section = element('section');
        section.append(element('h3', '', [group.analyte, group.unit ?? 'Unknown unit', group.method ?? 'Unknown method', group.specimen ?? 'Unknown specimen', group.laboratory ?? 'Unknown laboratory'].join(' · ')), labChart(group), labTable(group.points));
        if (group.bounded) section.append(element('p', 'warning', 'Only the first 1,000 raw observations are shown. Refine the dates; no aggregation or downsampling was performed.'));
        body.append(section);
      }
      trendWidget.render(result, { content: body, timezone: context.timezone, message: result.status === 'empty' ? 'No permitted series match these filters.' : result.status === 'unavailable' ? 'This series is unavailable. Check its source limitations.' : null });
    } catch (error) { if (generation === epoch && current === version && serial === seriesSerial && error.name !== 'AbortError') trendWidget.render({ status: 'error' }, { message: message(error), retry: loadSeries }); }
  }
  Object.values(controls).forEach(input => { input.addEventListener('input', reset); input.addEventListener('change', reset); });
  form.addEventListener('submit', event => { event.preventDefault(); if (!form.reportValidity()) return; reset(); args = Object.fromEntries(Object.entries(controls).filter(([, field]) => field.value).map(([key, field]) => [key, field.value])); loadList(); loadSeries(); });
  reset();
}
function labTable(rows) {
  const scroll = element('div', 'table-scroll lab-table'), table = element('table', 'results-table');
  table.append(element('caption', 'sr-only', 'Original laboratory results and reference intervals'));
  const head = element('thead'), header = element('tr');
  const keys = ['test_date', 'panel', 'analyte', 'value', 'unit', 'reference_low', 'reference_high', 'reference_text', 'flag', 'specimen', 'laboratory', 'method'];
  for (const title of [...keys, 'Details']) { const th = element('th', '', title.replaceAll('_', ' ')); th.scope = 'col'; header.append(th); } head.append(header); table.append(head);
  const tbody = element('tbody');
  for (const row of rows) {
    const tr = element('tr'); for (const key of keys) tr.append(element('td', '', row[key] ?? 'Unknown'));
    const details = element('td'); details.append(button('View observation', () => drawer.show('Laboratory observation', Object.entries(row).filter(([key]) => key !== 'evidence').map(([key, value]) => [key.replaceAll('_', ' '), value]), row.evidence || []), 'record-link')); tr.append(details); tbody.append(tr);
  }
  table.append(tbody); scroll.append(table); return scroll;
}
function labChart(group) {
  const figure = element('figure');
  figure.append(element('figcaption', 'small muted', 'Original numeric observations by test date; individual report intervals appear as vertical lines when both bounds are recorded. Text results have no plotted point. Exact values and all results remain in the table.'));
  const numeric = group.points.filter(row => typeof row.value === 'number' && Number.isFinite(row.value));
  if (!numeric.length) { figure.append(element('p', 'muted', 'This group contains text results only.')); return figure; }
  const ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg'); svg.setAttribute('viewBox', '0 0 640 250'); svg.setAttribute('width', '100%'); svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', 'Laboratory points in ' + (group.unit ?? 'unknown unit'));
  const values = numeric.flatMap(row => [row.value, row.reference_low, row.reference_high]).filter(value => typeof value === 'number' && Number.isFinite(value));
  const low = Math.min(...values), high = Math.max(...values), dates = group.points.map(row => Date.parse(row.test_date + 'T00:00:00Z'));
  const start = Math.min(...dates), finish = Math.max(...dates);
  const x = row => finish === start ? 320 : 55 + (Date.parse(row.test_date + 'T00:00:00Z') - start) / (finish - start) * 520;
  const y = value => high === low ? 110 : 190 - (value - low) / (high - low) * 160;
  function shape(name, attrs, text) { const node = document.createElementNS(ns, name); for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, String(value)); if (text) node.textContent = text; return node; }
  svg.append(shape('line', { x1: 55, y1: 200, x2: 580, y2: 200, stroke: '#84948b' }));
  for (const row of numeric) {
    if (typeof row.reference_low === 'number' && typeof row.reference_high === 'number' && row.reference_high >= row.reference_low) svg.append(shape('line', { x1: x(row), x2: x(row), y1: y(row.reference_low), y2: y(row.reference_high), stroke: '#8fc1a7', 'stroke-width': 3 }));
    const point = shape('circle', { cx: x(row), cy: y(row.value), r: 4, fill: '#32594b' }); point.append(shape('title', {}, `${row.test_date}: ${row.value} ${group.unit ?? ''}; flag ${row.flag ?? 'Unknown'}`)); svg.append(point);
  }
  svg.append(shape('text', { x: 5, y: 25, fill: '#3f514a', 'font-size': 12 }, String(high)), shape('text', { x: 5, y: 195, fill: '#3f514a', 'font-size': 12 }, String(low)), shape('text', { x: 55, y: 225, fill: '#3f514a', 'font-size': 12 }, new Date(start).toISOString().slice(0, 10)), shape('text', { x: 480, y: 245, fill: '#3f514a', 'font-size': 12 }, new Date(finish).toISOString().slice(0, 10)));
  figure.append(svg); return figure;
}

window.addEventListener('popstate', () => { if (context) renderPage(); });
window.addEventListener('pageshow', event => { if (event.persisted) lock('Verify your session to continue.'); });
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && context && expiresAt && expiresAt <= Date.now()) {
    api.session().then(session => { if (!session.authenticated) lock('Your session expired. Sign in again to continue.'); }).catch(error => { if (error.name !== 'AbortError') lock('Verify your session to continue.'); });
  }
});
lock();
