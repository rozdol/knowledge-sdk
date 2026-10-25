import { test, expect, login } from './fixtures.mjs';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

test('real login, search, detail, keyboard navigation and logout', async ({ page, host }) => {
  const failures = [];
  page.on('pageerror', error => failures.push(error.message));
  await login(page, host);
  await page.getByLabel('Search records', { exact: true }).fill('Ada');
  await page.locator('.search-form').getByRole('button', { name: 'Search', exact: true }).click();
  const record = page.locator('.search-area').getByRole('button', { name: 'Ada Synthetic', exact: true });
  await expect(record).toBeVisible();
  await expect(page.locator('.source-version').first()).toContainText('sv_');
  await expect(page.getByRole('button', { name: 'Next', exact: true })).toBeDisabled();
  await record.focus(); await page.keyboard.press('Enter');
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByRole('dialog')).toContainText('person_00000000000000000000000002');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).not.toBeVisible(); await expect(record).toBeFocused();
  await page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: 'Finance', exact: true }).click();
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('See the financial picture.');
  await expect(page.getByText('Unavailable', { exact: true })).toBeVisible();
  await page.goBack(); await expect(page.getByRole('heading', { level: 1 })).toHaveText('Your knowledge, in view.');
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.getByLabel('Access secret', { exact: true })).toBeVisible();
  await expect(page.getByText('Ada Synthetic', { exact: true })).toHaveCount(0);
  expect(failures).toEqual([]);
  expect(await page.evaluate(() => ({ local: localStorage.length, session: sessionStorage.length }))).toEqual({ local: 0, session: 0 });
});

test('category deep links show their implemented or unavailable sources and mobile fits', async ({ page, host }) => {
  await login(page, host, '/medical');
  for (const [path, title] of [['/agenda', 'Make room for what matters.'], ['/finance', 'See the financial picture.'], ['/medical', 'Keep the history together.'], ['/contacts', 'Stay close to your network.'], ['/memory', 'Keep the useful things.'], ['/learning', 'Follow your questions.']]) {
    await page.goto(host.origin + path);
    await expect(page.getByRole('heading', { level: 1 })).toHaveText(title);
    if (['/contacts', '/memory'].includes(path)) await expect(page.getByRole('heading', { name: path === '/contacts' ? 'Contacts' : 'Captures', exact: true })).toBeVisible();
    else await expect(page.getByText('Unavailable', { exact: true }).first()).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
  }
});

test('hostile imported strings remain text and hidden records stay absent', async ({ page, host }) => {
  const external = [];
  page.on('request', request => { if (!request.url().startsWith(host.origin)) external.push(request.url()); });
  await login(page, host, '/search');
  const input = page.getByLabel('Search records', { exact: true });
  await input.fill('Unsafe'); await input.press('Enter');
  await expect(page.locator('.search-area').getByRole('button', { name: 'Synthetic <img src=x onerror=window.injected=true>', exact: true })).toBeVisible();
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
  expect(await page.locator('main img').count()).toBe(0);
  await expect(page.locator('.widget[aria-busy="true"]')).toHaveCount(0);
  await input.fill('Secret'); await input.press('Enter');
  await expect(page.getByText('No permitted identity matches were found.', { exact: false })).toBeVisible();
  await expect(page.getByText('Hidden Synthetic', { exact: true })).toHaveCount(0);
  await expect(page.locator('.widget[aria-busy="true"]')).toHaveCount(0);
  await input.fill('Αδά'); await input.press('Enter');
  await expect(page.locator('.search-area').getByRole('button', { name: 'Ada Synthetic', exact: true })).toBeVisible();
  expect(external).toEqual([]); expect(page.url()).toBe(host.origin + '/search');
});

test('independent errors, retry, and obsolete results', async ({ page, host }) => {
  await page.route('**/api/v1/dashboard/availability', route => route.fulfill({ status: 503, json: { error: { code: 'service_unavailable' } } }));
  await login(page, host);
  await expect(page.getByText('Could not load', { exact: true })).toBeVisible();
  const input = page.getByLabel('Search records', { exact: true });
  await input.fill('Ada'); await input.press('Enter');
  await expect(page.locator('.search-area').getByRole('button', { name: 'Ada Synthetic', exact: true })).toBeVisible();
  await page.unroute('**/api/v1/dashboard/availability');
  await page.getByRole('button', { name: 'Try again', exact: true }).click();
  await expect(page.getByText('Identity search', { exact: true }).last()).toBeVisible();
  let held;
  await page.route('**/api/v1/search?**', async route => { held = route; });
  await input.fill('Ada'); await input.press('Enter');
  await expect(page.locator('.search-area').getByText('Loading', { exact: true })).toBeVisible();
  await page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: 'Memory & lifestyle', exact: true }).click();
  if (held) await held.fulfill({ json: { status: 'ok', data: { items: [{ name: 'Obsolete result', id: 'person_synthetic' }] } } }).catch(() => {});
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Keep the useful things.');
  await expect(page.getByText('Obsolete result', { exact: true })).toHaveCount(0);
});

test('session expiry removes private DOM and pending UI', async ({ page, host }) => {
  await login(page, host, '/search');
  const input = page.getByLabel('Search records', { exact: true });
  await input.fill('Ada'); await input.press('Enter');
  await expect(page.locator('.search-area').getByRole('button', { name: 'Ada Synthetic', exact: true })).toBeVisible();
  await writeFile(join(host.directory, 'clock-shift'), '1801');
  await input.fill('Ada'); await input.press('Enter');
  await expect(page.getByLabel('Access secret', { exact: true })).toBeVisible();
  await expect(page.getByText('Your session expired.', { exact: false })).toBeVisible();
  await expect(page.getByText('Ada Synthetic', { exact: true })).toHaveCount(0);
});

test('shared states, completeness, evidence and date-only values', async ({ page, host }) => {
  await login(page, host, '/search');
  let status = 'partial';
  await page.route('**/api/v1/search?**', route => route.fulfill({ json: {
    status, data: { items: [], page: { returned: 0, next_cursor: null } }, computed_at: '2026-10-25T12:00:00Z',
    warnings: [{ code: 'synthetic_warning', message: 'Synthetic source warning' }],
    completeness: { complete: false, limitations: [{ code: 'fixture', message: 'Synthetic incomplete coverage' }] },
    sources: [{ kind: 'graph', version: 'sv_synthetic', observed_at: '2026-10-25' }],
    evidence: [{ record_id: 'person_00000000000000000000000002', label: 'Synthetic <script>text</script>' }]
  } }));
  for (const [value, label] of [['partial', 'Partial'], ['stale', 'Out of date'], ['unavailable', 'Unavailable'], ['error', 'Could not load']]) {
    status = value;
    const input = page.getByLabel('Search records', { exact: true }); await input.fill('Ada'); await input.press('Enter');
    await expect(page.locator('.search-area').getByText(label, { exact: true })).toBeVisible();
    await expect(page.getByText('Synthetic incomplete coverage', { exact: true })).toBeVisible();
  }
  await page.getByRole('button', { name: 'View 1 source reference', exact: true }).click();
  await expect(page.getByRole('dialog')).toContainText('Synthetic <script>text</script>');
  expect(await page.locator('dialog script').count()).toBe(0);
  await expect(page.getByRole('dialog')).toContainText('person_00000000000000000000000002');
  await page.keyboard.press('Escape');
  await expect(page.getByText('graph: source updated 2026-10-25', { exact: true })).toBeVisible();
});

test('changing filters cancels loading and failed logout keeps private DOM cleared', async ({ page, host }) => {
  await login(page, host, '/search');
  await page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: 'Home', exact: true }).click();
  await page.locator('.topbar').getByRole('link', { name: 'Search', exact: true }).click();
  await page.route('**/api/v1/search?**', () => {});
  const input = page.getByLabel('Search records', { exact: true });
  await input.fill('Ada'); await input.press('Enter');
  await expect(page.locator('.search-area').getByText('Loading', { exact: true })).toBeVisible();
  await input.fill('Secret');
  await expect(page.getByText('Search again with the updated text and filters.', { exact: true })).toBeVisible();
  await page.unroute('**/api/v1/search?**');
  await page.route('**/api/v1/session/logout', route => route.abort());
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Your local view is cleared.', exact: true })).toBeVisible();
  await expect(page.getByLabel('Search records', { exact: true })).toHaveCount(0);
  await page.goBack();
  await expect(page.getByLabel('Search records', { exact: true })).toHaveCount(0);
  await page.unroute('**/api/v1/session/logout');
  await page.getByRole('button', { name: 'Retry sign out', exact: true }).click();
  await expect(page.getByLabel('Access secret', { exact: true })).toBeVisible();
});

test('P3 contact ranking, permitted details and relations work independently', async ({ page, host }) => {
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await login(page, host, '/contacts');
  const ranking = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Top recorded contacts', exact: true }) });
  await expect(ranking.getByRole('button', { name: 'Ada Synthetic', exact: true })).toBeVisible();
  await expect(ranking).toContainText('1 interactions');
  const contact = page.locator('.domain-list').getByRole('button', { name: 'Ada Synthetic', exact: true });
  await contact.focus(); await page.keyboard.press('Enter');
  const dialog = page.getByRole('dialog');
  await expect(dialog).toContainText('Ranking formula');
  await expect(dialog).toContainText('interaction-v1');
  await expect(dialog).toContainText('Other Synthetic');
  await expect(dialog).toContainText('Private contact access not enabled');
  await expect(dialog).not.toContainText('Hidden Synthetic');
  await page.keyboard.press('Escape'); await expect(contact).toBeFocused();
  await page.route('**/api/v1/contacts/top?**', route => route.fulfill({ status: 503, json: { error: { code: 'service_unavailable' } } }));
  await page.getByRole('button', { name: 'Update ranking', exact: true }).click();
  await expect(ranking.getByText('Could not load', { exact: true })).toBeVisible();
  await expect(contact).toBeVisible();
  expect(errors).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
});

test('P3 Capture history and learning resources use literal text and distinct sources', async ({ page, host }) => {
  const external = []; page.on('request', request => { if (!request.url().startsWith(host.origin)) external.push(request.url()); });
  await login(page, host, '/memory');
  const resource = page.getByRole('button', { name: 'Synthetic research resource', exact: true });
  await expect(resource).toBeVisible(); await resource.click();
  await expect(page.getByRole('dialog')).toContainText('Complete plain-text rendition');
  await expect(page.getByRole('dialog')).toContainText('neverExecute()');
  expect(await page.locator('dialog script').count()).toBe(0);
  await page.keyboard.press('Escape');
  const activity = page.locator('.domain-list').filter({ has: page.getByRole('heading', { name: 'Knowledge activity', exact: true }) });
  await expect(activity).toContainText('knowledge added');
  await expect(activity).toContainText('dataset activity not available');
  await expect(activity).not.toContainText('Hidden Synthetic');
  await page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: 'Learning & research', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Learning progress', exact: true })).toBeVisible();
  await expect(page.getByText('Unavailable', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Synthetic research resource', exact: true })).toBeVisible();
  expect(external).toEqual([]);
});

test('P3 federated search has per-source states and source change restarts paging', async ({ page, host }) => {
  await login(page, host, '/search');
  const input = page.getByLabel('Search records', { exact: true });
  await expect(page.locator('.widget[aria-busy="true"]')).toHaveCount(0);
  await input.fill('Αδά'); await input.press('Enter');
  await expect(page.locator('.search-area').getByRole('button', { name: 'Ada Synthetic', exact: true })).toBeVisible();
  await expect(page.locator('.domain-list').getByRole('button', { name: 'Synthetic research resource', exact: true })).toBeVisible();
  await expect(page.getByText('Each source reports its own state.', { exact: false })).toBeVisible();
  await expect(page.locator('.widget[aria-busy="true"]')).toHaveCount(0);
  // Controlled response tests the UI consumer of the real server cursor contract.
  let changed = false;
  await page.route('**/api/v1/contacts?**', route => {
    if (route.request().url().includes('cursor=')) return route.fulfill({ status: 409, json: { error: { code: 'context_changed' } } });
    changed = true;
    return route.fulfill({ json: { status: 'ok', data: { items: [{ id: 'person_00000000000000000000000002', name: 'Ada Synthetic', record_status: 'active' }], page: { returned: 1, next_cursor: 'A'.repeat(43) } } } });
  });
  await page.getByLabel('Search contact matches', { exact: true }).fill('Ada');
  const contacts = page.locator('.domain-list').filter({ has: page.getByRole('heading', { name: 'Contact matches', exact: true }) });
  await contacts.getByRole('button', { name: 'Apply filters', exact: true }).click();
  await contacts.getByRole('button', { name: 'Next', exact: true }).click();
  await expect(contacts).toContainText('The source or page context changed.');
  await contacts.getByRole('button', { name: 'Try again', exact: true }).click();
  await expect(contacts).toContainText('Page 1'); expect(changed).toBe(true);
  expect(page.url()).toBe(host.origin + '/search');
});
