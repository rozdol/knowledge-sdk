const READS = new Set(['/api/v1/search', '/api/v1/dashboard/availability', '/api/v1/contacts', '/api/v1/contacts/top', '/api/v1/captures', '/api/v1/activity',
  '/api/v1/finance/scopes', '/api/v1/finance/net-worth', '/api/v1/finance/positions', '/api/v1/finance/liabilities', '/api/v1/finance/transactions', '/api/v1/finance/pnl', '/api/v1/health/labs', '/api/v1/health/labs/series']);
export class APIError extends Error {
  constructor(code, status = 0) { super(code); this.code = code; this.status = status; }
}
export class API {
  constructor({ onExpired, onExpiry }) {
    this.onExpired = onExpired;
    this.onExpiry = onExpiry;
    this.csrf = null;
    this.controllers = new Map();
    this.generation = 0;
  }
  cancel(key) { this.controllers.get(key)?.abort(); this.controllers.delete(key); }
  cancelAll() {
    this.generation += 1;
    this.controllers.forEach(controller => controller.abort());
    this.controllers.clear();
  }
  clear() { this.cancelAll(); this.csrf = null; }
  async request(path, { key = path, method = 'GET', body, signal: outside } = {}) {
    this.cancel(key);
    const controller = new AbortController();
    const generation = this.generation;
    this.controllers.set(key, controller);
    const abort = () => controller.abort();
    outside?.addEventListener('abort', abort, { once: true });
    if (outside?.aborted) controller.abort();
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, (path.startsWith('/api/v1/finance/') || path.startsWith('/api/v1/health/')) ? 32000 : 12000);
    const headers = { Accept: 'application/json' };
    if (method === 'POST') { headers['Content-Type'] = 'application/json'; headers['X-CSRF-Token'] = this.csrf || ''; }
    try {
      const response = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal, credentials: 'same-origin', cache: 'no-store', redirect: 'error', referrerPolicy: 'no-referrer' });
      const data = await response.json();
      if (controller.signal.aborted || generation !== this.generation) throw new DOMException('Obsolete request', 'AbortError');
      if (response.status === 401 && path !== '/api/v1/session/login') {
        this.clear(); this.onExpired(); throw new APIError('authentication_required', 401);
      }
      if (!response.ok) throw new APIError(data.error?.code || 'request_failed', response.status);
      const expiry = response.headers.get('x-dashboard-session-expires-at');
      if (expiry) this.onExpiry(expiry);
      return data;
    } catch (error) {
      if (timedOut) throw new APIError('timeout');
      if (controller.signal.aborted || generation !== this.generation) throw new DOMException('Obsolete request', 'AbortError');
      throw error instanceof APIError ? error : new APIError('network_error');
    } finally {
      clearTimeout(timer);
      outside?.removeEventListener('abort', abort);
      if (this.controllers.get(key) === controller) this.controllers.delete(key);
    }
  }
  async session() {
    const session = await this.request('/api/v1/session', { key: 'session' });
    this.csrf = session.csrf_token;
    if (session.expires_at) this.onExpiry(session.expires_at);
    return session;
  }
  async login(secret) {
    const result = await this.request('/api/v1/session/login', { method: 'POST', body: { secret } });
    this.csrf = result.csrf_token;
    this.onExpiry(result.expires_at);
    return result;
  }
  async logout() { return this.request('/api/v1/session/logout', { method: 'POST', body: {} }); }
  get(path, params, key) {
    if (!READS.has(path) && !/^\/api\/v1\/(?:contacts\/person_[0-9A-HJKMNP-TV-Z]{26}(?:\/relations)?|captures\/capture_[0-9A-HJKMNP-TV-Z]{26})$/.test(path)) throw new APIError('unsupported_route');
    const query = new URLSearchParams(params);
    return this.request(path + (query.size ? `?${query}` : ''), { key });
  }
}
