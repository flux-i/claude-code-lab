'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { fail } = require('./chat-session.cjs');
function sharepointUrl(value, origin) {
  let u;
  try { u = new URL(value); } catch (_) { throw fail('sharepoint_url_invalid', 'SharePoint returned an invalid URL.'); }
  if (u.protocol !== 'https:' || !u.hostname.endsWith('.sharepoint.com') || u.origin !== origin
      || u.username || u.password) throw fail('sharepoint_scope_changed', 'SharePoint redirected outside the verified resource.');
  return u;
}
function personIdentity(profile, recipient) {
  const fields = Object.fromEntries((profile.UserProfileProperties || []).map(field => [field.Key, field.Value]));
  const mail = String(profile.Email || '').trim().toLowerCase();
  const objectId = fields['msOnline-ObjectId'];
  if (mail !== recipient || !/^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i.test(objectId || '')) {
    throw fail('directory_identity_not_verified', 'The directory did not confirm the exact email and immutable Microsoft user ID.');
  }
  return { email: mail, name: profile.DisplayName || mail, objectId: objectId.toLowerCase() };
}

class SharePointService {
  constructor(session, fetchImpl = fetch) { this.session = session; this.fetch = fetchImpl; }
  rootOrigin() {
    const origins = [...new Set(this.session.resources.map(token => token.origin).filter(origin => !new URL(origin).hostname.includes('-my.')))];
    if (origins.length !== 1) throw fail('directory_resource_ambiguous', 'No unique company SharePoint directory resource is available.');
    return origins[0];
  }
  personalOrigin() {
    const origins = [...new Set(this.session.resources.map(token => token.origin).filter(origin => new URL(origin).hostname.includes('-my.')))];
    if (origins.length !== 1) throw fail('onedrive_resource_ambiguous', 'No unique personal OneDrive resource is available.');
    return origins[0];
  }
  async request(url, { method = 'GET', json, body, headers = {}, refresh = true } = {}) {
    const origin = new URL(url).origin;
    sharepointUrl(url, origin);
    const token = this.session.resource(origin);
    let response;
    try {
      response = await this.fetch(url, { method, headers: { Authorization: 'Bearer ' + token.secret,
        Accept: 'application/json;odata=nometadata', ...(json !== undefined ? { 'Content-Type': 'application/json' } : {}), ...headers },
        ...(json !== undefined ? { body: JSON.stringify(json) } : body !== undefined ? { body } : {}),
        redirect: 'manual', signal: AbortSignal.timeout(30000) });
    } catch (_) { throw fail('sharepoint_request_failed', 'The SharePoint request did not return a response.'); }
    if (response.status === 401 && method === 'GET' && refresh) {
      await response.body?.cancel(); await this.session.refresh();
      return this.request(url, { method, json, body, headers, refresh: false });
    }
    if (!response.ok) {
      await response.body?.cancel(); throw Object.assign(fail('sharepoint_http_error', `SharePoint returned HTTP ${response.status}.`), { status: response.status });
    }
    return response;
  }
  async json(url, options) { return (await this.request(url, options)).json(); }
  async person(recipient) {
    const query = new URLSearchParams({ '@v': "'i:0#.f|membership|" + recipient.replace(/'/g, "''") + "'" });
    const value = await this.json(this.rootOrigin() + '/_api/SP.UserProfiles.PeopleManager/GetPropertiesFor(accountName=@v)?' + query);
    return personIdentity(value, recipient);
  }
  async lookupName(query) {
    const response = await this.json(this.rootOrigin()
      + '/_api/SP.UI.ApplicationPages.ClientPeoplePickerWebServiceInterface.clientPeoplePickerSearchUser', {
      method: 'POST', json: { queryParams: { QueryString: query, PrincipalType: 1, PrincipalSource: 15,
        MaximumEntitySuggestions: 20, AllowEmailAddresses: true, AllowMultipleEntities: false,
        AllUrlZones: false } }, refresh: false,
    });
    let people = response.value || response.ClientPeoplePickerSearchUser
      || response.d?.ClientPeoplePickerSearchUser || response;
    if (typeof people === 'string') { try { people = JSON.parse(people); } catch (_) { people = null; } }
    if (!Array.isArray(people)) throw fail('directory_search_invalid', 'The directory returned an unrecognized search response.');
    const matches = new Map();
    for (const entry of people) {
      if (entry.EntityType !== 'User' || !entry.IsResolved) continue;
      const mail = String(entry.EntityData?.Email || entry.Description || '').trim().toLowerCase();
      if (/^[^\s@,]+@[^\s@,]+\.[^\s@,]+$/.test(mail)) matches.set(mail, { name: entry.DisplayText || mail, email: mail });
    }
    return [...matches.values()];
  }
  async drive() {
    const origin = this.personalOrigin();
    const value = await this.json(origin + '/_api/v2.0/drive');
    const owner = value.owner?.user?.id;
    if (owner !== this.session.credentials.self.split(':').pop()) throw fail('onedrive_owner_not_verified', 'The OneDrive owner does not match the authenticated Teams sender.');
    const url = sharepointUrl(value.webUrl, origin);
    const sitePath = url.pathname.split('/Documents')[0].replace(/\/$/, '');
    if (!sitePath.startsWith('/personal/')) throw fail('onedrive_site_unrecognized', 'The user drive is not a recognizable personal site.');
    return { id: value.id, origin, siteUrl: origin + sitePath, rootWebUrl: url.href.replace(/\/$/, ''),
      api: origin + '/_api/v2.0/drive' };
  }
  async folder(drive, names) {
    let parent = await this.json(drive.api + '/root');
    for (const name of names) {
      const url = drive.api + '/items/' + encodeURIComponent(parent.id) + ':/' + encodeURIComponent(name);
      let child;
      try { child = await this.json(url); }
      catch (error) {
        if (error.status !== 404) throw error;
        child = await this.json(drive.api + '/items/' + encodeURIComponent(parent.id) + '/children', {
          method: 'POST', json: { name, folder: {}, '@name.conflictBehavior': 'fail' }, refresh: false,
        });
      }
      if (!child.id || !child.folder) throw fail('upload_folder_not_verified', 'The upload destination is not a folder.');
      parent = child;
    }
    return parent;
  }
  async upload(file, operationId) {
    const drive = await this.drive();
    const folder = await this.folder(drive, ['Microsoft Teams Chat Files', 'Codex Messenger', operationId]);
    const target = drive.api + '/items/' + encodeURIComponent(folder.id) + ':/' + encodeURIComponent(file.fileName);
    let item;
    if (file.size <= 4 * 1024 * 1024) {
      item = await this.json(target + ':/content', { method: 'PUT', body: fs.readFileSync(file.resolved),
        headers: { 'Content-Type': 'application/octet-stream' }, refresh: false });
    } else {
      const session = await this.json(target + ':/oneDrive.createUploadSession', {
        // Direct SharePoint rejects Graph's optional item annotation here.
        // The path fixes the name; the unique operation folder prevents overwrites.
        method: 'POST', json: {}, refresh: false,
      });
      const upload = sharepointUrl(session.uploadUrl, drive.origin);
      const fd = fs.openSync(file.resolved, 'r');
      try {
        let offset = 0;
        while (offset < file.size) {
          const length = Math.min(10 * 1024 * 1024, file.size - offset);
          const buffer = Buffer.allocUnsafe(length);
          const read = fs.readSync(fd, buffer, 0, length, offset);
          if (read !== length) throw fail('upload_source_changed', 'The source file changed during upload.');
          let response;
          try {
            response = await this.fetch(upload.href, { method: 'PUT', headers: {
              'Content-Length': String(length), 'Content-Range': `bytes ${offset}-${offset + length - 1}/${file.size}`,
              'Content-Type': 'application/octet-stream',
            }, body: buffer, redirect: 'manual', signal: AbortSignal.timeout(60000) });
          } catch (_) { throw fail('upload_result_ambiguous', 'The upload chunk did not return a response; no chat message was sent.'); }
          if (![200, 201, 202].includes(response.status)) {
            await response.body?.cancel(); throw fail('upload_rejected', `SharePoint rejected an upload chunk with HTTP ${response.status}.`);
          }
          const value = await response.json();
          offset += length;
          if (response.status === 202) {
            if (Number(String(value.nextExpectedRanges?.[0] || '').split('-')[0]) !== offset) {
              throw fail('upload_range_not_verified', 'SharePoint did not confirm the expected upload range.');
            }
          } else {
            if (offset !== file.size) throw fail('upload_length_not_verified', 'SharePoint completed the upload before all bytes were supplied.');
            item = value;
          }
        }
      } finally { fs.closeSync(fd); }
    }
    if (!item?.id || item.name !== file.fileName || item.size !== file.size
        || item.parentReference?.driveId !== drive.id || !item.file) {
      throw fail('uploaded_file_not_verified', 'OneDrive did not confirm the exact file name, size, and owner drive.');
    }
    const downloaded = await this.json(drive.api + '/items/' + encodeURIComponent(item.id));
    const hash = await this.downloadHash(drive, downloaded);
    if (hash !== file.contentSha256) throw fail('upload_hash_not_verified', 'The uploaded bytes do not match the selected local file.');
    item = await this.json(drive.api + '/items/' + encodeURIComponent(item.id)
      + '?$select=id,name,size,webUrl,file,parentReference,sharepointIds');
    // Office formats can return a Doc.aspx viewer URL. Bind a plain file path
    // independently to the uploaded immutable item before constructing its card.
    let fileUrl = item.webUrl;
    if (new URL(fileUrl).search) {
      const names = ['Microsoft Teams Chat Files', 'Codex Messenger', operationId, file.fileName];
      const verifiedPath = await this.json(drive.api + '/root:/' + names.map(encodeURIComponent).join('/'));
      if (verifiedPath.id !== item.id || verifiedPath.size !== file.size || verifiedPath.name !== file.fileName) {
        throw fail('file_path_not_verified', 'The authenticated file path does not identify the exact upload.');
      }
      fileUrl = drive.rootWebUrl + '/' + names.map(encodeURIComponent).join('/');
    }
    return { drive, item, hash, fileUrl };
  }
  async downloadHash(drive, item) {
    const raw = item['@content.downloadUrl'] || item['@microsoft.graph.downloadUrl'];
    if (!raw) throw fail('download_url_unavailable', 'OneDrive did not return a download URL for verification.');
    const url = sharepointUrl(raw, drive.origin);
    const response = await this.fetch(url.href, { redirect: 'manual', signal: AbortSignal.timeout(60000) });
    if (!response.ok || !response.body) throw fail('download_verification_failed', 'The uploaded file could not be downloaded for integrity verification.');
    const hash = crypto.createHash('sha256');
    for await (const bytes of response.body) hash.update(bytes);
    return hash.digest('hex');
  }
  // Fetches a file someone shared in chat. The name and URL come from a message, so both are untrusted:
  // the URL must be on this tenant's OneDrive, and the file is never allowed to overwrite anything.
  async downloadAttachment(attachment, directory) {
    const origin = this.personalOrigin();
    if (!attachment.url) throw fail('attachment_url_unavailable', 'The message does not include a file link.');
    const source = sharepointUrl(attachment.url, origin);
    const shareId = 'u!' + Buffer.from(source.href).toString('base64url');
    const item = await this.json(origin + '/_api/v2.0/shares/' + shareId + '/driveItem');
    const raw = item['@content.downloadUrl'] || item['@microsoft.graph.downloadUrl'];
    if (!raw || !item.file) throw fail('download_url_unavailable', 'OneDrive did not return a download URL for this file.');
    const name = safeFileName(attachment.fileName);
    const url = sharepointUrl(raw, origin);
    let response;
    try { response = await this.fetch(url.href, { redirect: 'manual', signal: AbortSignal.timeout(300000) }); }
    catch (_) { throw fail('download_failed', 'The file download did not return a response.'); }
    if (!response.ok || !response.body) {
      await response.body?.cancel(); throw fail('download_failed', `The file download returned HTTP ${response.status}.`);
    }
    const target = path.join(directory, name);
    const temporary = path.join(directory, '.' + crypto.randomUUID() + '.part');
    const hash = crypto.createHash('sha256');
    let size = 0;
    const fd = fs.openSync(temporary, 'wx', 0o600);
    try {
      try {
        for await (const bytes of response.body) { hash.update(bytes); size += bytes.length; fs.writeSync(fd, bytes); }
      } finally { fs.closeSync(fd); }
      if (Number.isInteger(item.size) && item.size !== size) throw fail('download_size_not_verified', 'The downloaded size does not match OneDrive.');
      try { fs.linkSync(temporary, target); } // Unlike rename, this refuses to replace an existing file.
      catch (error) {
        if (error.code === 'EEXIST') throw fail('download_target_exists', 'A file with this name already exists in that folder.');
        throw error;
      }
    } finally { fs.rmSync(temporary, { force: true }); }
    return { path: target, fileName: name, size, contentSha256: hash.digest('hex') };
  }
  async share(uploaded, binding) {
    const { drive, item } = uploaded;
    const result = await this.json(drive.api + '/items/' + encodeURIComponent(item.id) + '/oneDrive.invite', {
      method: 'POST', json: { recipients: [{ objectId: binding.memberId.split(':').pop() }],
        requireSignIn: true, sendInvitation: false, roles: ['read'], retainInheritedPermissions: false }, refresh: false,
    });
    if (!Array.isArray(result.value) || result.value.some(permission => permission.error)) {
      throw fail('file_permission_not_verified', 'OneDrive did not confirm the sharing permission.');
    }
    const permissions = await this.json(drive.api + '/items/' + encodeURIComponent(item.id) + '/permissions');
    verifyPermissions(permissions.value, binding, this.session.credentials.self);
    return { recipientAccessVerified: true, itemId: item.id, readOnlyAccess: true };
  }
  // Read access for each current group member individually; never a group, org-wide or anonymous link.
  async shareWithGroup(uploaded, binding) {
    const { drive, item } = uploaded;
    const self = this.session.credentials.self;
    const peers = (binding.members || []).filter(id => id !== self).map(id => id.split(':').pop());
    if (!peers.length) throw fail('group_membership_not_verified', 'The group has no members to share the file with.');
    const result = await this.json(drive.api + '/items/' + encodeURIComponent(item.id) + '/oneDrive.invite', {
      method: 'POST', json: { recipients: peers.map(objectId => ({ objectId })),
        requireSignIn: true, sendInvitation: false, roles: ['read'], retainInheritedPermissions: false }, refresh: false,
    });
    if (!Array.isArray(result.value) || result.value.some(permission => permission.error)) {
      throw fail('file_permission_not_verified', 'OneDrive did not confirm the sharing permission.');
    }
    const permissions = await this.json(drive.api + '/items/' + encodeURIComponent(item.id) + '/permissions');
    const grantedTo = verifyPermissionSet(permissions.value, peers, self.split(':').pop());
    return { recipientAccessVerified: true, itemId: item.id, readOnlyAccess: true, grantedTo };
  }
}

function safeFileName(value) {
  const name = String(value || '');
  if (!name || name === '.' || name === '..' || name.startsWith('.') || /[/\\\x00-\x1f]/.test(name)) {
    throw fail('attachment_name_unsafe', 'The attachment name is not a safe file name.');
  }
  return name;
}
function permissionIdentities(permission) {
  return [permission.grantedToV2, permission.grantedTo, ...(permission.grantedToIdentitiesV2 || []),
    ...(permission.grantedToIdentities || [])].filter(Boolean);
}
// Every intended person must hold read access, and nobody else (apart from the owner) may hold any access.
function verifyPermissionSet(permissions, peers, self) {
  if (!Array.isArray(permissions)) throw fail('file_permission_not_verified', 'OneDrive did not return file permissions.');
  const allowed = new Set(peers), confirmed = new Map();
  for (const permission of permissions) {
    if (permission.link && ['anonymous', 'organization'].includes(permission.link.scope)) {
      throw fail('file_permission_scope_too_broad', 'The file has a broader sharing link than the intended recipients.');
    }
    for (const identity of permissionIdentities(permission)) {
      const id = identity.user?.id;
      if (allowed.has(id) && permission.roles?.includes('read')) {
        confirmed.set(id, identity.user.displayName || identity.user.email || id);
      } else if (id && id !== self && !allowed.has(id)) throw fail('file_permission_scope_too_broad', 'The file grants access to another user.');
      if (identity.group || identity.siteGroup) throw fail('file_permission_scope_too_broad', 'The file grants group access.');
    }
  }
  if (peers.some(id => !confirmed.has(id))) throw fail('file_permission_not_verified', 'Read access for every intended member was not confirmed.');
  return peers.map(id => confirmed.get(id));
}
function verifyPermissions(permissions, binding, sender) {
  verifyPermissionSet(permissions, [binding.memberId.split(':').pop()], sender.split(':').pop());
  return true;
}

module.exports = { SharePointService, personIdentity, safeFileName, sharepointUrl, verifyPermissionSet, verifyPermissions };
