'use strict';

const { fail, trusted } = require('./chat-session.cjs');
function properties(message) {
  let value = message.properties || {};
  if (typeof value === 'string') { try { value = JSON.parse(value); } catch (_) { value = {}; } }
  return value && typeof value === 'object' ? value : {};
}
function attachments(message) {
  let files = properties(message).files || [];
  if (typeof files === 'string') { try { files = JSON.parse(files); } catch (_) { files = []; } }
  if (!Array.isArray(files)) return [];
  return files.map(file => ({ fileName: file.fileName || file.name || '', fileType: file.fileType || '',
    size: file.fileSize ?? file.size ?? file.fileInfo?.fileSize ?? null,
    url: file.fileInfo?.objectUrl || file.objectUrl || file.url || '',
    itemId: file.fileInfo?.itemid || file.fileInfo?.itemId || file.itemid || file.id || '' }));
}
function fromMember(message, member) {
  return message.from === member || String(message.from || '').endsWith('/' + member);
}
function contentHtml(message) {
  return '<p>' + message.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/\r\n/g, '\n').replace(/\n/g, '<br>') + '</p>';
}
function normalizedHtml(value) {
  // Teams inserts serialization CRLF after authored <br> nodes.
  // Preserve the nodes and every other character, including intentional blank lines.
  return String(value).replace(/(<br\s*\/?>)\r?\n/gi, '$1');
}
function deliveryMatch(messages, { beforeIds, clientId, self, content, fileName, fileItemId }) {
  const matches = messages.filter(message => !beforeIds.has(String(message.id))
    && String(message.clientmessageid) === String(clientId) && fromMember(message, self)
    && (content === undefined || normalizedHtml(message.content) === normalizedHtml(content))
    && (!fileName || (attachments(message).length === 1 && attachments(message).some(file =>
      file.fileName === fileName && (!fileItemId || file.itemId === fileItemId)))));
  if (matches.length > 1) throw fail('delivery_match_ambiguous', 'More than one message matched this send attempt.');
  return matches[0] || null;
}
function verifyMembers(thread, target, self) {
  const members = Array.isArray(thread.members) ? thread.members.map(member => member.id || member.mri) : [];
  const expected = new Set([self, target]);
  const actual = new Set(members);
  if (members.length !== actual.size || actual.size !== expected.size || [...expected].some(id => !actual.has(id))) {
    throw fail('server_membership_not_verified', 'The server thread does not contain exactly the sender and intended recipient.');
  }
  return true;
}
// Group chats only: channels (@thread.tacv2 / @thread.skype), meeting chats (19:meeting_…) and 1:1 chats are refused.
const GROUP_THREAD = /^19:[0-9a-f]{32}@thread\.v2$/i;
const INTERNAL_MEMBER = /^8:orgid:[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i;
function groupThreadId(value) {
  const id = String(value || '').trim();
  if (!GROUP_THREAD.test(id)) {
    throw fail('invalid_group', 'Use the exact group chat ID (19:<32 hex>@thread.v2) from `teams list`; names, 1:1 chats, meetings and channels are refused.');
  }
  return id;
}
function groupName(value) {
  const name = String(value || '').replace(/\s+/g, ' ').trim();
  if (!name) throw fail('invalid_group', 'Give the exact group name as a second check on the group ID.');
  return name;
}
function verifyGroup(thread, binding, self) {
  const members = Array.isArray(thread.members) ? thread.members.map(member => member.id || member.mri) : [];
  const unique = new Set(members);
  if (!members.length || members.length !== unique.size) throw fail('group_membership_not_verified', 'Teams did not return a clean member list for this group.');
  if (!unique.has(self)) throw fail('group_membership_not_verified', 'The signed-in sender is not a member of this group chat.');
  if (members.some(id => !INTERNAL_MEMBER.test(String(id)))) {
    throw fail('group_member_not_internal', 'The group has a member that is not an organisation user (guest, external account or bot); sending is refused.');
  }
  if (thread.properties?.threadType !== 'chat') throw fail('not_a_group_chat', 'This thread is not a group chat; meetings and channels are refused.');
  if (groupName(thread.properties?.topic) !== binding.expectedName) {
    throw fail('group_name_not_verified', 'The group name on the server does not exactly match the expected name.');
  }
  const sorted = [...unique].sort();
  // A snapshot taken at resolve time: the membership must not change between the check, the send and its verification.
  if (binding.members && (binding.members.length !== sorted.length || binding.members.some((id, i) => id !== sorted[i]))) {
    throw fail('group_membership_changed', 'The group membership changed during the operation.');
  }
  return sorted;
}
function verifyUrl(url, base) {
  let u, b;
  try { u = new URL(url); b = new URL(base); } catch (_) { throw fail('untrusted_service_url', 'The service returned an invalid URL.'); }
  if (u.protocol !== 'https:' || !trusted(u.hostname) || u.origin !== b.origin || u.username || u.password
      || !decodeURIComponent(u.pathname).startsWith(decodeURIComponent(b.pathname) + '/')) {
    throw fail('untrusted_service_url', 'The service URL leaves the verified Teams service.');
  }
  return u;
}
function nextHistoryUrl(value, current, root) {
  const raw = value?._metadata?.backwardLink || value?.backwardLink || null;
  if (!raw) return null;
  const next = new URL(raw, current);
  const expected = new URL(root);
  verifyUrl(next.href, root.slice(0, root.lastIndexOf('/messages')));
  if (decodeURIComponent(next.pathname) !== decodeURIComponent(expected.pathname)) throw fail('history_scope_changed', 'History pagination points at another conversation.');
  return next.href;
}

class ChatService {
  constructor(session, fetchImpl = fetch) { this.session = session; this.fetch = fetchImpl; }
  get credentials() {
    const credentials = this.session.credentials;
    if (!credentials || this.session.captureError) throw fail('authentication_unavailable', 'No verified background credential is available.');
    return credentials;
  }
  async request(url, { method = 'GET', body, refresh = true } = {}) {
    const credentials = this.credentials;
    const prefix = credentials.base.replace(/\/users\/ME\/conversations$/i, '');
    verifyUrl(url, prefix);
    let response;
    try {
      response = await this.fetch(url, { method, headers: { ...credentials.headers, Accept: 'application/json',
        ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}), redirect: 'manual',
        cache: 'no-store', signal: AbortSignal.timeout(20000) });
    } catch (_) { throw fail(method === 'POST' ? 'send_result_ambiguous' : 'service_request_failed', 'The background request did not return a response.'); }
    if (response.status === 401 && method === 'GET' && refresh) {
      await response.body?.cancel();
      await this.session.refresh();
      if (this.credentials.self !== credentials.self || this.credentials.base !== credentials.base) {
        throw fail('authentication_changed', 'The sender or service changed during authentication refresh.');
      }
      return this.request(url, { method, body, refresh: false });
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw fail(method === 'POST' ? 'send_result_ambiguous' : 'service_http_error', `Teams returned HTTP ${response.status}.`);
    }
    let value;
    try { value = await response.json(); }
    catch (_) {
      if (method === 'POST' && [201, 202, 204].includes(response.status)) value = {};
      else throw fail('service_response_invalid', 'Teams returned a response that could not be decoded.');
    }
    return { status: response.status, value };
  }
  messagesUrl(binding) {
    return this.credentials.base + '/' + encodeURIComponent(binding.conversationId) + '/messages';
  }
  async verify(binding) {
    const prefix = this.credentials.base.replace(/\/users\/ME\/conversations$/i, '');
    const { value } = await this.request(prefix + '/threads/' + encodeURIComponent(binding.conversationId));
    if (binding.kind === 'group') {
      const memberIds = verifyGroup(value, binding, this.credentials.self);
      return { group: binding.expectedName, conversationId: binding.conversationId, senderId: this.credentials.self,
        memberIds, memberCount: memberIds.length, serverMembersVerified: true };
    }
    verifyMembers(value, binding.memberId, this.credentials.self);
    return { recipient: binding.recipient, memberId: binding.memberId, conversationId: binding.conversationId,
      senderId: this.credentials.self, serverMembersVerified: true };
  }
  async page(binding, url) {
    const root = this.messagesUrl(binding);
    url ||= root + '?pageSize=100&view=msnp24Equivalent';
    verifyUrl(url, this.credentials.base);
    if (decodeURIComponent(new URL(url).pathname) !== decodeURIComponent(new URL(root).pathname)) throw fail('history_scope_changed', 'History points at another conversation.');
    const { value } = await this.request(url);
    if (!Array.isArray(value.messages)) throw fail('history_response_invalid', 'Teams did not return a messages array.');
    return { messages: value.messages, next: nextHistoryUrl(value, url, root) };
  }
  async history(binding, { limit = 20, scan = 5000, query, after, before, caseSensitive = false } = {}) {
    const found = [], seen = new Set(), visited = new Set();
    let url, more = false, scanned = 0;
    while (scanned < scan && found.length < limit) {
      const page = await this.page(binding, url);
      page.messages.sort((a, b) => Number(b.id) - Number(a.id));
      const texts = await this.session.decode(page.messages);
      for (let i = 0; i < page.messages.length; i++) {
        const item = page.messages[i], id = String(item.id || '');
        if (!id || seen.has(id)) continue;
        seen.add(id); scanned++;
        const timestamp = item.originalarrivaltime || (/^\d{12,14}$/.test(id) ? new Date(Number(id)).toISOString() : null);
        const time = timestamp ? Date.parse(timestamp) : NaN;
        const files = attachments(item);
        const haystack = [texts[i], ...files.map(file => file.fileName)].join('\n');
        const match = query === undefined || (caseSensitive ? haystack.includes(query) : haystack.toLocaleLowerCase().includes(query.toLocaleLowerCase()));
        if (match && (!after || time >= after) && (!before || time <= before)) {
          found.push({ id, clientMessageId: String(item.clientmessageid || ''),
            author: item.imdisplayname || (fromMember(item, this.credentials.self) ? 'me' : binding.expectedName || binding.recipient),
            fromMe: fromMember(item, this.credentials.self), timestamp, text: texts[i], attachments: files });
        }
        if (found.length >= limit || scanned >= scan) { more = i < page.messages.length - 1 || Boolean(page.next); break; }
      }
      if (found.length >= limit || scanned >= scan || !page.next) break;
      if (visited.has(page.next)) throw fail('history_pagination_loop', 'Teams repeated a history pagination link.');
      visited.add(page.next); url = page.next;
    }
    found.sort((a, b) => (Date.parse(a.timestamp) || Number(a.id) || 0) - (Date.parse(b.timestamp) || Number(b.id) || 0));
    return { messages: found, scanned, olderHistoryAvailable: more, scanLimitReached: scanned >= scan && more };
  }
  async post(binding, body) { return this.request(this.messagesUrl(binding), { method: 'POST', body, refresh: false }); }
  async waitForDelivery(binding, expected) {
    for (let round = 0; round < 15; round++) {
      const { messages } = await this.page(binding);
      const match = deliveryMatch(messages, expected);
      if (match) { await this.verify(binding); return match; }
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    throw fail('send_result_ambiguous', 'The send was not independently verified in the intended conversation. Do not retry automatically.');
  }
}

module.exports = { ChatService, attachments, contentHtml, deliveryMatch, fromMember, groupName, groupThreadId, nextHistoryUrl,
  normalizedHtml, verifyGroup, verifyMembers, verifyUrl };
