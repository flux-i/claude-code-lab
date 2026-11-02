'use strict';

// Runs only during token acquisition. It never operates the Teams interface.
async function resourceTokens({ oid, configs = [], forceRefresh = false }) {
  const tokens = [], discovered = new Map(configs.map(config => [config.origin, config]));
  for (const storage of [localStorage, sessionStorage]) {
    for (let i = 0; i < storage.length; i++) {
      const key = storage.key(i);
      if (!/auth|token|msal/i.test(key)) continue;
      let entry; try { entry = JSON.parse(storage.getItem(key)); } catch (_) { continue; }
      const value = entry?.secret || entry?.token || entry?.accessToken;
      if (typeof value !== 'string' || !/^eyJ[\w-]+\.[\w-]+\.[\w-]+$/.test(value)) continue;
      let claims; try { claims = JSON.parse(atob(value.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); } catch (_) { continue; }
      if (claims.oid !== oid || claims.aud !== '00000003-0000-0ff1-ce00-000000000000') continue;
      const origin = entry.target?.match(/https:\/\/[a-z\d.-]+\.sharepoint\.com(?=\/|\s|$)/i)?.[0];
      if (!origin) continue;
      const config = { origin, clientId: entry.clientId || claims.appid, tenant: entry.realm || claims.tid };
      discovered.set(origin, config);
      if (!forceRefresh && claims.exp * 1000 > Date.now() + 10000) {
        tokens.push({ ...config, secret: value, expiresAt: claims.exp * 1000 });
      }
    }
  }
  const errors = [];
  const missing = [...discovered.values()].filter(config => !tokens.some(token => token.origin === config.origin));
  if (missing.length) {
    let runtime;
    const chunks = window.webpackChunk_msteams_react_web_client;
    chunks?.push([['codex-token-acquisition-' + Date.now()], {}, require => { runtime = require; }]);
    let Ctor;
    try {
      if (runtime && !runtime.r) runtime.r = exports => {
        Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
        Object.defineProperty(exports, '__esModule', { value: true });
      };
      Ctor = runtime?.m?.[55211] ? runtime(55211).vq : null;
    } catch (_) { errors.push({ stage: 'sdk_import', code: 'token_sdk_unavailable' }); }
    for (const config of missing) {
      let stage = 'sdk';
      try {
        if (typeof Ctor !== 'function' || typeof Ctor.prototype.acquireTokenSilent !== 'function') throw new Error('sdk_unavailable');
        if (!/^[a-f\d-]{36}$/i.test(config.clientId) || !/^[a-f\d-]{36}$/i.test(config.tenant)) throw new Error('config_invalid');
        const client = new Ctor({ auth: { clientId: config.clientId, authority: 'https://login.microsoftonline.com/' + config.tenant,
          redirectUri: location.origin + '/v2/' }, cache: { cacheLocation: 'localStorage' },
          system: { loggerOptions: { loggerCallback: () => {}, piiLoggingEnabled: false } } });
        stage = 'initialize'; await client.initialize();
        stage = 'account';
        const accounts = await client.getAllAccounts();
        const account = accounts.find(account => account.localAccountId === oid && account.tenantId === config.tenant);
        if (!account) throw new Error('exact_account_unavailable');
        stage = 'silent_refresh';
        const result = await client.acquireTokenSilent({ account, scopes: [config.origin + '/.default'], forceRefresh: true });
        if (!result.accessToken || !result.expiresOn) throw new Error('token_unavailable');
        tokens.push({ ...config, secret: result.accessToken, expiresAt: result.expiresOn.getTime() });
      } catch (error) { errors.push({ origin: config.origin, stage, code: error.errorCode || error.name || 'token_refresh_failed' }); }
    }
  }
  return { tokens, configs: [...discovered.values()], errors };
}

module.exports = { resourceTokens };
