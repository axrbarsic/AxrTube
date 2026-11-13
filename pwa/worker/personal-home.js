// Native AxrTube's authenticated browse path. No copied OAuth client secrets,
// cookies, watch-history writes, media changes or locally fabricated ranking.
export async function personalHomeResponse(token,u,parse){
  const headers={'content-type':'application/json; charset=utf-8','cache-control':'no-store','referrer-policy':'no-referrer','x-content-type-options':'nosniff'};
  const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
  const continuation=u.searchParams.get('continuation')||'',visitor=u.searchParams.get('visitor')||'',rawLanguage=u.searchParams.get('lang')||'en';
  if(continuation.length>16000||visitor.length>4096||!/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$/.test(rawLanguage))return reply({code:'PERSONAL_HOME_INVALID'},400);
  const version='7.20260311.12.00',language=['ru','en','es','uk','ht'].includes(rawLanguage)?rawLanguage:'en';
  try{
    const r=await fetch('https://youtubei.googleapis.com/youtubei/v1/browse',{method:'POST',redirect:'manual',signal:AbortSignal.timeout(12000),headers:{'content-type':'application/json','authorization':'Bearer '+token,'x-youtube-client-name':'7','x-youtube-client-version':version},body:JSON.stringify({context:{client:{clientName:'TVHTML5',clientVersion:version,hl:language,gl:'US',...(visitor?{visitorData:visitor}:{})}},...(continuation?{continuation}:{browseId:'FEwhat_to_watch'})})});
    if([400,401,403].includes(r.status)){
      // Return only a known Google error enum, never the provider body/token.
      const allowed=new Set(['ACCESS_TOKEN_SCOPE_INSUFFICIENT','SERVICE_DISABLED','API_KEY_SERVICE_BLOCKED','CREDENTIALS_MISSING','UNAUTHENTICATED','PERMISSION_DENIED','ACCESS_NOT_CONFIGURED','CONSUMER_INVALID']);let reason=null;
      try{const error=(await r.json()).error;for(const item of error?.details||[])if(allowed.has(item.reason)){reason=item.reason;break}if(!reason&&error?.errors?.some(e=>e.reason==='insufficientPermissions'))reason='ACCESS_TOKEN_SCOPE_INSUFFICIENT';if(!reason&&allowed.has(error?.status))reason=error.status}catch{}
      return reply({code:'PERSONAL_HOME_AUTH_UNSUPPORTED',providerStatus:r.status,providerReason:reason},409);
    }
    if(!r.ok){await r.body?.cancel();return reply({code:'PERSONAL_HOME_UNAVAILABLE'},502)}
    const reader=r.body?.getReader();if(!reader)throw Error('Missing body');const chunks=[];let size=0;
    try{for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>8_000_000)throw Error('Response too large');chunks.push(value)}}finally{await reader.cancel()}
    const bytes=new Uint8Array(size);let at=0;for(const chunk of chunks){bytes.set(chunk,at);at+=chunk.length}const data=JSON.parse(new TextDecoder().decode(bytes));
    if(data.error)return reply({code:'PERSONAL_HOME_UNAVAILABLE'},502);
    if(data.responseContext?.mainAppWebResponseContext?.loggedOut===true)return reply({code:'PERSONAL_HOME_AUTH_UNSUPPORTED'},409);
    const result=parse(data);if(!result.videos.length&&!result.continuation)return reply({code:'PERSONAL_HOME_EMPTY'},422);
    const nextVisitor=data.responseContext?.visitorData;
    return reply({videos:result.videos,continuation:result.continuation,visitor:typeof nextVisitor==='string'&&nextVisitor.length<=4096?nextVisitor:null,source:'youtube-personal-home',personalized:true});
  }catch{return reply({code:'PERSONAL_HOME_UNAVAILABLE'},502)}
}
