import test from 'node:test';
import assert from 'node:assert/strict';
import {createHandler, validRedirect, tokenFields} from '../src/index.js';
const id = 'synthetic.apps.googleusercontent.com';
const secret = 'SYNTHETIC_SERVER_ONLY_VALUE';
const env = () => ({GOOGLE_CLIENT_ID: id, GOOGLE_CLIENT_SECRET: secret, AUTH_RATE_LIMITER: {limit: async () => ({success: true})}});
const fields = () => new URLSearchParams({client_id:id, grant_type:'authorization_code', code:'synthetic-code', code_verifier:'x'.repeat(64), redirect_uri:'http://127.0.0.1:54321/'});
const request = (form=fields(), extra={}) => new Request('https://auth.example.com/v1/token', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded','CF-Connecting-IP':'192.0.2.1',...extra},body:form.toString()});
const tokens = {access_token:'synthetic-access', refresh_token:'synthetic-refresh',expires_in:3600,scope:'https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly',token_type:'Bearer'};

test('authorization code and PKCE reach only fixed Google token endpoint; no secret leaks', async () => {
 let calls=0;
 const handle=createHandler(async (url, options) => {
  calls++;assert.equal(url,'https://oauth2.googleapis.com/token');assert.equal(options.redirect,'error');
  const form=new URLSearchParams(options.body);
  assert.equal(form.get('client_secret'),secret);assert.equal(form.get('code_verifier'),'x'.repeat(64));
  return Response.json({...tokens,client_secret:secret,debug:'private diagnostic',id_token:'not-needed'});
 });
 const result=await handle(request(),env());const body=await result.text();
 assert.equal(result.status,200);assert.deepEqual(JSON.parse(body),tokens);assert(!body.includes(secret));assert(!body.includes('private diagnostic'));
 assert.equal(result.headers.get('Cache-Control'),'no-store');assert.equal(calls,1);
});
test('refresh keeps token owner proof and does not require a browser session',async()=>{
 const form=new URLSearchParams({client_id:id,grant_type:'refresh_token',refresh_token:'private-refresh'});
 const result=await createHandler(async(_,opts)=>{assert.equal(new URLSearchParams(opts.body).get('refresh_token'),'private-refresh');return Response.json({access_token:'next',expires_in:3600,scope:tokens.scope});})(request(form),env());
 assert.equal(result.status,200);assert.deepEqual(await result.json(),{access_token:'next',expires_in:3600,scope:tokens.scope});
});
test('reject unsupported grants, other client IDs, duplicates and caller-supplied secret/URLs before Google',async()=>{
 for(const mutate of [f=>f.set('grant_type','client_credentials'),f=>f.set('client_id','foreign'),f=>f.append('code','duplicate'),f=>f.set('client_secret','caller-value'),f=>f.set('token_endpoint','https://evil.example/')]){
  const form=fields();mutate(form);assert.equal(tokenFields(form,id),null);
  const r=await createHandler(()=>{throw new Error('must not call');})(request(form),env());assert.equal(r.status,400);
 }
});
test('allow only canonical IPv4 loopback callbacks, never open redirects or network targets',()=>{
 assert(validRedirect('http://127.0.0.1:54321/'));
 for(const value of ['https://evil.example/','http://localhost:5000/','http://127.0.0.1:80/','http://127.0.0.1:5000/?next=x','http://127.0.0.1:5000/callback','http://127.0.0.1.evil.example:5000/','http://user@127.0.0.1:5000/','http://2130706433:5000/'])assert(!validRedirect(value),value);
});
test('require PKCE proof and nonempty bounded refresh token',()=>{
 const f=fields();f.set('code_verifier','short');assert.equal(tokenFields(f,id),null);
 for(const value of ['', 'x'.repeat(8193), 'line\nline']) assert.equal(tokenFields(new URLSearchParams({client_id:id,grant_type:'refresh_token',refresh_token:value}),id),null);
});
test('fail closed if server configuration, edge identity, or rate limiter is absent',async()=>{
 const h=createHandler(()=>{throw new Error('must not call');});
 for(const key of ['GOOGLE_CLIENT_ID','GOOGLE_CLIENT_SECRET','AUTH_RATE_LIMITER']) {const e=env();delete e[key];assert.equal((await h(request(),e)).status,503);}
 const e=env();e.AUTH_RATE_LIMITER.limit=async()=>({success:false});const r=await h(request(),e);assert.equal(r.status,429);assert.equal(r.headers.get('Retry-After'),'60');
 const missing=request();missing.headers.delete('CF-Connecting-IP');assert.equal((await h(missing,env())).status,503);
});
test('reject browsers, GET, non-form bodies, and oversized bodies',async()=>{
 const h=createHandler(()=>{throw new Error('must not call');});
 assert.equal((await h(request(fields(),{Origin:'https://evil.example'}),env())).status,403);
 assert.equal((await h(request(fields(),{'Content-Type':'application/json'}),env())).status,415);
 assert.equal((await h(new Request('https://auth.example.com/v1/token'),env())).status,405);
 const large=request(new URLSearchParams({x:'x'.repeat(20000)}));assert.equal((await h(large,env())).status,400);
});
test('provider errors are sanitized; never return upstream diagnostics or credentials',async()=>{
 for(const [status,error,want] of [[400,'invalid_grant',401],[401,'invalid_client',503],[429,'rate_limit',429],[500,'error',502]]){
  const r=await createHandler(async()=>Response.json({error,error_description:secret},{status}))(request(),env());assert.equal(r.status,want);assert(!(await r.text()).includes(secret));
 }
 const r=await createHandler(async()=>{throw new Error(secret);})(request(),env());assert.equal(r.status,502);assert(!(await r.text()).includes(secret));
});
test('reject malformed, truncated, oversized and incomplete provider responses',async()=>{
 for(const response of [new Response('{'),Response.json({access_token:'x'}),Response.json({...tokens,refresh_token:''}),Response.json({...tokens,expires_in:-1}),new Response('x'.repeat(70000))]){
  const r=await createHandler(async()=>response)(request(),env());assert.equal(r.status,502);
 }
});
test('health only indicates readiness, with no registration or token fields',async()=>{
 const r=await createHandler()(new Request('https://auth.example.com/health'),env());assert.deepEqual(await r.json(),{service:'minutes-google-auth',ready:true});
});

test('require exactly the read-only Calendar scopes and never proxy broader grants',async()=>{
 for(const scope of [undefined,'https://www.googleapis.com/auth/calendar',tokens.scope+' https://www.googleapis.com/auth/drive.readonly',tokens.scope.split(' ')[0]]) {
  const result=await createHandler(async()=>Response.json({...tokens,scope}))(request(),env());
  assert.equal(result.status,403);assert(!('access_token' in await result.json()));
 }
});
