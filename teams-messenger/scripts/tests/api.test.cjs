'use strict';
const test=require('node:test'), assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {execFileSync}=require('node:child_process');
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'teams-api-unit-'));
process.env.TEAMS_WEB_APP_DIR=directory;
const common=require('../cli-common.cjs');
const {ChatSession,email,memberFromToken}=require('../chat-session.cjs');
const {ChatService,verifyMembers,deliveryMatch,contentHtml,nextHistoryUrl,attachments}=require('../chat-service.cjs');
const {SharePointService,personIdentity,sharepointUrl,verifyPermissions}=require('../sharepoint-service.cjs');
const {argumentsFor,dateBound,localFile,sendText,sendFile,attachmentPayload}=require('../teams-api.cjs');
const self='8:orgid:11111111-1111-1111-1111-111111111111';
const peer='8:orgid:22222222-2222-2222-2222-222222222222';
const binding={recipient:'peer@example.com',memberId:peer,conversationId:'19:example@unq.gbl.spaces',expectedName:'Peer'};
const base='https://teams.cloud.microsoft/api/chatsvc/in/v1/users/ME/conversations';
const session=()=>({credentials:{self,base,headers:{Authorization:'in-memory-fixture'}},captureError:null,
  decode:ChatSession.prototype.decode, refresh:async()=>{}});
const json=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json'}});
const code=(fn,expected)=>assert.throws(fn,e=>e.code===expected);
test('exact recipient rejects groups, names and injected values',()=>{
 assert.equal(email(' Peer@Example.com '),'peer@example.com');
 for(const bad of ['Peer','a@b.com,c@d.com','a@b.com\nother','a"@b.com','a\\@b.com','a@[b].com'])code(()=>email(bad),'invalid_recipient');
});
test('directory binds exact email to immutable object ID',()=>{
 const profile={Email:binding.recipient,DisplayName:'Peer',UserProfileProperties:[{Key:'msOnline-ObjectId',Value:peer.split(':').pop()}]};
 assert.equal(personIdentity(profile,binding.recipient).objectId,peer.split(':').pop());
 code(()=>personIdentity({...profile,Email:'other@example.com'},binding.recipient),'directory_identity_not_verified');
 code(()=>personIdentity({...profile,UserProfileProperties:[]},binding.recipient),'directory_identity_not_verified');
});
test('thread members reject missing recipient, extras and duplicates',()=>{
 assert.equal(verifyMembers({members:[{id:self},{mri:peer}]},peer,self),true);
 for(const ids of [[self],[self,'other'],[self,peer,'other'],[self,peer,peer]])code(()=>verifyMembers({members:ids.map(id=>({id}))},peer,self),'server_membership_not_verified');
});
test('delivery requires new ID, exact client ID, sender and content',()=>{
 const m={id:'new',clientmessageid:'c',from:self,content:'<p>test</p>'};
 const expected={beforeIds:new Set(['old']),clientId:'c',self,content:m.content};
 assert.equal(deliveryMatch([m],expected),m);
 assert.equal(deliveryMatch([{...m,content:'<p>one<br>\r\ntwo</p>'}],{...expected,content:'<p>one<br>two</p>'})?.id,'new');
 for(const change of [{id:'old'},{clientmessageid:'different'},{from:peer},{content:'<p>wrong</p>'}])assert.equal(deliveryMatch([{...m,...change}],expected),null);
 code(()=>deliveryMatch([m,{...m,id:'other'}],expected),'delivery_match_ambiguous');
});
test('attachments cannot be verified by a wrong filename',()=>{
 const m={id:'new',clientmessageid:'c',from:self,properties:{files:JSON.stringify([{fileName:'exact.txt',fileInfo:{itemId:'immutable'}}])}};
 const expected={beforeIds:new Set(),clientId:'c',self,fileName:'exact.txt'};
 assert.equal(deliveryMatch([m],expected),m);
 assert.equal(deliveryMatch([m],{...expected,fileName:'other.txt'}),null);
 assert.equal(deliveryMatch([m],{...expected,fileItemId:'different'}),null);
 assert.equal(attachments(m)[0].itemId,'immutable');
});
test('HTML encoding and inert decoding preserve authored blank lines and indentation',async()=>{
 const text='Hello <&>\n\n  indented 日本語 😊\nhttps://example.com';
 assert.equal((await session().decode([{content:contentHtml(text)}]))[0],text);
 assert.equal((await session().decode([{content:contentHtml(text).replaceAll('<br>','<br>\r\n')}]))[0],text);
 assert.equal((await session().decode([{content:contentHtml('  first\n\n')}]))[0],'  first\n\n');
 assert.equal((await session().decode([{content:'<p>one</p><script>evil</script><p>two &amp; three</p>'}]))[0],'one\ntwo & three');
});
test('pagination accepts unescaped same-chat link but rejects another chat or host',()=>{
 const root=base+'/'+encodeURIComponent(binding.conversationId)+'/messages';
 assert.ok(nextHistoryUrl({_metadata:{backwardLink:base+'/'+binding.conversationId+'/messages?cursor=x'}},root,root));
 code(()=>nextHistoryUrl({_metadata:{backwardLink:base+'/another/messages'}},root,root),'untrusted_service_url');
 code(()=>nextHistoryUrl({_metadata:{backwardLink:'https://evil.example/messages'}},root,root),'untrusted_service_url');
});
test('history paginates, deduplicates and orders messages chronologically',async()=>{
 const s=session(),api=new ChatService(s);
 let calls=0;
 api.page=async()=>++calls===1?{messages:[{id:'103',content:'<p>new</p>',from:self},{id:'102',content:'<p>middle</p>',from:peer}],next:'page2'}:{messages:[{id:'102',content:'<p>middle</p>',from:peer},{id:'101',content:'<p>old</p>',from:peer}],next:null};
 const result=await api.history(binding,{limit:3});
 assert.deepEqual(result.messages.map(m=>m.id),['101','102','103']);assert.equal(calls,2);assert.equal(result.scanned,3);
});
test('search matches file names, case and date bounds and reports scan limits',async()=>{
 const s=session(),api=new ChatService(s);
 api.page=async()=>({messages:[{id:'1791980000000',content:'<p>Alpha</p>',from:self,properties:{files:'[{"fileName":"Report.pdf"}]'}},{id:'1791979000000',content:'<p>alpha</p>',from:peer}],next:'older'});
 assert.equal((await api.history(binding,{query:'REPORT.PDF',limit:1})).messages.length,1);
 assert.equal((await api.history(binding,{query:'Alpha',caseSensitive:true,scan:2})).messages.length,1);
 const result=await api.history(binding,{query:'missing',scan:2});assert.equal(result.scanLimitReached,true);
 assert.equal((await api.history(binding,{query:'alpha',after:1791979500000,scan:2})).messages.length,1);
});
test('history detects repeated pagination links',async()=>{
 const api=new ChatService(session());api.page=async()=>({messages:[],next:'same'});
 await assert.rejects(api.history(binding),e=>e.code==='history_pagination_loop');
});
test('401 read refreshes once; message POST never retries',async()=>{
 let requests=0,refreshes=0;const s=session();s.refresh=async()=>{refreshes++;};
 const api=new ChatService(s,async()=>++requests===1?json({},401):json({messages:[]}));
 await api.page(binding);assert.equal(requests,2);assert.equal(refreshes,1);
 requests=0;refreshes=0;const post=new ChatService(s,async()=>{requests++;return json({},401);});
 await assert.rejects(post.post(binding,{}),e=>e.code==='send_result_ambiguous');assert.equal(requests,1);assert.equal(refreshes,0);
});
test('read refresh refuses a changed sender',async()=>{
 const s=session();s.refresh=async()=>{s.credentials={...s.credentials,self:peer};};
 await assert.rejects(new ChatService(s,async()=>json({},401)).page(binding),e=>e.code==='authentication_changed');
});
test('outgoing credentials never follow redirects or untrusted origins',async()=>{
 let calls=0;const api=new ChatService(session(),async()=>{calls++;return json({},302);});
 await assert.rejects(api.request('https://evil.example/api'),e=>e.code==='untrusted_service_url');assert.equal(calls,0);
 await assert.rejects(api.page(binding),e=>e.code==='service_http_error');assert.equal(calls,1);
 code(()=>sharepointUrl('https://evil.example/file','https://tenant-my.sharepoint.com'),'sharepoint_scope_changed');
});
test('permission proof refuses other users, groups and broad links',()=>{
 const permissions=[{roles:['owner'],grantedToV2:{user:{id:self.split(':').pop()}}},{roles:['read'],grantedToV2:{user:{id:peer.split(':').pop()}}}];
 assert.equal(verifyPermissions(permissions,binding,self),true);
 for(const extra of [{roles:['read'],grantedToV2:{user:{id:'other'}}},{roles:['read'],grantedToV2:{group:{id:'group'}}},{link:{scope:'anonymous'}},{link:{scope:'organization'}}])code(()=>verifyPermissions([...permissions,extra],binding,self),'file_permission_scope_too_broad');
 code(()=>verifyPermissions(permissions.slice(0,1),binding,self),'file_permission_not_verified');
});
test('file paths require a real readable non-empty regular file',async()=>{
 const file=path.join(directory,'fixture.txt');fs.writeFileSync(file,'test');
 assert.equal((await localFile(file)).size,4);
 for(const input of ['relative.txt',directory,path.join(directory,'missing')])await assert.rejects(localFile(input));
 fs.writeFileSync(file,'');await assert.rejects(localFile(file),e=>e.code==='invalid_file');
});
test('CLI rejects missing, repeated and command-inappropriate flags',()=>{
 for(const argv of [['read',binding.recipient,'--limit'],['read',binding.recipient,'--limit','2','--limit','3'],['read',binding.recipient,'--force'],['send','a@b.com','test','--unknown']])code(()=>argumentsFor(argv),'invalid_arguments');
 assert.equal(argumentsFor(['send-file',binding.recipient,'/tmp/file','--message','caption']).options['--message'],'caption');
 code(()=>dateBound('2026-99-30',false),'invalid_arguments');
 code(()=>dateBound('2026-02-30',false),'invalid_arguments');
 assert.equal(dateBound('2026-10-14',true)-dateBound('2026-10-14',false),86400000-1);
});
test('corrupt receipts fail closed and writes have private permissions',()=>{
 common.saveReceipts({test:{status:'verified'}});assert.deepEqual(common.loadReceipts(),{test:{status:'verified'}});
 assert.equal(fs.statSync(common.RECEIPTS_PATH).mode&0o777,0o600);
 fs.writeFileSync(common.RECEIPTS_PATH,'invalid');code(()=>common.loadReceipts(),'receipt_store_invalid');common.saveReceipts({});
});
test('verified duplicates do not issue a POST; ambiguous attempts block retries',async()=>{
 const s=session();s.resolve=async()=>binding;const key=common.receiptKey(binding.recipient,'test');
 common.saveReceipts({[key]:{status:'verified',memberId:peer,senderId:self}});
 assert.equal((await sendText(s,binding.recipient,'test')).duplicatePrevented,true);
 common.saveReceipts({[key]:{status:'ambiguous',memberId:peer,senderId:self}});
 await assert.rejects(sendText(s,binding.recipient,'test'),e=>e.code==='prior_attempt_ambiguous');
 common.saveReceipts({});
});
test('operation lock blocks contention and releases without stale PID state',()=>{
 const wrapper=path.resolve(__dirname,'../teams');
 const script="import fcntl,os,subprocess\np=os.path.join(os.environ['TEAMS_WEB_APP_DIR'],'operation.lock')\nf=open(p,'w');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nr=subprocess.run(["+JSON.stringify(wrapper)+",'--help'],capture_output=True,text=True)\nprint(r.returncode);print(r.stdout)";
 const output=execFileSync('python3',['-I','-c',script],{encoding:'utf8'});
 assert.match(output,/operation_in_progress/);
 assert.match(execFileSync(wrapper,['--help'],{encoding:'utf8'}),/Usage:/);
});
test('attachment duplicates include caption and preserve uncaptioned legacy keys',async()=>{
 const filePath=path.join(directory,'caption.txt');fs.writeFileSync(filePath,'harmless');
 const file=await localFile(filePath),s=session();s.resolve=async()=>binding;s.resources=[];
 const key=common.fileReceiptKey(binding.recipient,file.fileName,file.contentSha256,'original caption');
 common.saveReceipts({[key]:{status:'verified',memberId:peer,senderId:self}});
 assert.equal((await sendFile(s,binding.recipient,filePath,{message:'original caption'})).duplicatePrevented,true);
 await assert.rejects(sendFile(s,binding.recipient,filePath,{message:'changed caption'}),e=>e.code==='onedrive_resource_ambiguous');
 assert.equal(common.fileReceiptKey(binding.recipient,file.fileName,file.contentSha256),common.fileReceiptKey(binding.recipient,file.fileName,file.contentSha256,''));
 common.saveReceipts({});
});
test('chunked upload sends complete bytes in order without bearer credentials',async()=>{
 const crypto=require('node:crypto'),filePath=path.join(directory,'chunked.txt');
 fs.writeFileSync(filePath,Buffer.alloc(10*1024*1024+123,0x41));const file=await localFile(filePath);
 const origin='https://tenant-my.sharepoint.com',drive={id:'drive',origin,api:origin+'/_api/v2.0/drive',siteUrl:origin+'/personal/user'};
 const item={id:'item',name:file.fileName,size:file.size,webUrl:origin+'/personal/user/Documents/chunked.txt',parentReference:{driveId:drive.id},file:{},sharepointIds:{listItemUniqueId:peer.split(':').pop()}};
 const chunks=[];let offset=0,sessionRequests=0;
 const api=new SharePointService({},async(url,opts)=>{
  assert.equal(opts.headers.Authorization,undefined);assert.equal(opts.redirect,'manual');
  assert.equal(opts.headers['Content-Range'],`bytes ${offset}-${offset+opts.body.length-1}/${file.size}`);
  chunks.push(opts.body);offset+=opts.body.length;
  return offset<file.size?json({nextExpectedRanges:[offset+'-']},202):json(item,201);
 });
 api.drive=async()=>drive;api.folder=async()=>({id:'folder'});
 api.json=async(url,opts)=>{if(url.includes('createUploadSession')){sessionRequests++;assert.deepEqual(opts.json,{});return {uploadUrl:origin+'/signed-upload'};}return item;};
 api.downloadHash=async()=>file.contentSha256;
 const uploaded=await api.upload(file,'unique-operation');
 assert.equal(sessionRequests,1);assert.equal(chunks.length,2);assert.equal(uploaded.item.id,item.id);
 assert.equal(crypto.createHash('sha256').update(Buffer.concat(chunks)).digest('hex'),file.contentSha256);
});
test('upload integrity mismatch blocks sharing and sending',async()=>{
 const filePath=path.join(directory,'changed.txt');fs.writeFileSync(filePath,'expected');const file=await localFile(filePath);
 const item={id:'item',name:file.fileName,size:file.size,parentReference:{driveId:'drive'},file:{}};
 const api=new SharePointService({});api.drive=async()=>({id:'drive',api:'https://tenant-my.sharepoint.com/_api/v2.0/drive'});
 api.folder=async()=>({id:'folder'});api.json=async()=>item;api.downloadHash=async()=> 'wronghash';
 await assert.rejects(api.upload(file,'operation'),e=>e.code==='upload_hash_not_verified');
});
test('ambiguous POST has a durable attempted receipt and is never repeated',async()=>{
 const s=session();s.resolve=async()=>binding;const message='network-uncertainty-fixture',key=common.receiptKey(binding.recipient,message);
 let posts=0;const originalFetch=global.fetch;
 global.fetch=async(url,opts)=>{
  if(opts.method==='POST'){posts++;assert.equal(common.loadReceipts()[key].status,'attempted');throw new Error('connection lost');}
  if(String(url).includes('/threads/'))return json({members:[{id:self},{id:peer}]});
  return json({messages:[]});
 };
 try{
  await assert.rejects(sendText(s,binding.recipient,message),e=>e.code==='send_result_ambiguous');
  assert.equal(common.loadReceipts()[key].status,'ambiguous');
  await assert.rejects(sendText(s,binding.recipient,message),e=>e.code==='prior_attempt_ambiguous');assert.equal(posts,1);
 }finally{global.fetch=originalFetch;common.saveReceipts({});}
});
test('Office viewer URL is bound to the immutable file path before sharing',async()=>{
 const filePath=path.join(directory,'office.csv');fs.writeFileSync(filePath,'test,only\n');const file=await localFile(filePath);
 const origin='https://tenant-my.sharepoint.com',drive={id:'drive',origin,api:origin+'/_api/v2.0/drive',siteUrl:origin+'/personal/user',rootWebUrl:origin+'/personal/user/Documents'};
 const item={id:'immutable',name:file.fileName,size:file.size,parentReference:{driveId:'drive'},file:{},webUrl:origin+'/personal/user/_layouts/15/Doc.aspx?sourcedoc=example',sharepointIds:{listItemUniqueId:peer.split(':').pop()}};
 const api=new SharePointService({});api.drive=async()=>drive;api.folder=async()=>({id:'folder'});api.downloadHash=async()=>file.contentSha256;
 let pathChecks=0;api.json=async(url)=>{if(url.includes('/root:/'))pathChecks++;return item;};
 const uploaded=await api.upload(file,'unique');assert.equal(pathChecks,1);
 const payload=attachmentPayload(uploaded);assert.equal(payload.fileInfo.itemId,item.id);assert.equal(new URL(payload.objectUrl).search,'');assert.ok(payload.objectUrl.endsWith('/office.csv'));
 api.json=async(url)=>url.includes('/root:/')?{...item,id:'another'}:item;
 await assert.rejects(api.upload(file,'unique'),e=>e.code==='file_path_not_verified');
});
test('legacy or other-account receipts cannot claim delivery for the current sender',async()=>{
 const s=session();s.resolve=async()=>binding;const message='legacy sender fixture',key=common.receiptKey(binding.recipient,message);
 for(const receipt of [{status:'verified',memberId:peer},{status:'verified',memberId:peer,senderId:peer}]){
  common.saveReceipts({[key]:receipt});await assert.rejects(sendText(s,binding.recipient,message),e=>e.code==='prior_attempt_ambiguous');
 }
 common.saveReceipts({});
});
// ---- Group chats ----
const {groupThreadId,verifyGroup}=require('../chat-service.cjs');
const {verifyPermissionSet}=require('../sharepoint-service.cjs');
const {sendGroupText}=require('../teams-api.cjs');
const groupId='19:0123456789abcdef0123456789abcdef@thread.v2';
const third='8:orgid:33333333-3333-3333-3333-333333333333';
const groupThread=(over={})=>({members:[{id:self},{id:peer},{id:third}],properties:{topic:'AI Quality',threadType:'chat'},...over});
const groupSession=()=>{const s=session();s.resolveGroup=ChatSession.prototype.resolveGroup;return s;};
test('group IDs accept only group chats',()=>{
 assert.equal(groupThreadId(' '+groupId+' '),groupId);
 for(const bad of ['AI Quality','19:abc_def@unq.gbl.spaces','19:0123456789abcdef0123456789abcdef@thread.tacv2','19:0123456789abcdef0123456789abcdef@thread.skype','19:meeting_abc@thread.v2',''])code(()=>groupThreadId(bad),'invalid_group');
});
test('group verification checks sender, internal members, type, exact name and a stable roster',()=>{
 const b={kind:'group',conversationId:groupId,expectedName:'AI Quality'};
 assert.deepEqual(verifyGroup(groupThread(),b,self),[self,peer,third].sort());
 code(()=>verifyGroup(groupThread({members:[{id:peer},{id:third}]}),b,self),'group_membership_not_verified');
 code(()=>verifyGroup(groupThread({members:[{id:self},{id:peer},{id:peer}]}),b,self),'group_membership_not_verified');
 code(()=>verifyGroup(groupThread({members:[{id:self},{id:'8:live:outsider'}]}),b,self),'group_member_not_internal');
 code(()=>verifyGroup(groupThread({members:[{id:self},{id:'28:bot-id'}]}),b,self),'group_member_not_internal');
 code(()=>verifyGroup(groupThread({properties:{topic:'AI Quality',threadType:'meeting'}}),b,self),'not_a_group_chat');
 code(()=>verifyGroup(groupThread({properties:{topic:'AI quality',threadType:'chat'}}),b,self),'group_name_not_verified');
 code(()=>verifyGroup(groupThread(),{...b,members:[self,peer].sort()},self),'group_membership_changed');
});
test('group file permissions require every member and nobody else',()=>{
 const p=id=>({roles:['read'],grantedToV2:{user:{id:id.split(':').pop(),displayName:'User '+id.slice(-4)}}});
 const owner={roles:['owner'],grantedToV2:{user:{id:self.split(':').pop()}}};
 const peers=[peer,third].map(id=>id.split(':').pop());
 assert.equal(verifyPermissionSet([owner,p(peer),p(third)],peers,self.split(':').pop()).length,2);
 code(()=>verifyPermissionSet([owner,p(peer)],peers,self.split(':').pop()),'file_permission_not_verified');
 for(const extra of [p('8:orgid:44444444-4444-4444-4444-444444444444'),{link:{scope:'organization'}},{roles:['read'],grantedToV2:{group:{id:'g'}}}])
  code(()=>verifyPermissionSet([owner,p(peer),p(third),extra],peers,self.split(':').pop()),'file_permission_scope_too_broad');
});
test('group send posts once and verifies delivery and an unchanged roster',async()=>{
 const s=groupSession(),message='group fixture message';let posts=0,posted=null;const originalFetch=global.fetch;
 global.fetch=async(url,opts)=>{
  if(opts.method==='POST'){posts++;posted=JSON.parse(opts.body);return json({},201);}
  if(String(url).includes('/threads/'))return json(groupThread());
  return json({messages:posted?[{id:'900',clientmessageid:posted.clientmessageid,from:self,content:posted.content}]:[]});
 };
 try{
  const result=await sendGroupText(s,groupId,'AI Quality',message);
  assert.equal(result.verified,true);assert.equal(posts,1);assert.equal(result.proof.exactGroupVerified,true);
  assert.equal(result.proof.membershipUnchanged,true);assert.equal(result.proof.recipientProof.memberCount,3);
  const again=await sendGroupText(s,groupId,'AI Quality',message);assert.equal(again.duplicatePrevented,true);assert.equal(posts,1);
  assert.notEqual(common.groupReceiptKey(groupId,message),common.receiptKey(groupId,message));
 }finally{global.fetch=originalFetch;common.saveReceipts({});}
});
test('a roster change before the POST stops the group send',async()=>{
 const s=groupSession();let threadReads=0,posts=0;const originalFetch=global.fetch;
 global.fetch=async(url,opts)=>{
  if(opts.method==='POST'){posts++;return json({},201);}
  if(String(url).includes('/threads/'))return json(++threadReads===1?groupThread():groupThread({members:[{id:self},{id:peer}]}));
  return json({messages:[]});
 };
 try{await assert.rejects(sendGroupText(s,groupId,'AI Quality','roster fixture'),e=>e.code==='group_membership_changed');assert.equal(posts,0);}
 finally{global.fetch=originalFetch;common.saveReceipts({});}
});
test('wrong group name is refused before any POST',async()=>{
 const s=groupSession();let posts=0;const originalFetch=global.fetch;
 global.fetch=async(url,opts)=>{if(opts.method==='POST')posts++;return json(groupThread());};
 try{await assert.rejects(sendGroupText(s,groupId,'Another Group','x'),e=>e.code==='group_name_not_verified');assert.equal(posts,0);}
 finally{global.fetch=originalFetch;}
});
test('group CLI flags',()=>{
 assert.equal(argumentsFor(['group-send-file',groupId,'AI Quality','/tmp/f','--message','c']).options['--message'],'c');
 code(()=>argumentsFor(['group-info',groupId,'AI Quality','--force']),'invalid_arguments');
 code(()=>argumentsFor(['group-send',groupId,'AI Quality','x','--message','c']),'invalid_arguments');
});

// ---- Meetings (Outlook calendar API) ----
const calendar=require('../calendar-service.cjs');
const {createMeeting,meetingKey}=require('../teams-api.cjs');
const {outlookToken}=require('../chat-session.cjs');
const now=Date.parse('2026-11-02T07:00:00Z');
const fakeJwt=claims=>'eyJhbGciOiJub25lIn0.'+Buffer.from(JSON.stringify(claims)).toString('base64url')+'.sig';
test('outlook credential must be for this user, Outlook, calendar write, and unexpired',()=>{
 const oid='11111111-1111-1111-1111-111111111111', good={aud:'https://outlook.office.com/',oid,scp:'Mail.Read Calendars.ReadWrite',exp:Math.floor(Date.now()/1000)+3600};
 assert.ok(outlookToken('Bearer '+fakeJwt(good),oid));
 for(const change of [{aud:'https://graph.microsoft.com'},{oid:'22222222-2222-2222-2222-222222222222'},{scp:'Calendars.Read'},{exp:Math.floor(Date.now()/1000)}])
  assert.equal(outlookToken('Bearer '+fakeJwt({...good,...change}),oid),null);
 assert.equal(outlookToken('Basic abc',oid),null);
});
test('meeting times convert the wall clock in the meeting zone',()=>{
 const t=calendar.meetingTimes({start:'2026-11-03T23:45',duration:30,now});
 assert.deepEqual([t.start,t.end,t.startUtc],['2026-11-03T23:45:00','2026-11-04T00:15:00','2026-11-03T18:15:00.000Z']);
 assert.equal(calendar.meetingTimes({start:'2027-03-14T03:30',zone:'Eastern Standard Time',now}).startUtc,'2027-03-14T07:30:00.000Z');
 code(()=>calendar.meetingTimes({start:'2027-03-14T02:30',zone:'Eastern Standard Time',now}),'invalid_start');
 code(()=>calendar.meetingTimes({start:'2026-11-01T10:00',now}),'start_in_past');
 code(()=>calendar.meetingTimes({start:'2026-11-03 15:00',now}),'invalid_start');
 code(()=>calendar.meetingTimes({start:'2026-11-03T15:00',duration:3,now}),'invalid_duration');
 code(()=>calendar.meetingTimes({start:'2026-11-03T15:00',zone:'Mars Time',now}),'invalid_time_zone');
});
test('meeting attendees and titles are validated',()=>{
 assert.deepEqual(calendar.attendeeList(' A@x.com, b@x.com '),['a@x.com','b@x.com']);
 assert.deepEqual(calendar.attendeeList(undefined),[]);
 code(()=>calendar.attendeeList('a@x.com,A@x.com'),'invalid_attendees');
 code(()=>calendar.attendeeList(' , '),'invalid_attendees');
 code(()=>calendar.meetingSubject('   '),'invalid_subject');
 assert.equal(calendar.meetingSubject(' Weekly   sync '),'Weekly sync');
});
const plan=()=>({organizer:{email:'me@example.com'},subject:'Sync',message:'Agenda <1>',
 times:calendar.meetingTimes({start:'2026-11-03T15:00',now}),attendees:[{email:'peer@example.com',name:'Peer',objectId:'2'}]});
test('meeting payload asks Outlook for a Teams meeting with exact attendees',()=>{
 const body=calendar.meetingPayload(plan(),'tx-1');
 assert.equal(body.IsOnlineMeeting,true); assert.equal(body.OnlineMeetingProvider,'TeamsForBusiness');
 assert.deepEqual(body.Start,{DateTime:'2026-11-03T15:00:00',TimeZone:'India Standard Time'});
 assert.deepEqual(body.Attendees,[{EmailAddress:{Address:'peer@example.com',Name:'Peer'},Type:'Required'}]);
 assert.equal(body.Body.Content,'<p>Agenda &lt;1&gt;</p>'); assert.equal(body.TransactionId,'tx-1');
});
const stored=(change={})=>({Id:'evt1',Subject:'Sync',Start:{DateTime:'2026-11-03T15:00:00.0000000'},End:{DateTime:'2026-11-03T15:30:00.0000000'},
 Attendees:[{EmailAddress:{Address:'Peer@example.com'}}],IsOnlineMeeting:true,IsOrganizer:true,IsCancelled:false,
 OnlineMeeting:{JoinUrl:'https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0'},
 SingleValueExtendedProperties:[{PropertyId:calendar.INVITES_SENT,Value:'true'}],...change});
test('meeting proof checks what Outlook stored',()=>{
 assert.ok(Object.values(calendar.eventProof(stored(),plan())).every(v=>v===true));
 assert.equal(calendar.eventProof(stored({Attendees:[]}),plan()).attendeesMatch,false);
 assert.equal(calendar.eventProof(stored({Attendees:[{EmailAddress:{Address:'peer@example.com'}},{EmailAddress:{Address:'x@example.com'}}]}),plan()).attendeesMatch,false);
 assert.equal(calendar.eventProof(stored({Start:{DateTime:'2026-11-03T16:00:00'}}),plan()).timesMatch,false);
 assert.equal(calendar.eventProof(stored({OnlineMeeting:{JoinUrl:'https://evil.example/l/meetup-join/x'}}),plan()).teamsLinkCreated,false);
 assert.equal(calendar.eventProof(stored({SingleValueExtendedProperties:[]}),plan()).invitesSent,null);
});
function meetingSession(){
 return {credentials:{self},resources:[{origin:'https://example.sharepoint.com',secret:'s',expiresAt:Date.now()+600000}],
  resource(origin){return this.resources.find(token=>token.origin===origin);},
  outlookCredential:()=>({secret:'o',expiresAt:Date.now()+600000}),refresh:async()=>{}};
}
function meetingFetch({create}={}){
 const calls=[];
 const impl=async(url,init={})=>{
  calls.push({url,method:init.method||'GET',body:init.body});
  const u=new URL(url);
  if(u.hostname==='example.sharepoint.com')return json({Email:'peer@example.com',DisplayName:'Peer',UserProfileProperties:[{Key:'msOnline-ObjectId',Value:peer.split(':').pop()}]});
  if(u.pathname==='/api/v2.0/me')return json({EmailAddress:'me@example.com',DisplayName:'Me'});
  if(u.pathname==='/api/v2.0/me/events'&&init.method==='POST')return create?create():json({Id:'evt1'},201);
  if(u.pathname==='/api/v2.0/me/events/evt1')return json(stored());
  throw new Error('unexpected '+url);
 };
 return {calls,impl};
}
async function withFetch(impl,fn){const original=global.fetch;global.fetch=impl;try{return await fn();}finally{global.fetch=original;}}
const meetingOptions={'--start':'2026-11-03T15:00','--attendees':'peer@example.com','--message':'Agenda'};
test('meeting creates once, verifies, then blocks a duplicate',async()=>{
 const {calls,impl}=meetingFetch(); const s=meetingSession();
 const first=await withFetch(impl,()=>createMeeting(s,'Sync',meetingOptions,{now,service:new calendar.CalendarService(s,impl,async()=>{})}));
 assert.equal(first.verified,true); assert.equal(first.proof.singlePost,true); assert.equal(first.proof.invitesSent,true);
 assert.match(first.teamsJoinUrl,/^https:\/\/teams\.microsoft\.com\//);
 assert.equal(calls.filter(c=>c.method==='POST'&&c.url.endsWith('/me/events')).length,1);
 const again=await withFetch(impl,()=>createMeeting(s,'Sync',meetingOptions,{now,service:new calendar.CalendarService(s,impl,async()=>{})}));
 assert.equal(again.duplicatePrevented,true);
 assert.equal(calls.filter(c=>c.method==='POST'&&c.url.endsWith('/me/events')).length,1);
});
test('external attendees are refused before anything is created',async()=>{
 const {calls,impl}=meetingFetch(); const s=meetingSession();
 await assert.rejects(withFetch(impl,()=>createMeeting(s,'Ext',{...meetingOptions,'--attendees':'someone@other.com'},{now,service:new calendar.CalendarService(s,impl,async()=>{})})),e=>e.code==='external_attendee_refused');
 assert.equal(calls.filter(c=>c.method==='POST').length,0);
});
test('a server error on create is ambiguous and blocks automatic retry; a 400 is a clean refusal',async()=>{
 const s=meetingSession();
 const err=meetingFetch({create:()=>new Response('',{status:503})});
 await assert.rejects(withFetch(err.impl,()=>createMeeting(s,'Flaky',meetingOptions,{now,service:new calendar.CalendarService(s,err.impl,async()=>{})})),e=>e.code==='send_result_ambiguous');
 await assert.rejects(withFetch(err.impl,()=>createMeeting(s,'Flaky',meetingOptions,{now,service:new calendar.CalendarService(s,err.impl,async()=>{})})),e=>e.code==='prior_attempt_ambiguous');
 const bad=meetingFetch({create:()=>new Response('',{status:400})});
 await assert.rejects(withFetch(bad.impl,()=>createMeeting(s,'Rejected',meetingOptions,{now,service:new calendar.CalendarService(s,bad.impl,async()=>{})})),e=>e.code==='meeting_rejected');
});
test('meeting CLI flags',()=>{
 assert.deepEqual(argumentsFor(['meeting','Sync','--start','2026-11-03T15:00','--attendees','a@x.com','--force']).options,{'--start':'2026-11-03T15:00','--attendees':'a@x.com','--force':true});
 code(()=>argumentsFor(['meeting-preview','Sync','--force']),'invalid_arguments');
 code(()=>argumentsFor(['send','a@x.com','hi','--start','x']),'invalid_arguments');
});
