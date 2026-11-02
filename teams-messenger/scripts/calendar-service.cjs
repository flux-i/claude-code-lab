'use strict';

const crypto = require('node:crypto');
const { fail } = require('./chat-session.cjs');
const { contentHtml } = require('./chat-service.cjs');
const API = 'https://outlook.office.com/api/v2.0/me';
// Windows time zone IDs (what Outlook stores) mapped to IANA zones (what Node can compute with).
const TIME_ZONES = {
  'India Standard Time': 'Asia/Kolkata', UTC: 'UTC', 'GMT Standard Time': 'Europe/London',
  'W. Europe Standard Time': 'Europe/Berlin', 'Arabian Standard Time': 'Asia/Dubai',
  'Singapore Standard Time': 'Asia/Singapore', 'Eastern Standard Time': 'America/New_York',
  'Central Standard Time': 'America/Chicago', 'Pacific Standard Time': 'America/Los_Angeles',
};
const DEFAULT_TIME_ZONE = 'India Standard Time';
const MAX_ATTENDEES = 50;
// PidLidFInvited: Outlook sets this once meeting requests have been sent to the attendees.
const INVITES_SENT = 'Boolean {00062002-0000-0000-C000-000000000046} Id 0x8229';

function timeZone(value = DEFAULT_TIME_ZONE) {
  if (!Object.hasOwn(TIME_ZONES, value)) {
    throw fail('invalid_time_zone', 'Use one of these time zones: ' + Object.keys(TIME_ZONES).join(', ') + '.');
  }
  return value;
}
function wallClock(instant, iana) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: iana, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' })
    .formatToParts(new Date(instant)).map(part => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}`;
}
// Converts a wall-clock time in a zone to an instant, refusing times a clock change skips or repeats.
function instantFor(local, iana) {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(String(local || ''));
  if (!match) throw fail('invalid_start', 'Use --start YYYY-MM-DDTHH:MM in the meeting time zone, for example 2026-11-03T15:00.');
  const [y, mo, d, h, mi] = match.slice(1).map(Number);
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  const target = local + ':00';
  const offsetAt = instant => Date.parse(wallClock(instant, iana) + 'Z') - Math.floor(instant / 1000) * 1000;
  // The zone's offset a day either side covers both sides of any clock change.
  const unique = [...new Set([guess - 86400000, guess + 86400000].map(probe => guess - offsetAt(probe)))]
    .filter(instant => wallClock(instant, iana) === target);
  if (unique.length !== 1) throw fail('invalid_start', 'That start time does not exist or is ambiguous in the meeting time zone.');
  return unique[0];
}
function meetingTimes({ start, duration = 30, zone = DEFAULT_TIME_ZONE, now = Date.now() }) {
  const tz = timeZone(zone), iana = TIME_ZONES[tz];
  const minutes = Number(duration);
  if (!Number.isInteger(minutes) || minutes < 5 || minutes > 480) throw fail('invalid_duration', '--duration must be whole minutes between 5 and 480.');
  const begins = instantFor(start, iana);
  if (begins < now - 60000) throw fail('start_in_past', 'The meeting start time is in the past.');
  if (begins > now + 366 * 86400000) throw fail('invalid_start', 'The meeting start time is more than a year away.');
  const ends = begins + minutes * 60000;
  return { timeZone: tz, start: wallClock(begins, iana), end: wallClock(ends, iana), durationMinutes: minutes,
    startUtc: new Date(begins).toISOString(), endUtc: new Date(ends).toISOString() };
}
function attendeeList(value) {
  if (value === undefined) return [];
  const emails = String(value).split(',').map(item => item.trim().toLowerCase()).filter(Boolean);
  if (!emails.length) throw fail('invalid_attendees', 'Give attendees as comma-separated exact email addresses.');
  if (new Set(emails).size !== emails.length) throw fail('invalid_attendees', 'An attendee is listed twice.');
  if (emails.length > MAX_ATTENDEES) throw fail('invalid_attendees', `At most ${MAX_ATTENDEES} attendees are supported.`);
  return emails;
}
function meetingSubject(value) {
  const subject = String(value || '').replace(/\s+/g, ' ').trim();
  if (!subject) throw fail('invalid_subject', 'The meeting title cannot be empty.');
  if (subject.length > 255) throw fail('invalid_subject', 'The meeting title is longer than 255 characters.');
  return subject;
}
function meetingPayload(plan, transactionId) {
  return {
    Subject: plan.subject,
    Body: { ContentType: 'HTML', Content: plan.message ? contentHtml(plan.message) : '' },
    Start: { DateTime: plan.times.start, TimeZone: plan.times.timeZone },
    End: { DateTime: plan.times.end, TimeZone: plan.times.timeZone },
    Attendees: plan.attendees.map(person => ({ EmailAddress: { Address: person.email, Name: person.name }, Type: 'Required' })),
    IsOnlineMeeting: true, OnlineMeetingProvider: 'TeamsForBusiness', ResponseRequested: true,
    TransactionId: transactionId,
  };
}
const joinUrl = event => event.OnlineMeeting?.JoinUrl || event.OnlineMeetingUrl || '';
function teamsJoinUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname === 'teams.microsoft.com'
      && /^\/(l\/meetup-join|meet)\//.test(url.pathname) ? value : '';
  } catch (_) { return ''; }
}
// Compares what Outlook stored with what was requested. Returns proof, or null fields where it differs.
function eventProof(event, plan) {
  const addresses = (event.Attendees || []).map(item => String(item.EmailAddress?.Address || '').toLowerCase()).sort();
  const expected = plan.attendees.map(person => person.email).sort();
  const minute = value => String(value?.DateTime || '').slice(0, 16);
  const sentFlag = (event.SingleValueExtendedProperties || []).find(item => item.PropertyId?.toLowerCase() === INVITES_SENT.toLowerCase());
  return {
    subjectMatches: event.Subject === plan.subject,
    attendeesMatch: addresses.length === expected.length && addresses.every((address, i) => address === expected[i]),
    timesMatch: minute(event.Start) === plan.times.start.slice(0, 16) && minute(event.End) === plan.times.end.slice(0, 16),
    isOrganizer: event.IsOrganizer !== false,
    notCancelled: event.IsCancelled !== true,
    teamsLinkCreated: Boolean(event.IsOnlineMeeting && teamsJoinUrl(joinUrl(event))),
    invitesSent: plan.attendees.length ? (sentFlag ? String(sentFlag.Value).toLowerCase() === 'true' : null) : false,
  };
}

class CalendarService {
  constructor(session, fetchImpl = fetch, wait = ms => new Promise(resolve => setTimeout(resolve, ms))) {
    this.session = session; this.fetch = fetchImpl; this.wait = wait;
  }
  async request(path, { method = 'GET', json, zone } = {}) {
    const url = new URL(API + path);
    if (url.origin !== 'https://outlook.office.com' || !url.pathname.startsWith('/api/v2.0/me')) throw fail('outlook_scope_changed', 'Refused a request outside the signed-in calendar.');
    const credential = this.session.outlookCredential();
    let response;
    try {
      response = await this.fetch(url.href, { method, redirect: 'manual', signal: AbortSignal.timeout(30000),
        headers: { Authorization: 'Bearer ' + credential.secret, Accept: 'application/json',
          ...(zone ? { Prefer: `outlook.timezone="${zone}"` } : {}),
          ...(json !== undefined ? { 'Content-Type': 'application/json' } : {}) },
        ...(json !== undefined ? { body: JSON.stringify(json) } : {}) });
    } catch (_) { throw fail('outlook_request_failed', 'The Outlook calendar request did not return a response.'); }
    if (!response.ok) {
      await response.body?.cancel();
      throw Object.assign(fail('outlook_http_error', `Outlook returned HTTP ${response.status}.`), { status: response.status });
    }
    return response.status === 204 ? null : response.json();
  }
  async organizer() {
    const me = await this.request('');
    const address = String(me.EmailAddress || '').toLowerCase();
    if (!/^[^\s@,]+@[^\s@,]+\.[^\s@,]+$/.test(address)) throw fail('organizer_unavailable', 'Outlook did not return the signed-in mailbox address.');
    return { email: address, name: me.DisplayName || address };
  }
  async create(payload) { return this.request('/events', { method: 'POST', json: payload }); }
  async event(id, zone) {
    if (!/^[\w=+/-]+$/.test(String(id || ''))) throw fail('event_id_invalid', 'Outlook returned an unrecognized event ID.');
    const select = 'Subject,Start,End,Attendees,IsOnlineMeeting,OnlineMeeting,OnlineMeetingUrl,OnlineMeetingProvider,IsOrganizer,IsCancelled,WebLink';
    const expand = `SingleValueExtendedProperties($filter=PropertyId eq '${INVITES_SENT}')`;
    return this.request('/events/' + encodeURIComponent(id) + '?$select=' + select + '&$expand=' + encodeURIComponent(expand), { zone });
  }
  // Outlook adds the Teams link and sends invites just after the event is saved, so read back a few times.
  async settled(id, plan, { attempts = 8, delay = 2000 } = {}) {
    let event, proof;
    for (let i = 0; i < attempts; i++) {
      if (i) await this.wait(delay);
      event = await this.event(id, plan.times.timeZone);
      proof = eventProof(event, plan);
      if (proof.teamsLinkCreated && (proof.invitesSent === true || !plan.attendees.length)) break;
    }
    return { event, proof };
  }
  // Finds events in the meeting's time window with the same title, for reconciling an uncertain create.
  async matching(plan) {
    const query = new URLSearchParams({ startDateTime: plan.times.startUtc, endDateTime: plan.times.endUtc,
      $select: 'Subject,Start,End', $top: '50' });
    const result = await this.request('/calendarview?' + query, { zone: plan.times.timeZone });
    return (result.value || []).filter(event => event.Subject === plan.subject);
  }
}

module.exports = { CalendarService, DEFAULT_TIME_ZONE, INVITES_SENT, TIME_ZONES, attendeeList, eventProof, instantFor,
  joinUrl, meetingPayload, meetingSubject, meetingTimes, teamsJoinUrl, timeZone, transactionId: () => crypto.randomUUID() };
