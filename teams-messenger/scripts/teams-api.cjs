#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const web = require('./cli-common.cjs');
const { ChatSession, email, fail } = require('./chat-session.cjs');
const { ChatService, contentHtml, groupName, groupThreadId } = require('./chat-service.cjs');
const { SharePointService } = require('./sharepoint-service.cjs');
const calendar = require('./calendar-service.cjs');
const TRANSPORT = 'teams-chat-service';
const emit = value => process.stdout.write(JSON.stringify(value, null, 2) + '\n');

function priorReceipt(key, binding, sender, force) {
  const prior = web.loadReceipts()[key];
  if (!prior || force) return null;
  // A group is identified by its thread ID; a person by their immutable member ID.
  const target = binding.kind === 'group' ? prior.recipientProof?.conversationId : prior.recipientProof?.memberId;
  const expected = binding.kind === 'group' ? binding.conversationId : binding.memberId;
  if (prior.status === 'verified' && target === expected && prior.senderId === sender) {
    return { verified: true, duplicatePrevented: true, recipient: binding.recipient,
      transport: prior.transport || TRANSPORT, receipt: prior };
  }
  throw fail('prior_attempt_ambiguous', 'This exact recipient and content already has an unverified attempt. Reconcile it before explicitly authorizing --force.');
}
function saveReceipt(key, receipt) {
  const receipts = web.loadReceipts(); receipts[key] = receipt; web.saveReceipts(receipts);
}
async function localFile(value) {
  if (typeof value !== 'string' || !path.isAbsolute(value)) throw fail('invalid_file_path', 'Use one absolute local file path.');
  let resolved, stat;
  try { resolved = fs.realpathSync(value); stat = fs.statSync(resolved); fs.accessSync(resolved, fs.constants.R_OK); }
  catch (_) { throw fail('file_unreadable', 'The selected file is not readable.'); }
  if (!stat.isFile() || stat.size < 1) throw fail('invalid_file', 'Select a non-empty regular file.');
  const hash = crypto.createHash('sha256');
  for await (const bytes of fs.createReadStream(resolved)) hash.update(bytes);
  return { resolved, fileName: path.basename(resolved), size: stat.size, contentSha256: hash.digest('hex') };
}
function attachmentPayload(uploaded) {
  const { drive, item } = uploaded;
  const uniqueId = item.sharepointIds?.listItemUniqueId;
  if (!/^[a-f\d-]{36}$/i.test(uniqueId || '')) throw fail('file_identity_unavailable', 'OneDrive did not expose a stable SharePoint file identity.');
  const type = path.extname(item.name).slice(1).toLowerCase();
  const fileUrl = uploaded.fileUrl || item.webUrl;
  const url = new URL(fileUrl);
  if (url.origin !== drive.origin || url.search || url.hash) throw fail('file_url_not_verified', 'The uploaded file URL is not a plain authenticated OneDrive URL.');
  return { '@type': 'http://schema.skype.com/File', version: 2, itemid: uniqueId, id: uniqueId,
    fileName: item.name, fileType: type, fileSize: item.size, type, title: item.name, state: 'active',
    fileInfo: { itemId: item.id, fileUrl, siteUrl: drive.siteUrl, serverRelativeUrl: decodeURIComponent(url.pathname),
      shareUrl: fileUrl, shareId: 'u!' + Buffer.from(fileUrl).toString('base64url') },
    fileChicletState: { serviceName: 'p2p', state: 'active' }, baseUrl: drive.siteUrl,
    objectUrl: fileUrl, openUrl: null, permissionScope: 'SpecificPeople',
    sharepointIds: { ...item.sharepointIds, driveId: drive.id } };
}
async function postVerified(session, binding, body, key, receipt, expected = {}) {
  const service = new ChatService(session);
  const recipientProof = await service.verify(binding);
  const { messages: before } = await service.page(binding);
  const beforeIds = new Set(before.map(message => String(message.id)));
  const record = { ...receipt, recipient: binding.recipient, senderId: session.credentials.self,
    recipientProof, status: 'attempted', clientMessageId: body.clientmessageid,
    attemptedAt: new Date().toISOString(), transport: TRANSPORT };
  saveReceipt(key, record);
  try {
    const response = await service.post(binding, body); // Exactly one message POST; never auto-retried.
    const delivered = await service.waitForDelivery(binding, { beforeIds, clientId: body.clientmessageid,
      self: session.credentials.self, content: body.content, ...expected });
    const proof = { ...(binding.kind === 'group' ? { exactGroupVerified: true, membershipUnchanged: true } : { exactEmailVerified: true }),
      serverMembersVerified: true, singlePost: true,
      freshHistoryMatch: true, messageId: String(delivered.id), clientMessageId: body.clientmessageid,
      recipientProof, postStatus: response.status, ...receipt.proof };
    saveReceipt(key, { ...record, status: 'verified', proof, messageId: String(delivered.id), verifiedAt: new Date().toISOString() });
    return { verified: true, duplicatePrevented: false, recipient: binding.recipient, transport: TRANSPORT,
      ...(receipt.kind === 'file' ? { attachment: { fileName: receipt.fileName, size: receipt.size } } : {}), proof };
  } catch (error) {
    saveReceipt(key, { ...record, status: 'ambiguous', errorCode: error.code || 'send_result_ambiguous' });
    throw fail('send_result_ambiguous', 'A message send was attempted but could not be independently verified. No automatic retry was made.');
  }
}
async function sendText(session, recipient, message, { force = false } = {}) {
  if (typeof message !== 'string' || !message.trim()) throw fail('empty_message', 'Message text cannot be empty.');
  const binding = await session.resolve(email(recipient));
  const key = web.receiptKey(binding.recipient, message);
  const duplicate = priorReceipt(key, binding, session.credentials.self, force);
  if (duplicate) return duplicate;
  return postVerified(session, binding, { content: contentHtml(message), messagetype: 'RichText/Html',
    contenttype: 'text', clientmessageid: String(Date.now()) }, key,
    { kind: 'text', contentSha256: crypto.createHash('sha256').update(message).digest('hex') });
}
async function sendFile(session, recipient, filePath, { force = false, message = '' } = {}) {
  const file = await localFile(filePath);
  const binding = await session.resolve(email(recipient));
  const key = web.fileReceiptKey(binding.recipient, file.fileName, file.contentSha256, message);
  const duplicate = priorReceipt(key, binding, session.credentials.self, force);
  if (duplicate) return duplicate;
  const sharepoint = new SharePointService(session);
  const uploaded = await sharepoint.upload(file, crypto.randomUUID());
  const permission = await sharepoint.share(uploaded, binding);
  const attachment = attachmentPayload(uploaded);
  const body = { content: contentHtml(message), messagetype: 'RichText/Html', contenttype: 'text',
    clientmessageid: String(Date.now()), properties: { files: JSON.stringify([attachment]) } };
  return postVerified(session, binding, body, key,
    { kind: 'file', fileName: file.fileName, size: file.size, contentSha256: file.contentSha256,
      captionSha256: crypto.createHash('sha256').update(message).digest('hex'),
      cloudItemId: uploaded.item.id, proof: { uploadedBytesVerified: true, recipientAccessVerified: permission.recipientAccessVerified } },
    { fileName: file.fileName, fileItemId: uploaded.item.id });
}
async function sendGroupText(session, threadId, expectedName, message, { force = false } = {}) {
  if (typeof message !== 'string' || !message.trim()) throw fail('empty_message', 'Message text cannot be empty.');
  const binding = await session.resolveGroup(threadId, expectedName);
  const key = web.groupReceiptKey(binding.conversationId, message);
  const duplicate = priorReceipt(key, binding, session.credentials.self, force);
  if (duplicate) return duplicate;
  return postVerified(session, binding, { content: contentHtml(message), messagetype: 'RichText/Html',
    contenttype: 'text', clientmessageid: String(Date.now()) }, key,
    { kind: 'text', contentSha256: crypto.createHash('sha256').update(message).digest('hex') });
}
async function sendGroupFile(session, threadId, expectedName, filePath, { force = false, message = '' } = {}) {
  const file = await localFile(filePath);
  const binding = await session.resolveGroup(threadId, expectedName);
  const key = web.groupFileReceiptKey(binding.conversationId, file.fileName, file.contentSha256, message);
  const duplicate = priorReceipt(key, binding, session.credentials.self, force);
  if (duplicate) return duplicate;
  const sharepoint = new SharePointService(session);
  const uploaded = await sharepoint.upload(file, crypto.randomUUID());
  const permission = await sharepoint.shareWithGroup(uploaded, binding);
  const attachment = attachmentPayload(uploaded);
  const body = { content: contentHtml(message), messagetype: 'RichText/Html', contenttype: 'text',
    clientmessageid: String(Date.now()), properties: { files: JSON.stringify([attachment]) } };
  return postVerified(session, binding, body, key,
    { kind: 'file', fileName: file.fileName, size: file.size, contentSha256: file.contentSha256,
      captionSha256: crypto.createHash('sha256').update(message).digest('hex'), cloudItemId: uploaded.item.id,
      proof: { uploadedBytesVerified: true, recipientAccessVerified: permission.recipientAccessVerified, grantedTo: permission.grantedTo } },
    { fileName: file.fileName, fileItemId: uploaded.item.id });
}
// Resolves every attendee to an exact directory identity in the organizer's own organization. Read-only.
async function meetingPlan(session, subjectValue, options, now = Date.now()) {
  const subject = calendar.meetingSubject(subjectValue);
  const times = calendar.meetingTimes({ start: options['--start'], duration: options['--duration'] ?? 30,
    zone: options['--timezone'] ?? calendar.DEFAULT_TIME_ZONE, now });
  const emails = calendar.attendeeList(options['--attendees']);
  const organizer = await new calendar.CalendarService(session).organizer();
  const domain = organizer.email.split('@')[1];
  if (emails.includes(organizer.email)) throw fail('invalid_attendees', 'The organizer is added automatically; remove your own address.');
  const external = emails.filter(address => address.split('@')[1] !== domain);
  if (external.length) throw fail('external_attendee_refused', 'Only people in your organization can be invited: ' + external.join(', '));
  const directory = new SharePointService(session);
  const attendees = [];
  for (const address of emails) attendees.push(await directory.person(email(address)));
  return { organizer, subject, times, attendees, message: options['--message'] || '' };
}
function meetingSummary(plan) {
  return { organizer: plan.organizer.email, subject: plan.subject, start: plan.times.start, end: plan.times.end,
    timeZone: plan.times.timeZone, durationMinutes: plan.times.durationMinutes, startUtc: plan.times.startUtc,
    attendees: plan.attendees.map(person => ({ name: person.name, email: person.email })),
    teamsMeeting: true, description: plan.message };
}
function meetingKey(plan) {
  return crypto.createHash('sha256').update('meeting\0' + JSON.stringify([plan.organizer.email, plan.subject, plan.times.start,
    plan.times.end, plan.times.timeZone, plan.attendees.map(person => person.email).sort(), plan.message])).digest('hex');
}
// Creates the event with exactly one POST. Outlook then adds the Teams link and sends the invites itself.
async function createMeeting(session, subject, options, { force = false, now = Date.now(), service } = {}) {
  const plan = await meetingPlan(session, subject, options, now);
  const outlook = service || new calendar.CalendarService(session);
  const key = meetingKey(plan), prior = web.loadReceipts()[key];
  if (prior && !force) {
    if (prior.status === 'verified') return { verified: true, duplicatePrevented: true, ...meetingSummary(plan),
      teamsJoinUrl: prior.teamsJoinUrl, eventId: prior.eventId, receipt: { verifiedAt: prior.verifiedAt } };
    throw fail('prior_attempt_ambiguous', 'This exact meeting already has an unverified attempt. Check the calendar before explicitly authorizing --force.');
  }
  // A forced retry reuses the earlier transaction ID, so Outlook itself refuses to create a second copy.
  const transactionId = prior?.transactionId || calendar.transactionId();
  const record = { kind: 'meeting', status: 'attempted', organizer: plan.organizer.email, subject: plan.subject,
    start: plan.times.start, end: plan.times.end, timeZone: plan.times.timeZone,
    attendees: plan.attendees.map(person => ({ email: person.email, objectId: person.objectId })),
    transactionId, attemptedAt: new Date().toISOString(), transport: 'outlook-rest' };
  saveReceipt(key, record);
  let created;
  try { created = await outlook.create(calendar.meetingPayload(plan, transactionId)); }
  catch (error) {
    // A clean 4xx means Outlook refused the request and stored nothing.
    if (error.status >= 400 && error.status < 500 && error.status !== 408 && error.status !== 409) {
      saveReceipt(key, { ...record, status: 'rejected', errorCode: error.code, httpStatus: error.status });
      throw fail('meeting_rejected', `Outlook refused the meeting (HTTP ${error.status}). Nothing was created.`);
    }
    saveReceipt(key, { ...record, status: 'ambiguous', errorCode: error.code || 'meeting_result_ambiguous' });
    throw fail('send_result_ambiguous', 'The meeting create was attempted but its result is unknown. No automatic retry was made.');
  }
  try {
    const { event, proof } = await outlook.settled(created.Id, plan);
    const verified = Object.entries(proof).every(([name, value]) => name === 'invitesSent' ? value !== false || !plan.attendees.length : value === true);
    const result = { ...record, status: verified ? 'verified' : 'ambiguous', eventId: created.Id, teamsJoinUrl: calendar.joinUrl(event),
      proof, ...(verified ? { verifiedAt: new Date().toISOString() } : {}) };
    saveReceipt(key, result);
    return { verified, duplicatePrevented: false, ...meetingSummary(plan), teamsJoinUrl: result.teamsJoinUrl,
      eventId: created.Id, webLink: event.WebLink || '', transport: 'outlook-rest',
      proof: { singlePost: true, eventReadBack: true, ...proof } };
  } catch (_) {
    saveReceipt(key, { ...record, status: 'ambiguous', eventId: created.Id, errorCode: 'readback_failed' });
    throw fail('send_result_ambiguous', 'The meeting was created but could not be read back to confirm it. No automatic retry was made.');
  }
}
// Picks the newest file the other person sent. Several files in one message need an explicit --file.
function latestAttachment(messages, fileName) {
  for (const message of [...messages].reverse()) {
    if (message.fromMe) continue;
    const files = (message.attachments || []).filter(file => !fileName || file.fileName === fileName);
    if (files.length === 1) return { message, attachment: files[0] };
    if (files.length > 1) throw fail('attachment_choice_required', 'That message has several files. Choose one with --file: ' + files.map(file => file.fileName).join(', '));
  }
  throw fail('attachment_not_found', fileName ? 'No file with that exact name was found from this person.' : 'No file from this person was found in recent history.');
}
function downloadDirectory(value) {
  let resolved;
  if (typeof value !== 'string' || !path.isAbsolute(value)) throw fail('invalid_download_folder', 'Use one absolute folder path.');
  try { resolved = fs.realpathSync(value); fs.accessSync(resolved, fs.constants.W_OK); }
  catch (_) { throw fail('invalid_download_folder', 'The download folder is not writable.'); }
  if (!fs.statSync(resolved).isDirectory()) throw fail('invalid_download_folder', 'The download path is not a folder.');
  return resolved;
}
async function downloadFile(session, recipient, directory, { fileName } = {}) {
  const binding = await session.resolve(email(recipient));
  const service = new ChatService(session);
  const recipientProof = await service.verify(binding);
  const { messages } = await service.history(binding, { limit: 500, scan: 5000 });
  const { message, attachment } = latestAttachment(messages, fileName);
  const file = await new SharePointService(session).downloadAttachment(attachment, directory);
  return { verified: true, recipient: binding.recipient, recipientProof, transport: TRANSPORT,
    sentAt: message.timestamp, sentBy: message.author, file };
}
function contacts(query = '') {
  return fs.readFileSync(path.join(__dirname, 'teams_contacts.txt'), 'utf8').split(/\r?\n/)
    .filter(line => line.trim() && !line.trim().startsWith('#') && line.includes('='))
    .map(line => { const [name, address] = line.split('=', 2).map(value => value.trim()); return { name, email: email(address) }; })
    .filter(contact => [contact.name, contact.email].some(value => value.toLowerCase().includes(query.toLowerCase())));
}
function integer(value, low, high, label) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < low || n > high) throw fail('invalid_arguments', `${label} must be an integer between ${low} and ${high}.`);
  return n;
}
function dateBound(value, end) {
  if (!/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:\d{2}))?$/.test(value)) {
    throw fail('invalid_arguments', 'Use an ISO date or timestamp for date filters.');
  }
  const normalized = value.length === 10 ? value + (end ? 'T23:59:59.999Z' : 'T00:00:00.000Z') : value;
  const timestamp = Date.parse(normalized);
  const calendarDate = value.slice(0, 10);
  const calendarTime = Date.parse(calendarDate + 'T00:00:00.000Z');
  if (!Number.isFinite(timestamp) || !Number.isFinite(calendarTime)
      || new Date(calendarTime).toISOString().slice(0, 10) !== calendarDate) {
    throw fail('invalid_arguments', 'The date filter is invalid.');
  }
  return timestamp;
}
function argumentsFor(argv) {
  const [command, ...input] = argv, args = [], options = {};
  for (let i = 0; i < input.length; i++) {
    const token = input[i];
    if (['--force', '--case-sensitive'].includes(token)) {
      if (options[token]) throw fail('invalid_arguments', 'A flag was repeated.');
      options[token] = true;
    } else if (['--limit', '--max-scan', '--after', '--before', '--message', '--start', '--duration', '--timezone', '--attendees', '--file'].includes(token)) {
      if (options[token] !== undefined || input[i + 1] === undefined) throw fail('invalid_arguments', 'A flag value was missing or repeated.');
      options[token] = input[++i];
    } else if (token.startsWith('--')) throw fail('invalid_arguments', 'Unknown option: ' + token);
    else args.push(token);
  }
  const allowed = { send: ['--force'], 'send-file': ['--force', '--message'], 'group-send': ['--force'],
    'group-send-file': ['--force', '--message'], 'group-info': [],
    list: ['--limit'], read: ['--limit'], download: ['--file'],
    'meeting-preview': ['--start', '--duration', '--timezone', '--attendees', '--message'],
    meeting: ['--start', '--duration', '--timezone', '--attendees', '--message', '--force'], search: ['--limit', '--max-scan', '--after', '--before', '--case-sensitive'] };
  if (Object.keys(options).some(option => !(allowed[command] || []).includes(option))) throw fail('invalid_arguments', 'This command does not accept that option.');
  return { command, args, options };
}
const usage = `Usage:
  teams auth
  teams status
  teams contacts [name-or-email]
  teams lookup <name-or-email>
  teams list [--limit N]
  teams send <exact-email> <message> [--force]
  teams send-file <exact-email> <absolute-path> [--message <caption>] [--force]
  teams read <exact-email> [--limit 20]
  teams search <exact-email> <text> [--limit 20] [--max-scan 5000] [--after ISO] [--before ISO] [--case-sensitive]
  teams download <exact-email> <absolute-folder> [--file <exact-file-name>]
  teams group-info <group-chat-id> <exact-group-name>
  teams group-send <group-chat-id> <exact-group-name> <message> [--force]
  teams group-send-file <group-chat-id> <exact-group-name> <absolute-path> [--message <caption>] [--force]
  teams meeting-preview <title> --start YYYY-MM-DDTHH:MM [--duration 30] [--timezone "India Standard Time"]
        [--attendees a@org.com,b@org.com] [--message <description>]
  teams meeting <title> --start YYYY-MM-DDTHH:MM [same options as meeting-preview] [--force]

The browser is used only for token acquisition. All operational commands use APIs.
Existing 1:1 chats and existing group chats with internal members only. Group commands need the
exact group chat ID from \`teams list\` plus its exact name. Channels, meeting chats and implicit
message retries are unsupported.`;

async function main(argv) {
  if (!argv.length || ['--help', '-h', 'help'].includes(argv[0])) { process.stdout.write(usage + '\n'); return; }
  const { command, args, options } = argumentsFor(argv);
  if (command === 'auth') {
    if (args.length) throw fail('invalid_arguments', usage);
    // Interactive sign-in is the sole visible browser action, explicitly requested by this command.
    emit(await require('./token-browser.cjs').auth()); return;
  }
  if (command === 'contacts') {
    if (args.length > 1) throw fail('invalid_arguments', usage);
    emit({ readOnly: true, contacts: contacts(args[0]) }); return;
  }
  const counts = { status: 0, lookup: 1, list: 0, send: 2, 'send-file': 2, read: 1, search: 2, download: 2,
    'group-info': 2, 'group-send': 3, 'group-send-file': 3, 'meeting-preview': 1, meeting: 1 };
  if (counts[command] === undefined || args.length !== counts[command]) throw fail('invalid_arguments', usage);
  if (['send', 'send-file', 'read', 'search', 'download'].includes(command)) email(args[0]);
  if (command === 'download') downloadDirectory(args[1]);
  if (command.startsWith('group-')) { groupThreadId(args[0]); groupName(args[1]); }
  if (command === 'group-send' && !args[2].trim()) throw fail('empty_message', 'Message text cannot be empty.');
  if (command === 'group-send-file') await localFile(args[2]);
  const limit = integer(options['--limit'] ?? 20, 1, 500, '--limit');
  const scan = integer(options['--max-scan'] ?? 5000, 1, 100000, '--max-scan');
  if (command === 'search' && !args[1].trim()) throw fail('invalid_arguments', 'Search text cannot be empty.');
  if (command === 'send' && !args[1].trim()) throw fail('empty_message', 'Message text cannot be empty.');
  if (command === 'send-file') await localFile(args[1]);
  const after = options['--after'] ? dateBound(options['--after'], false) : undefined;
  const before = options['--before'] ? dateBound(options['--before'], true) : undefined;
  if (after && before && after > before) throw fail('invalid_arguments', '--after must be earlier than --before.');
  const isMeeting = command === 'meeting' || command === 'meeting-preview';
  if (isMeeting) {
    // Validate everything that needs no network before opening the token browser.
    calendar.meetingSubject(args[0]); calendar.attendeeList(options['--attendees']);
    calendar.meetingTimes({ start: options['--start'], duration: options['--duration'] ?? 30, zone: options['--timezone'] ?? calendar.DEFAULT_TIME_ZONE });
  }
  const session = new ChatSession({ outlook: isMeeting });
  try {
    await session.start();
    const service = new ChatService(session);
    if (command === 'status') {
      await service.request(session.credentials.base + '?pageSize=1');
      emit({ authenticated: true, transport: TRANSPORT, browserUsage: 'token-acquisition-only', browserClosedBeforeOperation: !session.context,
        resourcesAvailable: session.resources.length });
    } else if (command === 'lookup') {
      const directory = new SharePointService(session);
      const matches = args[0].includes('@') ? [await directory.person(email(args[0]))] : await directory.lookupName(args[0]);
      emit({ readOnly: true, matches, transport: TRANSPORT });
    } else if (command === 'meeting-preview') {
      emit({ readOnly: true, preview: meetingSummary(await meetingPlan(session, args[0], options)) });
    } else if (command === 'meeting') {
      emit(await createMeeting(session, args[0], options, { force: Boolean(options['--force']) }));
    } else if (command === 'send') emit(await sendText(session, args[0], args[1], { force: Boolean(options['--force']) }));
    else if (command === 'send-file') emit(await sendFile(session, args[0], args[1], {
      force: Boolean(options['--force']), message: options['--message'] || '' }));
    else if (command === 'group-info') {
      const binding = await session.resolveGroup(args[0], args[1]);
      emit({ readOnly: true, transport: TRANSPORT, group: binding.expectedName, conversationId: binding.conversationId,
        memberCount: binding.members.length, memberIds: binding.members });
    } else if (command === 'group-send') emit(await sendGroupText(session, args[0], args[1], args[2], { force: Boolean(options['--force']) }));
    else if (command === 'group-send-file') emit(await sendGroupFile(session, args[0], args[1], args[2], {
      force: Boolean(options['--force']), message: options['--message'] || '' }));
    else if (command === 'download') emit(await downloadFile(session, args[0], downloadDirectory(args[1]), { fileName: options['--file'] }));
    else if (command === 'list') {
      const { value } = await service.request(session.credentials.base + '?pageSize=100');
      if (!Array.isArray(value.conversations)) throw fail('conversation_list_invalid', 'Teams did not return a conversation list.');
      emit({ readOnly: true, transport: TRANSPORT, conversations: value.conversations.slice(0, limit).map(item => ({ id: item.id, type: item.type || '',
        name: item.threadProperties?.topic || item.properties?.topic || '' })) });
    } else {
      const binding = await session.resolve(args[0]);
      const result = await service.history(binding, { limit, scan: command === 'read' ? limit + 100 : scan,
        ...(command === 'search' ? { query: args[1], after, before, caseSensitive: Boolean(options['--case-sensitive']) } : {}) });
      emit({ readOnly: true, recipient: binding.recipient, recipientProof: await service.verify(binding),
        transport: TRANSPORT, ...(command === 'search' ? { query: args[1] } : {}), messageCount: result.messages.length, ...result });
    }
  } finally { await session.close(); }
}

if (require.main === module) main(process.argv.slice(2)).catch(error => {
  emit({ verified: false, error: error.code || 'unexpected_error', message: error.code ? error.message : 'The Teams operation failed unexpectedly.' });
  process.exitCode = error.code === 'send_result_ambiguous' ? 3 : 1;
});

module.exports = { argumentsFor, attachmentPayload, contacts, downloadDirectory, downloadFile, latestAttachment, createMeeting, meetingKey, meetingPlan, meetingSummary, dateBound, integer, localFile, main, postVerified, sendFile,
  sendGroupFile, sendGroupText, sendText };
