// Guest catalog mirrors the native WEB InnerTube path. Never returns ad renderers.
const catalogText = value => typeof value==='string'?value:value?.simpleText||value?.content||value?.runs?.map(r=>r.text||'').join('')||'';
const videoID = value => /^[a-zA-Z0-9_-]{11}$/.test(value||'');
function catalogThumb(raw,id) {
  try {const u=new URL(raw);if(u.protocol==='https:'&&(u.hostname==='i.ytimg.com'||u.hostname.endsWith('.ytimg.com')))return u.href;}catch{}
  return 'https://i.ytimg.com/vi/'+id+'/hqdefault.jpg';
}
export function parseCatalog(data) {
  const videos=[],seen=new Set();let continuation=null,visited=0;
  const blocked=/^(adSlotRenderer|adRenderer|promoted.*Renderer|displayAdRenderer|adBreakServiceRenderer|inFeedAdLayoutRenderer|searchPyvRenderer)$/;
  function add(r,short=false,tile=false) {
    // WEB lockupViewModel and TV tileRenderer use different contentType enums.
    // Do not treat a WEB video as an unsupported TV tile.
    if(!tile&&r.contentType?.startsWith('LOCKUP_')&&r.contentType!=='LOCKUP_CONTENT_TYPE_VIDEO')return;
    if(tile){
      if(!['TILE_CONTENT_TYPE_VIDEO','TILE_CONTENT_TYPE_REEL'].includes(r.contentType))return;
      const command=r.onSelectCommand?.innertubeCommand||r.onSelectCommand||r.navigationEndpoint||{};
      const metadata=r.metadata?.tileMetadataRenderer||{},items=metadata.lines?.[0]?.lineRenderer?.items||[];
      const byline=items[0]?.lineItemRenderer;
      r={...r,videoId:command.watchEndpoint?.videoId||command.reelWatchEndpoint?.videoId||r.contentId,title:metadata.title,ownerText:byline?.text,thumbnail:r.header?.tileHeaderRenderer?.thumbnail||r.thumbnail,lengthText:r.header?.tileHeaderRenderer?.thumbnailOverlays?.find(t=>t.thumbnailOverlayTimeStatusRenderer)?.thumbnailOverlayTimeStatusRenderer?.text,navigationEndpoint:command};
      short||=r.contentType==='TILE_CONTENT_TYPE_REEL';
    }
    const id=r.videoId||r.contentId||r.onTap?.innertubeCommand?.reelWatchEndpoint?.videoId;
    if(!videoID(id)||seen.has(id))return;
    const model=r.metadata?.lockupMetadataViewModel;
    const parts=model?.metadata?.contentMetadataViewModel?.metadataRows||[];
    const byline=r.ownerText||r.longBylineText||r.shortBylineText;
    const title=catalogText(r.title)||catalogText(model?.title)||catalogText(r.overlayMetadata?.primaryText);
    if(!title)return;
    const channelId=byline?.runs?.find(t=>t.navigationEndpoint?.browseEndpoint?.browseId)?.navigationEndpoint.browseEndpoint.browseId;
    const thumbs=r.thumbnail?.thumbnails||r.contentImage?.thumbnailViewModel?.image?.sources||r.thumbnail?.sources||[];
    seen.add(id);videos.push({id,title:title.slice(0,500),channel:catalogText(byline)||catalogText(parts[0]?.metadataParts?.[0]?.text),
      channelId:/^UC[\w-]{22}$/.test(channelId||'')?channelId:null,
      thumbnail:catalogThumb(thumbs.at(-1)?.url,id),duration:catalogText(r.lengthText)||catalogText(r.thumbnailOverlays?.find(t=>t.thumbnailOverlayTimeStatusRenderer)?.thumbnailOverlayTimeStatusRenderer?.text),
      views:catalogText(r.shortViewCountText)||catalogText(r.viewCountText)||catalogText(r.overlayMetadata?.secondaryText),published:catalogText(r.publishedTimeText),isShort:short||!!r.navigationEndpoint?.reelWatchEndpoint||!!r.onTap?.innertubeCommand?.reelWatchEndpoint||!!r.thumbnailOverlays?.some(t=>t.thumbnailOverlayTimeStatusRenderer?.style==='SHORTS')});
  }
  function walk(node,depth=0) {
    if(!node||typeof node!=='object'||depth>45||++visited>30000)return;
    if(Array.isArray(node)){for(const item of node)walk(item,depth+1);return;}
    if(Object.keys(node).some(k=>blocked.test(k)))return;
    for(const key of ['videoRenderer','compactVideoRenderer','gridVideoRenderer','reelItemRenderer','shortsLockupViewModel','lockupViewModel','tileRenderer']){
      if(key==='tileRenderer'&&node[key]&&!['TILE_CONTENT_TYPE_VIDEO','TILE_CONTENT_TYPE_REEL'].includes(node[key].contentType))return;
      if(node[key]){add(node[key],key==='reelItemRenderer'||key==='shortsLockupViewModel',key==='tileRenderer');return;}
    }
    const next=node.continuationItemRenderer?.continuationEndpoint?.continuationCommand?.token;
    if(typeof next==='string'&&next.length<=16000)continuation=next;
    const tvNext=node.continuations?.[0]?.nextContinuationData?.continuation;if(typeof tvNext==='string'&&tvNext.length<=16000)continuation=tvNext;
    for(const value of Object.values(node))walk(value,depth+1);
  }
  walk(data);
  return {videos:videos.slice(0,80),continuation};
}
async function catalogPost(endpoint,body) {
  const r=await fetch('https://www.youtube.com/youtubei/v1/'+endpoint+'?prettyPrint=false',{
    method:'POST',headers:{'content-type':'application/json',origin:'https://www.youtube.com','x-youtube-client-name':'1','x-youtube-client-version':'2.20260206.01.00'},
    body:JSON.stringify({context:{client:{clientName:'WEB',clientVersion:'2.20260206.01.00',hl:'ru',gl:'US'}},...body}),
    redirect:'manual',signal:AbortSignal.timeout(12000)
  });
  if(!r.ok)throw Error('CATALOG_HTTP_'+r.status);
  const text=await r.text();if(text.length>8000000)throw Error('CATALOG_TOO_LARGE');
  const data=JSON.parse(text);if(data.error)throw Error('CATALOG_REJECTED');return data;
}
export async function catalogResponse(u) {
  const q=(u.searchParams.get('q')||'').trim();
  const feed=u.searchParams.get('feed')||'search';
  const continuation=u.searchParams.get('continuation');
  if(q.length>200||(continuation&&continuation.length>16000))return {status:400,body:{error:'Слишком длинный запрос'}};
  const next=continuation?{continuation}:null;
  try {
    let data;
    if(feed==='home')data=await catalogPost('browse',next||{browseId:'FEwhat_to_watch'});
    else if(feed==='channel'){
      const id=u.searchParams.get('channel');
      if(!/^UC[\w-]{22}$/.test(id||''))return {status:400,body:{error:'Некорректный канал'}};
      data=await catalogPost('browse',next||{browseId:id,params:'EgZ2aWRlb3PyBgQKAjoA'});
    }else if(feed==='related'){
      const id=u.searchParams.get('id');if(!videoID(id))return {status:400,body:{error:'Некорректный ролик'}};
      const response=await catalogPost('next',next||{videoId:id});
      data=response.contents?.twoColumnWatchNextResults?.secondaryResults||response.onResponseReceivedEndpoints||{};
    }else if(feed==='shorts'||feed==='search'){
      if(feed==='search'&&!q&&!next)return {status:400,body:{error:'Введите поисковый запрос'}};
      data=await catalogPost('search',next||{query:feed==='shorts'?'#shorts':q,...(feed==='shorts'?{params:'EgIYAQ=='}:{})});
    }else return {status:400,body:{error:'Неизвестная лента'}};
    const result=parseCatalog(data);
    if(feed==='related')result.videos=result.videos.filter(v=>v.id!==u.searchParams.get('id'));
    if(feed==='shorts')result.videos=result.videos.filter(v=>v.isShort||(/^\d{1,2}:\d{2}$/.test(v.duration)&&Number(v.duration.split(':')[0])<3));
    return {status:200,body:{...result,feed,guest:true}};
  }catch(error){return {status:502,body:{error:'YouTube временно не отдал ленту. Попробуйте ещё раз.',code:/^CATALOG_[A-Z_0-9]+$/.test(error.message)?error.message:'CATALOG_UNAVAILABLE'}};}
}
export async function suggestionResponse(u) {
  const q=(u.searchParams.get('q')||'').trim();if(!q||q.length>200)return {suggestions:[]};
  try{
    const r=await fetch('https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&callback=&q='+encodeURIComponent(q),{redirect:'manual',signal:AbortSignal.timeout(5000)});
    if(!r.ok)return {suggestions:[]};const text=await r.text();if(text.length>100000)return {suggestions:[]};
    const data=JSON.parse(text.slice(text.indexOf('['),text.lastIndexOf(']')+1));
    return {suggestions:(data[1]||[]).map(s=>Array.isArray(s)?s[0]:s).filter(s=>typeof s==='string').slice(0,8)};
  }catch{return {suggestions:[]};}
}
const sponsorCache=new Map();
export function cleanSponsorSegments(data) {
  return (Array.isArray(data)?data:[]).filter(s=>['sponsor','selfpromo'].includes(s.category)&&Array.isArray(s.segment)&&s.segment.length===2&&s.segment.every(Number.isFinite)&&s.segment[0]>=0&&s.segment[1]>s.segment[0]&&s.segment[1]<604800)
    .slice(0,100).map(s=>({start:s.segment[0],end:s.segment[1],category:s.category})).sort((a,b)=>a.start-b.start);
}
export async function sponsorResponse(u) {
  const id=u.searchParams.get('id');if(!videoID(id))return {segments:[],available:false};
  const prior=sponsorCache.get(id);if(prior&&prior.expires>Date.now())return prior.body;
  try{
    const r=await fetch('https://sponsor.ajay.app/api/skipSegments?videoID='+id+'&categories='+encodeURIComponent('["sponsor","selfpromo"]'),{redirect:'manual',signal:AbortSignal.timeout(5000)});
    if(r.status!==404&&!r.ok)return {segments:[],available:false};
    const text=r.status===404?'[]':await r.text();if(text.length>200000)return {segments:[],available:false};
    const body={segments:cleanSponsorSegments(JSON.parse(text)),available:true};
    if(sponsorCache.size>=100)sponsorCache.delete(sponsorCache.keys().next().value);
    sponsorCache.set(id,{body,expires:Date.now()+600000});return body;
  }catch{return {segments:[],available:false};}
}
