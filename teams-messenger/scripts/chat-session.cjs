'use strict';

const web = { ...require('./cli-common.cjs'), ...require('./token-browser.cjs') };
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');
const { resourceTokens } = require('./token-resources.cjs');
const directory = process.env.TEAMS_WEB_APP_DIR || path.join(os.homedir(), 'Library', 'Application Support', 'Codex Teams Messenger');
const configPath = path.join(directory, 'auth-resources.json');
const trusted = host => host === 'teams.microsoft.com' || host.endsWith('.teams.microsoft.com')
  || host === 'teams.cloud.microsoft' || host.endsWith('.teams.cloud.microsoft');
function fail(code, message) { return Object.assign(new Error(message), { code }); }
function email(value) {
  const result = web.validateEmail(value);
  if (/["\\\[\]\x00-\x1f]/.test(result)) throw fail('invalid_recipient', 'Use one complete email address.');
  return result;
}
function memberFromToken(value) {
  try {
    const jwt = value.match(/eyJ[\w-]+\.[\w-]+\.[\w-]+/)[0];
    const claims = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url'));
    let member = claims.skypeid || claims.oid;
    if (typeof member !== 'string') throw new Error();
    if (/^[a-f\d-]{36}$/i.test(member)) member = '8:orgid:' + member;
    else if (member.startsWith('orgid:')) member = '8:' + member;
    if (!/^8:orgid:[a-f\d-]{36}$/i.test(member)) throw new Error();
    return { self: member, expiresAt: typeof claims.exp === 'number' ? claims.exp * 1000 : null };
  } catch (_) { throw fail('sender_identity_unavailable', 'The chat-service credential has no recognizable sender identity.'); }
}

// Accept only a bearer credential for Outlook, issued to the signed-in user, that allows calendar writes.
function outlookToken(header, oid) {
  const match = /^Bearer (eyJ[\w-]+\.([\w-]+)\.[\w-]+)$/.exec(String(header || ''));
  if (!match) return null;
  let claims; try { claims = JSON.parse(Buffer.from(match[2], 'base64url')); } catch (_) { return null; }
  if (!['https://outlook.office.com', 'https://outlook.office.com/'].includes(claims.aud)) return null;
  if (String(claims.oid).toLowerCase() !== String(oid).toLowerCase()) return null;
  if (!String(claims.scp || '').split(' ').includes('Calendars.ReadWrite')) return null;
  if (typeof claims.exp !== 'number' || claims.exp * 1000 <= Date.now() + 60000) return null;
  return { secret: match[1], expiresAt: claims.exp * 1000 };
}

class ChatSession {
  constructor({ outlook = false } = {}) {
    this.credentials = null; this.actor = null; this.captureError = null; this.resources = [];
    this.wantOutlook = outlook; this.outlook = null;
  }
  async start({ forceResourceRefresh = false } = {}) {
    this.credentials = null; this.outlook = null;
    this.acquiring = true;
    this.context = await web.launchPersistent(true);
    try {
    this.context.on('request', request => { this.capture(request).catch(error => {
      if (this.acquiring && error.code === 'sender_identity_unavailable') this.captureError = true;
    }); });
    this.page = await web.currentPage(this.context);
    this.page = await web.gotoTeamsHome(this.context, this.page);
    if (!await web.waitForTeamsShell(this.page, 60000)) throw fail('authentication_required', 'Sign in using: teams auth');
    await this.waitForCredentials();
    let configs = [];
    try {
      const saved = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      if (saved.senderId === this.credentials.self) configs = saved.configs;
    } catch (error) { if (error.code !== 'ENOENT') throw fail('auth_resource_config_invalid', 'The resource configuration is unreadable.'); }
    const result = await this.page.evaluate(resourceTokens, { oid: this.credentials.self.split(':').pop(), configs,
      forceRefresh: forceResourceRefresh });
    this.resources = result.tokens;
    this.resourceErrors = result.errors;
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    fs.writeFileSync(configPath, JSON.stringify({ senderId: this.credentials.self, configs: result.configs }), { mode: 0o600 });
    fs.chmodSync(configPath, 0o600);
    if (this.wantOutlook) await this.acquireOutlook();
    // Browser lifetime ends here. Every operational command below uses HTTP only.
    return this;
    } finally {
      this.acquiring = false;
      this.context?.removeAllListeners('request');
      await this.context?.close().catch(() => {}); this.context = null; this.page = null;
    }
  }
  // The Teams calendar is Outlook on the web hosted inside Teams. Opening it makes the hosted
  // calendar call outlook.office.com with the user's Outlook credential, which is captured in memory.
  async acquireOutlook() {
    const oid = this.credentials.self.split(':').pop();
    this.context.on('request', request => {
      if (!this.acquiring || this.outlook) return;
      let url; try { url = new URL(request.url()); } catch (_) { return; }
      if (url.protocol !== 'https:' || url.hostname !== 'outlook.office.com') return;
      request.allHeaders().then(headers => {
        if (!this.acquiring || this.outlook) return;
        const token = outlookToken(headers.authorization, oid);
        if (token) this.outlook = token;
      }).catch(() => {});
    });
    await this.page.locator('[data-tid="app-bar-ef56c0de-36fc-4ef8-b417-3d82ba9d073c"], button[aria-label^="Calendar"]')
      .first().click({ timeout: 15000 }).catch(() => { throw fail('calendar_unavailable', 'The Teams calendar could not be opened for Outlook authentication.'); });
    for (let i = 0; i < 60 && !this.outlook; i++) await this.page.waitForTimeout(500);
    if (!this.outlook) throw fail('outlook_auth_unavailable', 'No usable Outlook calendar credential appeared in the background session.');
  }
  outlookCredential() {
    if (!this.outlook || this.outlook.expiresAt <= Date.now() + 5000) throw fail('outlook_auth_unavailable', 'The Outlook calendar credential is unavailable or expired.');
    return this.outlook;
  }
  async capture(request) {
    if (!this.acquiring) return;
    if (request.method() !== 'GET') return;
    const u = new URL(request.url());
    const route = u.pathname.match(/^(.*\/api\/chatsvc\/.*\/v1\/users\/ME\/conversations)(?:\/|$)/i);
    if (u.protocol !== 'https:' || !trusted(u.hostname) || !route) return;
    const all = await request.allHeaders();
    if (!this.acquiring) return;
    const headers = Object.fromEntries(Object.entries(all).filter(([key]) => /^(authorization|authentication|x-skypetoken)$/i.test(key)));
    if (!Object.keys(headers).length) return;
    const identity = memberFromToken(Object.values(headers).join(' '));
    if (identity.expiresAt && identity.expiresAt <= Date.now() + 5000) return;
    if (this.actor && this.actor !== identity.self) { this.captureError = true; return; }
    this.actor = identity.self;
    this.credentials = { headers, base: u.origin + route[1], ...identity };
  }
  async waitForCredentials() {
    for (let i = 0; i < 40; i++) {
      if (this.captureError) throw fail('authentication_changed', 'The background session credential changed or could not be verified.');
      if (this.credentials) return;
      await this.page.waitForTimeout(500);
    }
    throw fail('chat_service_auth_unavailable', 'No usable chat-service credential appeared in the background session.');
  }
  async refresh() { await this.start({ forceResourceRefresh: true }); }
  resource(origin) {
    const result = this.resources.find(token => token.origin === origin && token.expiresAt > Date.now() + 5000);
    if (!result) throw fail('resource_token_unavailable', 'A required SharePoint credential is unavailable; run teams auth if silent token refresh cannot complete.');
    return result;
  }
  async resolve(recipient) {
    const { SharePointService } = require('./sharepoint-service.cjs');
    const { ChatService } = require('./chat-service.cjs');
    const directory = new SharePointService(this);
    const person = await directory.person(email(recipient));
    const conversationId = '19:' + [this.credentials.self.split(':').pop(), person.objectId].sort().join('_') + '@unq.gbl.spaces';
    const binding = { recipient: person.email, memberId: '8:orgid:' + person.objectId,
      conversationId, expectedName: person.name };
    await new ChatService(this).verify(binding);
    return binding;
  }
  async resolveGroup(threadId, expectedName) {
    const { ChatService, groupName, groupThreadId } = require('./chat-service.cjs');
    const conversationId = groupThreadId(threadId), name = groupName(expectedName);
    const binding = { kind: 'group', recipient: name + ' [' + conversationId + ']', conversationId, expectedName: name };
    const proof = await new ChatService(this).verify(binding);
    // Every later check (before the POST, after delivery) must see exactly this membership.
    binding.members = proof.memberIds;
    return binding;
  }
  async decode(messages) {
    const output = execFileSync('python3', ['-I', path.join(__dirname, 'html-text.py')], {
      input: JSON.stringify(messages.map(message => String(message.content || ''))), encoding: 'utf8', maxBuffer: 20 * 1024 * 1024,
    });
    return JSON.parse(output);
  }
  async close() { this.credentials = null; this.resources = []; this.outlook = null; await this.context?.close().catch(() => {}); }

}

module.exports = { ChatSession, email, fail, memberFromToken, outlookToken, trusted };
