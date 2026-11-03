const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const headers = {'Cache-Control': 'no-store', 'Pragma': 'no-cache', 'Content-Type': 'application/json; charset=utf-8', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'"};
const reply = (value, status = 200, extra = {}) => new Response(JSON.stringify(value), {status, headers: {...headers, ...extra}});
const failure = (error, status) => reply({error}, status);
async function boundedText(body, maximum) {
  if (!body) throw new Error('empty_body');
  const reader = body.getReader(); let size = 0, parts = [];
  try {
    for (;;) {
      const {value, done} = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > maximum) { await reader.cancel(); throw new Error('too_large'); }
      parts.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
  return new TextDecoder('utf-8', {fatal: true}).decode(bytes);
}
export function validRedirect(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'http:' && url.hostname === '127.0.0.1' && /^\d+$/.test(url.port) && +url.port >= 1024 && +url.port <= 65535 && url.pathname === '/' && !url.username && !url.password && !url.search && !url.hash && value === `http://127.0.0.1:${url.port}/`;
  } catch { return false; }
}
export function tokenFields(form, clientID) {
  const grant = form.get('grant_type');
  const allowed = grant === 'authorization_code' ? ['grant_type', 'client_id', 'code', 'code_verifier', 'redirect_uri'] : grant === 'refresh_token' ? ['grant_type', 'client_id', 'refresh_token'] : [];
  if (!allowed.length || form.get('client_id') !== clientID) return null;
  if ([...form.keys()].some(key => !allowed.includes(key) || form.getAll(key).length !== 1)) return null;
  const safe = value => typeof value === 'string' && value.length > 0 && !/[\x00-\x1f\x7f]/.test(value);
  if (grant === 'authorization_code') {
    if (!safe(form.get('code')) || form.get('code').length > 4096 || !/^[A-Za-z0-9._~-]{43,128}$/.test(form.get('code_verifier') ?? '') || !validRedirect(form.get('redirect_uri'))) return null;
  } else if (!safe(form.get('refresh_token')) || form.get('refresh_token').length > 8192) return null;
  return new URLSearchParams(form);
}
export function createHandler(upstream = (...args) => globalThis.fetch(...args)) {
  return async function handle(request, env) {
    try {
      const url = new URL(request.url);
      if (url.protocol !== 'https:') return failure('https_required', 400);
      const ready = Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET && env.AUTH_RATE_LIMITER);
      if (url.pathname === '/health' && request.method === 'GET') return reply({service: 'minutes-google-auth', ready}, ready ? 200 : 503);
      if (url.pathname !== '/v1/token' || url.search || url.hash) return failure('not_found', 404);
      if (request.method !== 'POST') return failure('method_not_allowed', 405);
      // Native requests carry an OAuth code+PKCE proof, or a private refresh
      // token. Never use browser cookies, CORS, or a shared API key in the app.
      if (request.headers.has('Origin')) return failure('browser_request_rejected', 403);
      if ((request.headers.get('Content-Type') ?? '').split(';')[0].trim().toLowerCase() !== 'application/x-www-form-urlencoded') return failure('unsupported_media_type', 415);
      if (!ready) return failure('service_unconfigured', 503);
      const ip = request.headers.get('CF-Connecting-IP');
      if (!ip) return failure('edge_identity_missing', 503);
      const {success} = await env.AUTH_RATE_LIMITER.limit({key: ip});
      if (!success) return reply({error: 'rate_limited'}, 429, {'Retry-After': '60'});
      const size = request.headers.get('Content-Length');
      if (size && (!/^\d+$/.test(size) || +size > 16384)) return failure('request_too_large', 413);
      let form;
      try { form = new URLSearchParams(await boundedText(request.body, 16384)); }
      catch { return failure('invalid_request', 400); }
      const fields = tokenFields(form, env.GOOGLE_CLIENT_ID);
      if (!fields) return failure('invalid_request', 400);
      fields.set('client_secret', env.GOOGLE_CLIENT_SECRET);
      let response;
      try {
        response = await upstream(GOOGLE_TOKEN_URL, {method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(20000), headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: fields.toString()});
      } catch (error) { return failure(error?.name === 'TimeoutError' || error?.name === 'AbortError' ? 'provider_timeout' : 'provider_transport_error', 502); }
      let data;
      try { data = JSON.parse(await boundedText(response.body, 65536)); }
      catch { return failure('provider_response_invalid', 502); }
      if (!response.ok) {
        if (response.status === 429) return reply({error: 'provider_busy'}, 429, {'Retry-After': '60'});
        if (data.error === 'invalid_grant') return failure('reconnect_required', 401);
        if (['invalid_client', 'unauthorized_client'].includes(data.error)) return failure('service_unconfigured', 503);
        return failure('provider_unavailable', 502);
      }
      if (typeof data.access_token !== 'string' || !data.access_token || typeof data.expires_in !== 'number' || !Number.isFinite(data.expires_in) || data.expires_in <= 0 || (fields.get('grant_type') === 'authorization_code' && (typeof data.refresh_token !== 'string' || !data.refresh_token))) return failure('provider_response_invalid', 502);
      const allowedScopes = new Set(['https://www.googleapis.com/auth/calendar.events.readonly', 'https://www.googleapis.com/auth/calendar.calendarlist.readonly']);
      const granted = typeof data.scope === 'string' ? new Set(data.scope.split(/\s+/).filter(Boolean)) : new Set();
      if (granted.size !== allowedScopes.size || [...granted].some(scope => !allowedScopes.has(scope))) return failure('calendar_permission_required', 403);
      // No provider diagnostics, client secret, or unrelated identity fields.
      const result = {access_token: data.access_token, expires_in: data.expires_in};
      for (const key of ['refresh_token', 'scope', 'token_type']) if (typeof data[key] === 'string') result[key] = data[key];
      return reply(result);
    } catch { return failure('service_unavailable', 503); }
  };
}
export default {fetch: createHandler()};
