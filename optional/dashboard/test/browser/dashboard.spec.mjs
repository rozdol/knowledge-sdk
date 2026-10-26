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

test('Finance requires explicit scope, exact tables, missing FX and monthly native charts', async ({ page, financeHost: host }) => {
  const failures = [], external = [];
  page.on('pageerror', error => failures.push(error.message));
  page.on('request', request => { if (!request.url().startsWith(host.origin)) external.push(request.url()); });
  await login(page, host, '/finance');
  const owner = page.getByLabel('Financial owner', { exact: true });
  await expect(owner).toHaveValue('');
  await expect(page.getByRole('button', { name: 'Load financial reports', exact: true })).toBeVisible();
  await owner.selectOption('financialowner_00000000000000000000000001');
  await page.getByRole('button', { name: 'Load financial reports', exact: true }).click();
  const worth = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Owner net worth', exact: true }) });
  const positions = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Positions', exact: true }) });
  const transactions = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Immutable transactions', exact: true }) });
  const pnl = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Investment P&L', exact: true }) });
  await expect(worth).toContainText('Net worth: Unavailable EUR');
  await expect(positions.getByRole('cell', { name: '0.2', exact: true })).toBeVisible();
  await expect(positions.getByRole('cell', { name: 'USD', exact: true })).toBeVisible();
  await expect(transactions.getByRole('cell', { name: 'SELL', exact: true })).toBeVisible();
  await expect(pnl.locator('tbody tr')).toHaveCount(1);
  await positions.getByRole('button', { name: 'View details', exact: true }).click();
  await expect(page.getByRole('dialog')).toContainText('0.04');
  await page.keyboard.press('Escape');
  await page.getByLabel('Net worth reporting currency', { exact: true }).selectOption('USD');
  await page.getByLabel('Investment P&L period', { exact: true }).selectOption('monthly');
  await expect(positions.locator('tbody tr')).toHaveCount(0);
  await page.getByRole('button', { name: 'Load financial reports', exact: true }).click();
  await expect(worth).toContainText('Net worth: 0.059 USD');
  await expect(pnl.getByRole('img', { name: 'Monthly investment P&L in USD', exact: true })).toBeVisible();
  await expect(pnl).toContainText('Missing P&L has no bar');
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
  expect(await page.locator('main img').count()).toBe(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
  expect(external).toEqual([]); expect(failures).toEqual([]);
  await page.screenshot({ path: `../../output/playwright/p4-${test.info().project.name}.png`, fullPage: true });
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.getByText('0.059', { exact: true })).toHaveCount(0);
});

test('Finance isolates failures and cancels obsolete filter results', async ({ page, financeHost: host }) => {
  let fail = true;
  await page.route('**/api/v1/finance/pnl?**', async route => {
    if (fail) { fail = false; await route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: { code: 'internal_error' } }) }); }
    else await route.continue();
  });
  await login(page, host, '/finance');
  await page.getByLabel('Financial owner', { exact: true }).selectOption('financialowner_00000000000000000000000001');
  await page.getByLabel('Net worth reporting currency', { exact: true }).selectOption('USD');
  await page.getByRole('button', { name: 'Load financial reports', exact: true }).click();
  const pnl = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Investment P&L', exact: true }) });
  const worth = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Owner net worth', exact: true }) });
  await expect(pnl).toHaveAttribute('data-state', 'error');
  await expect(worth).toContainText('Net worth: 0.059 USD');
  await pnl.getByRole('button', { name: 'Try again', exact: true }).click();
  await expect(pnl.locator('tbody tr')).toHaveCount(1);
  await page.route('**/api/v1/finance/net-worth?**', async route => {
    const response = await route.fetch(); await new Promise(resolve => setTimeout(resolve, 500));
    await route.fulfill({ response });
  });
  await page.getByRole('button', { name: 'Load financial reports', exact: true }).click();
  await expect(worth).toHaveAttribute('data-state', 'loading');
  await page.getByLabel('Financial owner', { exact: true }).selectOption('');
  await expect(worth).toHaveAttribute('data-state', 'empty');
  await page.waitForTimeout(800);
  await expect(worth).not.toContainText('0.059');
  await expect(worth).toContainText('Select an owner');
});

test('Medical scopes original results, separate series and literal clinical context', async ({ page, healthHost: host }) => {
  const errors = [], external = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => { if (!request.url().startsWith(host.origin)) external.push(request.url()); });
  await login(page, host, '/medical');
  const subject = page.getByLabel('Laboratory subject', { exact: true });
  await expect(subject).toHaveValue('');
  await expect(subject).not.toContainText('Hidden synthetic patient');
  await subject.selectOption('person_00000000000000000000000011');
  await page.getByRole('button', { name: 'Load laboratory history', exact: true }).click();
  const history = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Laboratory history', exact: true }) });
  const trends = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Analyte trends', exact: true }) });
  await expect(history.locator('tbody tr')).toHaveCount(9);
  await expect(history.getByRole('cell', { name: 'Negative', exact: true })).toBeVisible();
  await expect(history.getByRole('cell', { name: '<5', exact: true })).toBeVisible();
  await expect(history.getByRole('cell', { name: '777', exact: true })).toHaveCount(0);
  await expect(history.getByRole('columnheader', { name: 'analyte', exact: true })).toBeVisible();
  await history.getByText('Timeline of this page', { exact: true }).click();
  await expect(history.locator('.lab-timeline ol li')).toHaveCount(9);
  await history.getByRole('button', { name: 'View observation', exact: true }).first().click();
  await expect(page.getByRole('dialog')).toContainText('test date');
  await expect(page.getByRole('dialog')).not.toContainText('source_uri');
  await page.keyboard.press('Escape');
  await page.getByLabel('Analyte (exact recorded name)', { exact: true }).fill('Novel assay <img src=x onerror=window.injected=true>');
  await page.getByRole('button', { name: 'Load laboratory history', exact: true }).click();
  await expect(trends.locator('.lab-series > section')).toHaveCount(6);
  await expect(trends.getByRole('img', { name: 'Laboratory points in mmol/L', exact: true })).toBeVisible();
  await expect(trends.getByText('This group contains text results only.', { exact: true })).toBeVisible();
  await expect(trends).toContainText('Unknown method');
  await expect(trends).toContainText('assay B');
  await expect(trends).toContainText('Original interval');
  await expect(page.getByText('Diagnosis and treatment recommendations are unavailable.', { exact: false })).toBeVisible();
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
  expect(await page.locator('main img, main script').count()).toBe(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
  expect(external).toEqual([]); expect(errors).toEqual([]);
  await page.screenshot({ path: `../../output/playwright/p5-${test.info().project.name}.png`, fullPage: true });
  await page.screenshot({ path: `../../output/playwright/p5-viewport-${test.info().project.name}.png` });
  await subject.selectOption('person_00000000000000000000000012');
  await expect(history.locator('tbody tr')).toHaveCount(0);
  await page.getByRole('button', { name: 'Load laboratory history', exact: true }).click();
  await expect(history.getByRole('cell', { name: '777', exact: true })).toBeVisible();
  await expect(history.getByRole('cell', { name: 'Negative', exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.getByLabel('Laboratory subject', { exact: true })).toHaveCount(0);
});

test('Medical series failure stays independent and obsolete subject results are cancelled', async ({ page, healthHost: host }) => {
  let fail = true;
  await page.route('**/api/v1/health/labs/series?**', async route => {
    if (fail) { fail = false; await route.fulfill({ status: 500, json: { error: { code: 'internal_error' } } }); }
    else await route.continue();
  });
  await login(page, host, '/medical');
  const subject = page.getByLabel('Laboratory subject', { exact: true });
  await subject.selectOption('person_00000000000000000000000011');
  await page.getByLabel('Analyte (exact recorded name)', { exact: true }).fill('Novel assay <img src=x onerror=window.injected=true>');
  await page.getByRole('button', { name: 'Load laboratory history', exact: true }).click();
  const history = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Laboratory history', exact: true }) });
  const trends = page.locator('.widget').filter({ has: page.getByRole('heading', { name: 'Analyte trends', exact: true }) });
  await expect(history.locator('tbody tr')).toHaveCount(9);
  await expect(trends).toHaveAttribute('data-state', 'error');
  await trends.getByRole('button', { name: 'Try again', exact: true }).click();
  await expect(trends.locator('.lab-series > section')).toHaveCount(6);
  await page.route('**/api/v1/health/labs?**', async route => {
    const response = await route.fetch(); await new Promise(resolve => setTimeout(resolve, 500)); await route.fulfill({ response });
  });
  await page.getByRole('button', { name: 'Load laboratory history', exact: true }).click();
  await expect(history).toHaveAttribute('data-state', 'loading');
  await subject.selectOption('');
  await expect(history).toHaveAttribute('data-state', 'empty');
  await page.waitForTimeout(800);
  await expect(history.locator('tbody tr')).toHaveCount(0);
  await expect(trends.locator('svg')).toHaveCount(0);
  expect(page.url()).toBe(host.origin + '/medical');
});
