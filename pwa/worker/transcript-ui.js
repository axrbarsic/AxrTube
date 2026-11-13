export function transcriptTimestamp(value){const n=Math.max(0,Math.floor(value||0));return (n>=3600?Math.floor(n/3600)+':':'')+String(Math.floor(n/60)%60).padStart(2,'0')+':'+String(n%60).padStart(2,'0')}
export function transcriptExport(document,t=value=>value,markdown=false){
  const url='https://www.youtube.com/watch?v='+document.id;
  const escape=value=>markdown?String(value).replace(/[\\`*_{}\[\]<>#]/g,'\\$&'):String(value);
  const lines=[(markdown?'# ':'')+escape(document.title),escape(document.channel),url,t('Язык')+': '+escape(document.languageName||document.language),t('Длительность')+': '+transcriptTimestamp(document.duration),t('Создано')+': '+(document.generatedAt||''),'',t('Оглавление')];
  for(const [index,section]of document.sections.entries())lines.push(t('Раздел')+' '+(index+1)+', '+transcriptTimestamp(section.start));
  for(const [index,section]of document.sections.entries()){lines.push('',(markdown?'## ':'')+t('Раздел')+' '+(index+1)+', '+transcriptTimestamp(section.start));for(const paragraph of section.paragraphs)lines.push(transcriptTimestamp(paragraph.start)+'  '+escape(paragraph.text),'')}
  lines.push(t('Исходное видео')+': '+url);return lines.join('\n')+'\n';
}
export function createTranscriptUI({doc,win,t,language}){
  let dialog=null,controller=null,generation=0,previousFocus=null;const cache=new Map();
  const node=(tag,cls,text)=>{const el=doc.createElement(tag);if(cls)el.className=cls;if(text!==undefined)el.textContent=text;return el};
  const button=(text,action)=>{const b=node('button','pill',text);b.type='button';b.onclick=action;return b};
  function close(){generation++;controller?.abort();controller=null;if(dialog){const old=dialog;dialog=null;old.close();old.remove()}previousFocus?.focus?.()}
  function ready(data,body,actions){
    body.replaceChildren(node('h2','',data.title),node('p','muted-text',data.languageName||data.language));actions.replaceChildren();
    const plain=transcriptExport(data,t),copy=button(t('Копировать всё'),async()=>{
      try{await win.navigator.clipboard.writeText(plain);copy.textContent=t('Скопировано')}
      catch{const fallback=node('textarea','transcript-copy');fallback.readOnly=true;fallback.setAttribute('aria-label',t('Полный текст стенограммы'));fallback.value=plain;body.prepend(node('p','muted-text',t('Буфер обмена недоступен. Выделите текст и скопируйте вручную.')),fallback);fallback.focus();fallback.select();copy.textContent=t('Копировать всё')}
    });
    actions.append(copy,button(t('Сохранить Markdown'),()=>{const blob=new Blob([transcriptExport(data,t,true)],{type:'text/markdown;charset=utf-8'});const url=win.URL.createObjectURL(blob),link=node('a');link.href=url;link.download='AxrTube-'+data.id+'.md';doc.body.append(link);link.click();link.remove();win.setTimeout(()=>win.URL.revokeObjectURL(url),1000)}));
    const contents=node('details','transcript-contents');contents.append(node('summary','',t('Оглавление')));for(const [index,section]of data.sections.entries())contents.append(button(t('Раздел')+' '+(index+1)+' · '+transcriptTimestamp(section.start),()=>body.querySelector('[data-section="'+index+'"]').scrollIntoView({block:'start'})));body.append(contents);
    for(const [index,section]of data.sections.entries()){const box=node('section','transcript-section');box.dataset.section=index;box.append(node('h3','',transcriptTimestamp(section.start)));for(const paragraph of section.paragraphs)box.append(node('p','',paragraph.text));body.append(box)}
  }
  async function open(video,retry=false){
    close();previousFocus=doc.activeElement;const key=++generation,lang=language(),cacheKey=video.id+':'+lang;
    dialog=node('dialog','transcript-dialog');dialog.setAttribute('aria-label',t('Стенограмма'));const header=node('header','transcript-header');header.append(node('h1','',t('Стенограмма')),button(t('Закрыть'),close));const actions=node('div','transcript-actions'),body=node('div','transcript-body');body.append(node('p','loading',t('Собираем стенограмму')),node('p','muted-text',t('Получаем полную дорожку субтитров и убираем повторы.')));dialog.append(header,actions,body);dialog.addEventListener('cancel',e=>{e.preventDefault();close()});doc.body.append(dialog);dialog.showModal();
    if(!retry&&cache.has(cacheKey)){ready(cache.get(cacheKey),body,actions);return}
    controller=new AbortController();
    try{const r=await win.fetch('/api/transcript?'+new URLSearchParams({id:video.id,lang}),{cache:'no-store',signal:controller.signal});const data=await r.json();if(key!==generation)return;
      if(!r.ok||!data.complete||data.id!==video.id||!data.sections?.length)throw Error(data.code||'TRANSCRIPT_SOURCE_UNAVAILABLE');
      if(cache.size>=2)cache.delete(cache.keys().next().value);cache.set(cacheKey,data);ready(data,body,actions);
    }catch(error){if(key!==generation||error.name==='AbortError')return;body.replaceChildren(node('h2','',t(error.message==='TRANSCRIPT_UNAVAILABLE'?'Стенограмма недоступна':'Не удалось получить стенограмму')),node('p','muted-text',t(error.message==='TRANSCRIPT_UNAVAILABLE'?'YouTube не предоставил субтитры для этого ролика.':error.message==='TRANSCRIPT_TOO_LARGE'?'Дорожка слишком большая. Текст не был обрезан.':'YouTube временно не отдал текст. Повторите загрузку.')),button(t('Повторить'),()=>open(video,true)))}
  }
  return {open,close};
}
export const transcriptStyle=`.transcript-dialog{position:fixed;inset:0;margin:auto;width:min(100%,720px);max-width:100%;height:100dvh;max-height:100dvh;padding:env(safe-area-inset-top,0px) 0 env(safe-area-inset-bottom,0px);border:0;background:var(--bg);color:inherit;overflow:hidden}.transcript-dialog[open]{display:flex;flex-direction:column}.transcript-dialog::backdrop{background:#0009}.transcript-header{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:12px 20px;border-bottom:1px solid var(--line)}.transcript-header h1{font-size:22px;margin:0}.transcript-actions{display:flex;flex-wrap:wrap;gap:8px;padding:10px 20px}.transcript-actions:empty{display:none}.transcript-actions button{min-height:48px;flex:1;white-space:normal}.transcript-body{overflow:auto;overscroll-behavior:contain;min-height:0;padding:0 20px 32px;line-height:1.65;overflow-wrap:anywhere;user-select:text;-webkit-user-select:text}.transcript-body h2{font-size:22px}.transcript-section{scroll-margin-top:12px}.transcript-section h3{color:var(--muted);font-size:16px;margin-top:24px}.transcript-section p{font-size:17px;white-space:pre-wrap}.transcript-contents button{display:block;margin:6px 0}.transcript-copy{width:100%;min-height:240px;font-size:16px;color:inherit;background:var(--panel);border:1px solid var(--line);padding:12px}`;
export const transcriptClient='const transcriptTimestamp='+transcriptTimestamp.toString()+';const transcriptExport='+transcriptExport.toString()+';window.axrCreateTranscript='+createTranscriptUI.toString()+';';
