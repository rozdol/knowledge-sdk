export function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}
export function button(text, action, className = 'button secondary') {
  const node = element('button', className, text);
  node.type = 'button'; node.addEventListener('click', action); return node;
}
const STATES = new Set(['loading', 'ok', 'empty', 'partial', 'unavailable', 'stale', 'error']);
const LABELS = { loading: 'Loading', ok: 'Ready', empty: 'No results', partial: 'Partial', unavailable: 'Unavailable', stale: 'Out of date', error: 'Could not load' };
export function timestamp(value, timezone) {
  if (!value) return 'Unknown';
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return value;
  try { return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short', timeZone: timezone }).format(new Date(value)); }
  catch { return 'Unknown'; }
}
export class Widget {
  constructor(title, description) {
    this.node = element('section', 'widget');
    const header = element('header', 'widget-header');
    const titles = element('div'); titles.append(element('h2', '', title));
    if (description) titles.append(element('p', 'muted', description));
    this.badge = element('span', 'state'); this.badge.setAttribute('role', 'status');
    header.append(titles, this.badge);
    this.body = element('div', 'widget-body');
    this.meta = element('footer', 'widget-meta');
    this.node.append(header, this.body, this.meta);
  }
  render(result, { content, message, retry, openEvidence, timezone = 'Etc/UTC' } = {}) {
    const status = STATES.has(result?.status) ? result.status : 'error';
    this.node.dataset.state = status;
    this.node.setAttribute('aria-busy', String(status === 'loading'));
    this.badge.textContent = LABELS[status];
    this.badge.className = `state state-${status}`;
    this.body.replaceChildren(); this.meta.replaceChildren();
    if (message) this.body.append(element('p', `state-message ${status === 'error' ? 'error-copy' : 'muted'}`, message));
    if (content && !['loading', 'unavailable', 'error'].includes(status)) this.body.append(content);
    if (retry) this.body.append(button('Try again', retry));
    for (const warning of [...(result?.warnings || []), ...(result?.completeness?.limitations || [])].slice(0, 10)) {
      const text = typeof warning === 'string' ? warning : warning.message;
      if (text && !Array.from(this.meta.children).some(child => child.textContent === text)) this.meta.append(element('p', 'warning', text));
    }
    if (result?.computed_at) this.meta.append(element('p', '', `Computed ${timestamp(result.computed_at, timezone)} · ${timezone}`));
    for (const source of (result?.sources || []).slice(0, 10)) {
      this.meta.append(element('p', '', `${source.kind}: source updated ${timestamp(source.observed_at, timezone)}`));
      if (source.version) this.meta.append(element('p', 'source-version', `Version ${source.version}`));
    }
    const refs = (result?.evidence || []).slice(0, 20);
    if (refs.length && openEvidence) this.meta.append(button(`View ${refs.length} source reference${refs.length === 1 ? '' : 's'}`, () => openEvidence(refs), 'text-button'));
    this.meta.hidden = this.meta.childElementCount === 0;
  }
}
export function pagination(page, { next, back, index = 1 } = {}) {
  const nav = element('nav', 'pagination'); nav.setAttribute('aria-label', 'Result pages');
  const previous = button('Previous', () => back?.()); previous.disabled = !back || index <= 1;
  const following = button('Next', () => next?.(page.next_cursor));
  following.disabled = !next || !page?.next_cursor || index >= 5;
  nav.append(previous, element('span', 'muted', `Page ${index} · ${Number(page?.returned || 0)} shown`), following);
  return nav;
}
export class Drawer {
  constructor() {
    this.node = element('dialog', 'drawer'); this.node.setAttribute('aria-labelledby', 'drawer-title');
    this.node.addEventListener('close', () => { if (this.node.open) return; this.node.replaceChildren(); if (this.opener?.isConnected) this.opener.focus(); this.opener = null; });
    document.body.append(this.node);
  }
  show(title, fields, evidence = []) {
    const opener = this.node.open && this.opener?.isConnected ? this.opener : document.activeElement;
    this.close(); this.opener = opener;
    const header = element('header', 'drawer-header');
    const heading = element('h2', '', title); heading.id = 'drawer-title';
    const close = button('Close', () => this.close()); close.autofocus = true;
    header.append(heading, close); this.node.append(header);
    const list = element('dl', 'record-fields');
    for (const [label, value] of fields) { list.append(element('dt', '', label), element('dd', '', Array.isArray(value) ? value.join(', ') : (value ?? 'Unknown'))); }
    this.node.append(list);
    this.node.append(element('h3', '', 'Source references'));
    if (!evidence.length) this.node.append(element('p', 'muted', 'No source references were supplied. Source preview is unavailable.'));
    for (const ref of evidence.slice(0, 20)) {
      const item = element('div', 'evidence-reference');
      item.append(element('p', '', ref.label || ref.role || 'Source reference'), element('p', 'mono', ref.record_id || ref.evidence_id || 'Reference unavailable'));
      this.node.append(item);
    }
    this.node.append(element('p', 'muted small', 'This view shows permitted fields only. It does not open files or attachments.'));
    this.node.showModal();
  }
  close() { if (this.node.open) this.node.close(); this.node.replaceChildren(); }
}
