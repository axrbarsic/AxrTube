// YouTube discussion through the official Data API v3 with the signed-in user's
// own OAuth token. Plain text only; no cookies, scraping or ad renderers.
const commentsAPI='https://www.googleapis.com/youtube/v3/';
const commentsHeaders={'content-type':'application/json; charset=utf-8','cache-control':'no-store','x-content-type-options':'nosniff','referrer-policy':'no-referrer'};
const commentsJSON=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:commentsHeaders});
const commentVideoID=v=>/^[\w-]{11}$/.test(v||'');
const commentPageToken=v=>!v||/^[\w-]{1,400}$/.test(v);
async function commentsCall(token,method,endpoint,params,body){
  const url=new URL(commentsAPI+endpoint);
  for(const [k,v]of Object.entries(params||{}))if(v!==undefined&&v!=='')url.searchParams.set(k,v);
  const r=await fetch(url,{method,redirect:'manual',signal:AbortSignal.timeout(12000),
    headers:{authorization:'Bearer '+token,accept:'application/json',...(body?{'content-type':'application/json'}:{})},
    ...(body?{body:JSON.stringify(body)}:{})});
  const text=await r.text();if(text.length>4_000_000)throw Object.assign(Error('COMMENTS_TOO_LARGE'),{status:502});
  let data={};try{data=JSON.parse(text)}catch{}
  if(!r.ok){
    // Only a known Google reason enum leaves the server, never the provider body.
    const reason=data.error?.errors?.[0]?.reason||data.error?.status||'';
    throw Object.assign(Error('COMMENTS_HTTP_'+r.status),{status:r.status,reason:/^[A-Za-z_]{1,60}$/.test(reason)?reason:''});
  }
  return data;
}
export function cleanComment(c,parentId=null){
  const s=c?.snippet||{};
  const text=typeof s.textOriginal==='string'?s.textOriginal:typeof s.textDisplay==='string'?s.textDisplay:'';
  const avatar=typeof s.authorProfileImageUrl==='string'&&/^https:\/\/yt\d?\.(ggpht|googleusercontent)\.com\//.test(s.authorProfileImageUrl)?s.authorProfileImageUrl:'';
  return {id:String(c?.id||''),parentId,author:String(s.authorDisplayName||''),authorChannelId:String(s.authorChannelId?.value||''),avatar,
    text:text.slice(0,20000),likes:Number(s.likeCount)||0,published:String(s.publishedAt||''),edited:!!s.updatedAt&&s.updatedAt!==s.publishedAt};
}
export function cleanThread(t){
  const top=cleanComment(t?.snippet?.topLevelComment);
  return {...top,replyCount:Number(t?.snippet?.totalReplyCount)||0,canReply:t?.snippet?.canReply!==false,
    replies:(t?.replies?.comments||[]).map(c=>cleanComment(c,top.id)).reverse()};
}
function commentsError(error){
  if(error.status===401)return commentsJSON({code:'SESSION_EXPIRED',error:'Срок входа истёк. Войдите снова.'},401);
  if(error.status===403&&error.reason==='commentsDisabled')return commentsJSON({code:'COMMENTS_DISABLED',error:'Автор отключил комментарии к этому ролику.'},403);
  if(error.status===403&&/insufficientPermissions|ACCESS_TOKEN_SCOPE_INSUFFICIENT|PERMISSION_DENIED/i.test(error.reason))return commentsJSON({code:'COMMENTS_SCOPE',error:'Нужно разрешение на комментарии. Войдите заново.'},403);
  if(error.status===403&&/quota/i.test(error.reason))return commentsJSON({code:'COMMENTS_QUOTA',error:'Дневной лимит YouTube API исчерпан. Попробуйте завтра.'},429);
  if(error.status===404)return commentsJSON({code:'COMMENTS_NOT_FOUND',error:'Ролик или комментарий не найден.'},404);
  return commentsJSON({code:'COMMENTS_UNAVAILABLE',error:'YouTube не отдал обсуждение. Попробуйте ещё раз.'},502);
}
// path is under /api/account/. Returns null for paths it does not own.
export async function commentsResponse(path,token,request,u){
  try{
    if(path==='/api/account/comments'&&request.method==='GET'){
      const id=u.searchParams.get('id'),order=u.searchParams.get('order')==='time'?'time':'relevance',page=u.searchParams.get('page')||'';
      if(!commentVideoID(id)||!commentPageToken(page))return commentsJSON({error:'Некорректный запрос'},400);
      const [threads,video]=await Promise.all([
        commentsCall(token,'GET','commentThreads',{part:'snippet,replies',videoId:id,order,maxResults:'50',textFormat:'plainText',pageToken:page}),
        page?null:commentsCall(token,'GET','videos',{part:'statistics',id,fields:'items(statistics(commentCount))'}).catch(()=>null)]);
      return commentsJSON({items:(threads.items||[]).map(cleanThread).filter(t=>t.id),nextPage:threads.nextPageToken||null,
        total:video?Number(video.items?.[0]?.statistics?.commentCount)||null:null});
    }
    if(path==='/api/account/replies'&&request.method==='GET'){
      const parent=u.searchParams.get('parent'),page=u.searchParams.get('page')||'';
      if(!/^[\w.-]{8,200}$/.test(parent||'')||!commentPageToken(page))return commentsJSON({error:'Некорректный запрос'},400);
      const d=await commentsCall(token,'GET','comments',{part:'snippet',parentId:parent,maxResults:'100',textFormat:'plainText',pageToken:page});
      return commentsJSON({items:(d.items||[]).map(c=>cleanComment(c,parent)).filter(c=>c.id),nextPage:d.nextPageToken||null});
    }
    if(path==='/api/account/comment'&&request.method==='POST'){
      const raw=await request.text();if(raw.length>40000)return commentsJSON({error:'Слишком длинный комментарий'},413);
      let body;try{body=JSON.parse(raw)}catch{return commentsJSON({error:'Некорректный запрос'},400)}
      const text=typeof body.text==='string'?body.text.trim():'';
      if(!text||text.length>10000)return commentsJSON({error:'Комментарий пустой или длиннее 10 000 символов'},400);
      if(body.parent){
        if(!/^[\w.-]{8,200}$/.test(body.parent))return commentsJSON({error:'Некорректный запрос'},400);
        const d=await commentsCall(token,'POST','comments',{part:'snippet'},{snippet:{parentId:body.parent,textOriginal:text}});
        return commentsJSON({item:cleanComment(d,body.parent)});
      }
      if(!commentVideoID(body.video))return commentsJSON({error:'Некорректный ролик'},400);
      const d=await commentsCall(token,'POST','commentThreads',{part:'snippet'},{snippet:{videoId:body.video,topLevelComment:{snippet:{textOriginal:text}}}});
      return commentsJSON({item:cleanThread(d)});
    }
    return null;
  }catch(error){return commentsError(error)}
}
