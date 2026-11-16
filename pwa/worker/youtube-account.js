// YouTube connection only. Does not replace Sites identity or its reserved routes.
const accountOrigin='https://axrtube.axrbarsic.workers.dev';
const accountScope='https://www.googleapis.com/auth/youtube.readonly';
// Write scope for the discussion tab (commentThreads/comments insert). The
// session field recommendationsAuthorized keeps its historical name.
const personalHomeScope='https://www.googleapis.com/auth/youtube.force-ssl';
const accountCookies={epoch:'__Host-axr-yt-epoch',pending:'__Host-axr-yt-pending',session:'__Host-axr-yt-session',refresh:'__Host-axr-yt-refresh'};
const rememberSeconds=180*86400;
const refreshCookieName=epoch=>/^[\w-]{43}$/.test(epoch||'')?accountCookies.refresh+'-'+epoch:accountCookies.refresh;
const accountHeaders={'cache-control':'no-store','referrer-policy':'no-referrer','x-content-type-options':'nosniff'};
const accountJSON=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{...accountHeaders,'content-type':'application/json'}});
const base64url=bytes=>btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
const from64=s=>Uint8Array.from(atob(s.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
const nonce=()=>base64url(crypto.getRandomValues(new Uint8Array(32)));
function accountConfigured(env){return env.GOOGLE_OAUTH_ENABLED==='true'&&/^[0-9]+-[\w-]+\.apps\.googleusercontent\.com$/.test(env.GOOGLE_OAUTH_CLIENT_ID||'')&&!!env.GOOGLE_OAUTH_CLIENT_SECRET&&/^[a-f0-9]{64}$/.test(env.GOOGLE_OAUTH_COOKIE_KEY||'');}
async function accountKey(env){return crypto.subtle.importKey('raw',Uint8Array.from(env.GOOGLE_OAUTH_COOKIE_KEY.match(/../g),s=>parseInt(s,16)),'AES-GCM',false,['encrypt','decrypt']);}
export async function sealAccount(env,kind,data){
  const iv=crypto.getRandomValues(new Uint8Array(12)),aad=new TextEncoder().encode(accountOrigin+':'+kind);
  const encrypted=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad},await accountKey(env),new TextEncoder().encode(JSON.stringify(data)));
  const value=base64url(iv)+'.'+base64url(new Uint8Array(encrypted));if(value.length>3800)throw Error('Cookie too large');return value;
}
export async function openAccount(env,kind,value){
  try{
    if(!value||value.length>3800||!/^[\w-]+\.[\w-]+$/.test(value))return null;
    const [iv,data]=value.split('.');const decoded=await crypto.subtle.decrypt({name:'AES-GCM',iv:from64(iv),additionalData:new TextEncoder().encode(accountOrigin+':'+kind)},await accountKey(env),from64(data));
    const result=JSON.parse(new TextDecoder().decode(decoded));return Number.isFinite(result.expires)&&result.expires>Date.now()?result:null;
  }catch{return null;}
}
function cookie(name,value,age){return name+'='+value+'; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age='+age;}
function cookieValues(request){const values={};for(const part of(request.headers.get('cookie')||'').split(';')){const at=part.indexOf('=');if(at>0)values[part.slice(0,at).trim()]=part.slice(at+1).trim();}return values;}
function accountRedirect(path,cookies=[]){const h=new Headers({...accountHeaders,location:path});for(const c of cookies)h.append('set-cookie',c);return new Response(null,{status:303,headers:h});}
function sameOrigin(request){return request.headers.get('origin')===accountOrigin&&(!request.headers.has('sec-fetch-site')||request.headers.get('sec-fetch-site')==='same-origin');}
async function googleData(token,endpoint,params){
  const url=new URL('https://www.googleapis.com/youtube/v3/'+endpoint);for(const [k,v]of Object.entries(params))url.searchParams.set(k,v);
  const r=await fetch(url,{headers:{authorization:'Bearer '+token},redirect:'manual',signal:AbortSignal.timeout(10000)});
  if(!r.ok)throw Object.assign(Error('YouTube API unavailable'),{status:r.status});
  const text=await r.text();if(text.length>2000000)throw Error('API response too large');return JSON.parse(text);
}
// Bounded subscription batches, not YouTube's unavailable recommendation feed.
// No shared cache: every response belongs only to this encrypted user session.
async function subscriptionFeed(token,page,hideShorts,catalog){
  const subscriptions=await googleData(token,'subscriptions',{part:'snippet',mine:'true',order:'alphabetical',maxResults:'6',pageToken:page,fields:'nextPageToken,items(snippet(title,resourceId(channelId)))'});
  const channels=(subscriptions.items||[]).slice(0,6).map(i=>({id:i.snippet?.resourceId?.channelId,name:i.snippet?.title||'Канал'})).filter(c=>/^UC[\w-]{22}$/.test(c.id||''));
  if(!channels.length)return {videos:[],channels:[],nextPage:subscriptions.nextPageToken||null,partial:false};
  if(hideShorts){
    // Data API has no reliable isShort flag. Read the public Videos tab instead
    // of guessing from duration. Never pass the OAuth token to InnerTube.
    if(!catalog)throw Error('Videos catalog unavailable');let failed=0;
    const results=await Promise.all(channels.map(async c=>{try{const url=new URL('/api/catalog',accountOrigin);url.searchParams.set('feed','channel');url.searchParams.set('channel',c.id);const r=await catalog(url);if(r.status!==200)throw Error('Channel unavailable');return (r.body.videos||[]).filter(v=>!v.isShort).slice(0,5).map(v=>({...v,channel:c.name,channelId:c.id}))}catch{failed++;return []}}));
    if(failed===channels.length)throw Error('Videos catalog unavailable');const seen=new Set();
    return {videos:results.flat().filter(v=>{if(seen.has(v.id))return false;seen.add(v.id);return true}),channels,nextPage:subscriptions.nextPageToken||null,partial:failed>0,videosOnly:true};
  }
  const details=await googleData(token,'channels',{part:'contentDetails',id:channels.map(c=>c.id).join(','),fields:'items(id,contentDetails/relatedPlaylists/uploads)'});
  const uploads=new Map((details.items||[]).map(c=>[c.id,c.contentDetails?.relatedPlaylists?.uploads]));
  let failed=0;
  const batches=await Promise.all(channels.map(async c=>{
    const playlist=uploads.get(c.id);if(!/^[\w-]{2,100}$/.test(playlist||'')){failed++;return []}
    try{
      const d=await googleData(token,'playlistItems',{part:'snippet,contentDetails',playlistId:playlist,maxResults:'5',fields:'items(snippet(title),contentDetails(videoId,videoPublishedAt))'});
      return (d.items||[]).slice(0,5).map(i=>({id:i.contentDetails?.videoId,title:i.snippet?.title||'Видео',channel:c.name,channelId:c.id,publishedAt:i.contentDetails?.videoPublishedAt})).filter(v=>/^[\w-]{11}$/.test(v.id||'')&&Number.isFinite(Date.parse(v.publishedAt)));
    }catch(error){if(error.status===401)throw error;failed++;return []}
  }));
  if(failed===channels.length)throw Error('Subscription videos unavailable');
  const seen=new Set();const videos=batches.flat().sort((a,b)=>Date.parse(b.publishedAt)-Date.parse(a.publishedAt)).filter(v=>{if(seen.has(v.id))return false;seen.add(v.id);return true});
  return {videos,channels,nextPage:subscriptions.nextPageToken||null,partial:failed>0};
}
// Only encrypted, purpose-bound HttpOnly cookies carry credentials. Never
// expose refresh/access tokens to UI code, storage, JSON or diagnostics.
const accountRefreshes=new Map();
export async function youtubeAccountResponse(request,env={},catalog=null,personalHome=null,comments=null){
  const u=new URL(request.url);
  const commentPost=request.method==='POST'&&u.pathname==='/api/account/comment';
  if(!u.pathname.startsWith('/api/account')||!accountConfigured(env)||u.origin!==accountOrigin||(!['GET','HEAD'].includes(request.method)&&!commentPost))return youtubeAccountRoutes(request,env,catalog,personalHome,comments);
  if(commentPost&&!sameOrigin(request))return accountJSON({error:'Origin rejected'},403);
  const values=cookieValues(request),epoch=values[accountCookies.epoch];
  const session=await openAccount(env,'session',values[accountCookies.session]);
  if(session&&session.epoch===epoch&&session.expires>Date.now()+30000){const response=await youtubeAccountRoutes(commentPost?request.clone():request,env,catalog,personalHome,comments);if(response.status!==401)return response;}
  const rememberedValue=values[refreshCookieName(epoch)]||values[accountCookies.refresh];
  const remembered=await openAccount(env,'refresh',rememberedValue);
  if(!epoch||remembered?.epoch!==epoch)return youtubeAccountRoutes(request,env,catalog,personalHome,comments);
  try{
    const key=rememberedValue;let pending=accountRefreshes.get(key);
    if(!pending){
      if(accountRefreshes.size>=100)return accountJSON({code:'ACCOUNT_RETRY',error:'Повторите проверку аккаунта.'},503);
      pending=(async()=>{
        const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:env.GOOGLE_OAUTH_CLIENT_ID,client_secret:env.GOOGLE_OAUTH_CLIENT_SECRET,refresh_token:remembered.token,grant_type:'refresh_token'}),redirect:'manual',signal:AbortSignal.timeout(12000)});
        const data=await r.json();if(!r.ok)throw Object.assign(Error('Refresh failed'),{revoked:data.error==='invalid_grant'});
        if(data.token_type?.toLowerCase()!=='bearer'||typeof data.access_token!=='string'||data.access_token.length<16||data.access_token.length>2500||!Number.isFinite(Number(data.expires_in))||Number(data.expires_in)<=0)throw Error('Invalid refresh response');
        const scopes=typeof data.scope==='string'?data.scope.split(/\s+/):null;
        if(scopes&&!scopes.includes(accountScope)&&!scopes.includes(personalHomeScope))throw Object.assign(Error('Scope revoked'),{revoked:true});
        const seconds=Math.min(3600,Math.floor(Number(data.expires_in)));
        const next={epoch,token:data.access_token,recommendationsAuthorized:scopes?scopes.includes(personalHomeScope):remembered.recommendationsAuthorized===true,expires:Date.now()+seconds*1000};
        const issued=[cookie(accountCookies.session,await sealAccount(env,'session',next),seconds)];
        if(typeof data.refresh_token==='string'&&data.refresh_token.length>=16&&data.refresh_token.length<=2000)issued.push(cookie(refreshCookieName(epoch),await sealAccount(env,'refresh',{...remembered,token:data.refresh_token}),Math.max(1,Math.floor((remembered.expires-Date.now())/1000))));
        return {next,issued};
      })();accountRefreshes.set(key,pending);pending.finally(()=>{if(accountRefreshes.get(key)===pending)accountRefreshes.delete(key)}).catch(()=>{});
    }
    const {next,issued}=await pending;
    const h=new Headers(request.headers);h.set('cookie',(h.get('cookie')||'').split(';').filter(c=>!c.trim().startsWith(accountCookies.session+'=')).join(';')+'; '+accountCookies.session+'='+await sealAccount(env,'session',next));
    const result=await youtubeAccountRoutes(new Request(request,{headers:h}),env,catalog,personalHome,comments);
    const response=new Response(result.body,result);for(const c of issued)response.headers.append('set-cookie',c);return response;
  }catch(error){
    if(error.revoked){const response=accountJSON({configured:true,signedIn:false,code:'SESSION_REVOKED',recommendationsAvailable:env.GOOGLE_OAUTH_PERSONAL_HOME_ENABLED==='true'},401);for(const name of new Set([refreshCookieName(epoch),accountCookies.refresh]))response.headers.append('set-cookie',cookie(name,'',0));return response}
    // A timeout or Google outage is NOT logout. Preserve all stored cookies.
    return accountJSON({code:'ACCOUNT_RETRY',error:'Повторите проверку аккаунта.'},503);
  }
}
async function youtubeAccountRoutes(request,env={},catalog=null,personalHome=null,comments=null){
  const u=new URL(request.url),path=u.pathname;
  if(!path.startsWith('/oauth/google/')&&!path.startsWith('/api/account'))return null;
  if(u.origin!==accountOrigin)return accountJSON({error:'Origin rejected'},403);
  if(!accountConfigured(env))return accountJSON({configured:false,signedIn:false,error:'Вход Google ещё настраивается'},503);
  const values=cookieValues(request),epoch=values[accountCookies.epoch];
  if(path==='/oauth/google/start'){
    if(request.method!=='POST')return accountJSON({error:'Method not allowed'},405);
    if(!sameOrigin(request))return accountJSON({error:'Origin rejected'},403);
    const recommendations=u.searchParams.get('recommendations')==='1'||(env.GOOGLE_OAUTH_PERSONAL_HOME_ENABLED==='true'&&u.searchParams.get('readonly')!=='1');
    if(recommendations&&env.GOOGLE_OAUTH_PERSONAL_HOME_ENABLED!=='true')return accountJSON({code:'PERSONAL_HOME_DISABLED'},503);
    // An upgrade keeps the current short-lived session valid if consent is
    // cancelled. Logout still rotates epoch and invalidates pending callbacks.
    const freshEpoch=/^[\w-]{43}$/.test(epoch||'')?epoch:nonce(),state=nonce(),verifier=nonce();
    const challenge=base64url(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
    const pending=await sealAccount(env,'pending',{epoch:freshEpoch,state,verifier,recommendations,expires:Date.now()+600000});
    const google=new URL('https://accounts.google.com/o/oauth2/v2/auth');
    for(const [k,v]of Object.entries({client_id:env.GOOGLE_OAUTH_CLIENT_ID,redirect_uri:accountOrigin+'/oauth/google/callback',response_type:'code',scope:recommendations?accountScope+' '+personalHomeScope:accountScope,state,code_challenge:challenge,code_challenge_method:'S256',access_type:'offline',prompt:'consent select_account'}))google.searchParams.set(k,v);
    return accountRedirect(google.href,[cookie(accountCookies.epoch,freshEpoch,rememberSeconds),cookie(accountCookies.pending,pending,600)]);
  }
  if(path==='/oauth/google/logout'){
    if(request.method!=='POST'||!sameOrigin(request))return accountJSON({error:'Origin rejected'},403);
    // Rotate the binding cookie. A late pre-logout callback can set only a stale
    // session cookie and cannot resurrect access against this new epoch.
    return accountRedirect('/#you',[cookie(accountCookies.epoch,nonce(),rememberSeconds),cookie(accountCookies.pending,'',0),cookie(accountCookies.session,'',0),cookie(accountCookies.refresh,'',0),cookie(refreshCookieName(epoch),'',0)]);
  }
  if(path==='/oauth/google/callback'){
    if(request.method!=='GET')return accountJSON({error:'Method not allowed'},405);
    const pending=await openAccount(env,'pending',values[accountCookies.pending]);
    if(!pending||!epoch||pending.epoch!==epoch||pending.state!==u.searchParams.get('state'))return accountJSON({error:'Вход не подтверждён в этом браузере. Вернитесь в AxrTube и начните вход заново.'},400);
    if(u.searchParams.has('error'))return accountRedirect('/?auth=denied#you',[cookie(accountCookies.pending,'',0)]);
    const code=u.searchParams.get('code');if(!code||code.length>4096)return accountJSON({error:'Некорректный ответ Google'},400);
    try{
      const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:env.GOOGLE_OAUTH_CLIENT_ID,client_secret:env.GOOGLE_OAUTH_CLIENT_SECRET,code,code_verifier:pending.verifier,grant_type:'authorization_code',redirect_uri:accountOrigin+'/oauth/google/callback'}),redirect:'manual',signal:AbortSignal.timeout(12000)});
      if(!r.ok)throw Error('Code exchange failed');const data=await r.json();
      const scopes=typeof data.scope==='string'?data.scope.split(/\s+/):[],recommendationsAuthorized=scopes.includes(personalHomeScope);
      if(data.token_type?.toLowerCase()!=='bearer'||typeof data.access_token!=='string'||data.access_token.length<16||data.access_token.length>2500||!Number.isFinite(Number(data.expires_in))||Number(data.expires_in)<=0||(!scopes.includes(accountScope)&&!recommendationsAuthorized))throw Error('Invalid token response');
      const seconds=Math.min(3600,Math.floor(Number(data.expires_in)));
      const binding=nonce(),session=await sealAccount(env,'session',{epoch:binding,token:data.access_token,recommendationsAuthorized,expires:Date.now()+seconds*1000});
      const issued=[cookie(accountCookies.epoch,binding,rememberSeconds),cookie(accountCookies.pending,'',0),cookie(accountCookies.session,session,seconds),cookie(refreshCookieName(epoch),'',0),cookie(accountCookies.refresh,'',0)];
      if(typeof data.refresh_token==='string'&&data.refresh_token.length>=16&&data.refresh_token.length<=2000){
        const age=Number.isFinite(Number(data.refresh_token_expires_in))?Math.max(1,Math.min(rememberSeconds,Math.floor(Number(data.refresh_token_expires_in)))):rememberSeconds;
        issued.push(cookie(refreshCookieName(binding),await sealAccount(env,'refresh',{epoch:binding,token:data.refresh_token,recommendationsAuthorized,expires:Date.now()+age*1000}),age));
      }
      return accountRedirect(pending.recommendations&&!recommendationsAuthorized?'/?auth=partial#you':'/#you',issued);
    }catch{return accountRedirect('/?auth=failed#you',[cookie(accountCookies.pending,'',0)]);}
  }
  const commentPost=request.method==='POST'&&path==='/api/account/comment';
  if(commentPost&&!sameOrigin(request))return accountJSON({error:'Origin rejected'},403);
  if(!['GET','HEAD'].includes(request.method)&&!commentPost)return accountJSON({error:'Method not allowed'},405);
  const session=await openAccount(env,'session',values[accountCookies.session]);
  if(!session||!epoch||session.epoch!==epoch)return accountJSON({configured:true,signedIn:false,recommendationsAvailable:env.GOOGLE_OAUTH_PERSONAL_HOME_ENABLED==='true'},path==='/api/account'?200:401);
  if(comments&&/^\/api\/account\/(comments|replies|comment)$/.test(path)){const r=await comments(path,session.token,request,u);if(r)return r}
  if(commentPost)return accountJSON({error:'Not found'},404);
  if(path==='/api/account/home')return personalHome?personalHome(session.token,u):accountJSON({code:'PERSONAL_HOME_UNAVAILABLE'},503);
  try{
    if(path==='/api/account'){
      const refresh=await openAccount(env,'refresh',values[refreshCookieName(epoch)]||values[accountCookies.refresh]);
      const d=await googleData(session.token,'channels',{part:'snippet',mine:'true',fields:'items(id,snippet(title))'});
      return accountJSON({configured:true,signedIn:true,name:d.items?.[0]?.snippet?.title||'Аккаунт YouTube',expiresAt:session.expires,remembered:refresh?.epoch===epoch,recommendationsAvailable:env.GOOGLE_OAUTH_PERSONAL_HOME_ENABLED==='true',recommendationsAuthorized:session.recommendationsAuthorized===true});
    }
    const page=u.searchParams.get('page')||'';if(page.length>2000)return accountJSON({error:'Invalid page'},400);
    if(path==='/api/account/feed')return accountJSON(await subscriptionFeed(session.token,page,u.searchParams.get('hideShorts')==='1',catalog));
    if(path==='/api/account/subscriptions'){
      const d=await googleData(session.token,'subscriptions',{part:'snippet',mine:'true',order:'alphabetical',maxResults:'50',pageToken:page,fields:'nextPageToken,items(snippet(title,resourceId(channelId)))'});
      return accountJSON({items:(d.items||[]).map(i=>({id:i.snippet?.resourceId?.channelId,name:i.snippet?.title})).filter(i=>/^UC[\w-]{22}$/.test(i.id||'')&&typeof i.name==='string'),nextPage:d.nextPageToken||null});
    }
    if(path==='/api/account/playlists'){
      const d=await googleData(session.token,'playlists',{part:'snippet,contentDetails',mine:'true',maxResults:'50',pageToken:page,fields:'nextPageToken,items(id,snippet(title),contentDetails(itemCount))'});
      return accountJSON({items:(d.items||[]).map(i=>({id:i.id,title:i.snippet?.title,count:i.contentDetails?.itemCount||0})),nextPage:d.nextPageToken||null});
    }
    if(path==='/api/account/playlist'){
      const id=u.searchParams.get('id');if(!/^[\w-]{2,100}$/.test(id||''))return accountJSON({error:'Invalid playlist'},400);
      const d=await googleData(session.token,'playlistItems',{part:'snippet',playlistId:id,maxResults:'50',pageToken:page,fields:'nextPageToken,items(snippet(title,videoOwnerChannelTitle,videoOwnerChannelId,resourceId(videoId)))'});
      return accountJSON({videos:(d.items||[]).map(i=>({id:i.snippet?.resourceId?.videoId,title:i.snippet?.title,channel:i.snippet?.videoOwnerChannelTitle||'',channelId:i.snippet?.videoOwnerChannelId||null})).filter(i=>/^[\w-]{11}$/.test(i.id||'')),nextPage:d.nextPageToken||null});
    }
    return accountJSON({error:'Not found'},404);
  }catch(error){return accountJSON({configured:true,signedIn:error.status!==401,error:error.status===401?'Срок входа истёк. Войдите снова.':'YouTube API пока недоступен. Попробуйте позже.',code:error.status===401?'SESSION_EXPIRED':'YOUTUBE_API_UNAVAILABLE'},error.status===401?401:502);}
}
