'use strict';
// Explicitly authorized live test only. Uses harmless fixtures, sends to the given exact email.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {ChatSession,email}=require('../chat-session.cjs');
const {ChatService}=require('../chat-service.cjs');
const {SharePointService}=require('../sharepoint-service.cjs');
const {sendFile,sendText}=require('../teams-api.cjs');
async function main(){
 const [flag,receiver,directory,reportPath]=process.argv.slice(2);
 if(flag!=='--approved-receiver'||!receiver||!path.isAbsolute(directory||'')||!path.isAbsolute(reportPath||''))throw new Error('Usage: live-regression.cjs --approved-receiver exact-email absolute-fixture-directory absolute-report');
 email(receiver);
 const files=['txt','md','csv','json','html','png','jpg','gif','pdf','docx','xlsx','pptx','zip','wav','mp3','mp4'].map(ext=>'codex-api-test.'+ext).concat('codex-api-large-test.txt');
 for(const name of files)assert.ok(fs.statSync(path.join(directory,name)).isFile());
 const report={receiver,startedAt:new Date().toISOString(),checks:[],files:[]};
 const save=()=>{fs.writeFileSync(reportPath,JSON.stringify(report,null,2)+'\n',{mode:0o600});};
 const check=(name,detail={})=>{report.checks.push({name,passed:true,...detail});save();console.log(JSON.stringify({check:name,passed:true,...detail}));};
 const s=new ChatSession();
 try{
  await s.start();assert.equal(s.context,null);check('browser closed before API operations');
  const api=new ChatService(s),directoryApi=new SharePointService(s);
  const binding=await s.resolve(receiver);check('exact email and server membership');
  const people=await directoryApi.lookupName(binding.expectedName.split(' ')[0]);assert.ok(people.some(p=>p.email===receiver));check('directory name search');
  const {value}=await api.request(s.credentials.base+'?pageSize=100');assert.ok(Array.isArray(value.conversations));check('list chats',{count:value.conversations.length});
  const message='This is Codex, Furqan’s AI assistant. API-only messaging test.\n\n  Unicode: 日本語 😊 & < >\nhttps://example.com';
  let result=await sendText(s,receiver,message);assert.equal(result.verified,true);check('multiline Unicode and link message',{duplicatePrevented:result.duplicatePrevented});
  result=await sendText(s,receiver,message);assert.equal(result.duplicatePrevented,true);check('text duplicate prevention');
  for(const name of files){
   const started=Date.now();
   result=await sendFile(s,receiver,path.join(directory,name),{message:'This is Codex, Furqan’s AI assistant. API-only attachment test: '+name+'.'});
   assert.equal(result.verified,true);
   if(!result.duplicatePrevented){assert.equal(result.proof.uploadedBytesVerified,true);assert.equal(result.proof.recipientAccessVerified,true);assert.equal(result.proof.freshHistoryMatch,true);}
   assert.equal(s.context,null);
   const record={fileName:name,verified:true,duplicatePrevented:result.duplicatePrevented,elapsedMs:Date.now()-started};
   report.files.push(record);save();console.log(JSON.stringify(record));
  }
  result=await sendFile(s,receiver,path.join(directory,files.at(-1)),{message:'This is Codex, Furqan’s AI assistant. API-only attachment test: '+files.at(-1)+'.'});assert.equal(result.duplicatePrevented,true);check('file duplicate prevention');
  const read=await api.history(binding,{limit:110,scan:250});assert.ok(read.messages.length>0);check('recent history and pagination',{count:read.messages.length,scanned:read.scanned,olderHistoryAvailable:read.olderHistoryAvailable});
  const search=await api.history(binding,{query:'api-only messaging test',limit:2,scan:250});assert.ok(search.messages.length>=1);check('case insensitive message search');
  assert.ok((await api.history(binding,{query:'codex-api-test.pdf',caseSensitive:true,limit:1,scan:250})).messages.length===1);check('attachment filename search');
  assert.equal((await api.history(binding,{query:'__codex_missing_search_8746382__',scan:20})).messages.length,0);check('missing search and scan limit');
  assert.equal((await api.history(binding,{query:'Codex',after:Date.parse('2099-01-01'),scan:20})).messages.length,0);check('date filter');
  await api.verify(binding);check('final server membership');
  report.completedAt=new Date().toISOString();report.passed=true;save();
 }catch(e){report.passed=false;report.failure={code:e.code||'assertion',message:e.code?e.message:String(e.message).slice(0,300)};save();throw e;}
 finally{await s.close();}
}
main().catch(e=>{console.error(JSON.stringify({error:e.code||'test_failed',message:e.message}));process.exitCode=1;});
