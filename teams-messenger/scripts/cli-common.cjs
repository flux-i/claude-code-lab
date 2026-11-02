'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const APP_DIR = process.env.TEAMS_WEB_APP_DIR || path.join(os.homedir(), 'Library', 'Application Support', 'Codex Teams Messenger');
const PROFILE_DIR = process.env.TEAMS_WEB_PROFILE_DIR || path.join(APP_DIR, 'browser-profile');
const RECEIPTS_PATH = process.env.TEAMS_WEB_RECEIPTS || path.join(APP_DIR, 'receipts.json');
function failure(code, message) { return Object.assign(new Error(message), { code }); }
function normalized(value) { return String(value || '').replace(/\r\n/g, '\n').replace(/\u00a0/g, ' ').trim(); }
function validateEmail(value) {
  const email = String(value || '').trim().toLowerCase();
  if (!/^[^\s@,]+@[^\s@,]+\.[^\s@,]+$/.test(email) || /["\\\[\]\x00-\x1f]/.test(email)) {
    throw failure('invalid_recipient', 'Use one complete email address; names, groups, and guessed addresses are refused.');
  }
  return email;
}
function ensurePrivateDirectory(directory) { fs.mkdirSync(directory, { recursive: true, mode: 0o700 }); fs.chmodSync(directory, 0o700); }
function loadReceipts() {
  try {
    const value = JSON.parse(fs.readFileSync(RECEIPTS_PATH, 'utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value;
  } catch (error) {
    if (error.code === 'ENOENT') return {};
    throw failure('receipt_store_invalid', 'The send receipt store is unreadable.');
  }
}
function saveReceipts(receipts) {
  ensurePrivateDirectory(path.dirname(RECEIPTS_PATH));
  const temporary = RECEIPTS_PATH + '.' + process.pid + '.tmp';
  fs.writeFileSync(temporary, JSON.stringify(receipts, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(temporary, RECEIPTS_PATH); fs.chmodSync(RECEIPTS_PATH, 0o600);
}
function receiptKey(recipient, message) { return crypto.createHash('sha256').update(recipient + '\0' + message).digest('hex'); }
function fileReceiptKey(recipient, name, hash, caption = '') {
  // Preserve browser-era keys for uncaptioned attachments.
  return crypto.createHash('sha256').update('file\0' + recipient + '\0' + name + '\0' + hash
    + (caption ? '\0caption\0' + caption : '')).digest('hex');
}
// Group keys carry their own prefix, so a group send can never match a 1:1 receipt.
function groupReceiptKey(conversationId, message) {
  return crypto.createHash('sha256').update('group\0' + conversationId + '\0' + message).digest('hex');
}
function groupFileReceiptKey(conversationId, name, hash, caption = '') {
  return crypto.createHash('sha256').update('groupfile\0' + conversationId + '\0' + name + '\0' + hash + '\0caption\0' + caption).digest('hex');
}
module.exports = { APP_DIR, PROFILE_DIR, RECEIPTS_PATH, ensurePrivateDirectory, failure, fileReceiptKey, groupFileReceiptKey,
  groupReceiptKey, loadReceipts, normalized, receiptKey, saveReceipts, validateEmail };
