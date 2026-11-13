import assert from 'node:assert/strict';
import vm from 'node:vm';
import {languageRows,languageNames,resolveLanguage,createI18n} from '../worker/i18n.js';
import {appClient} from '../worker/app-client.js';
import app from '../worker/index.js';
assert.equal(Object.keys(languageNames).length,6);
const keys=new Set();for(const row of languageRows){assert.equal(row.length,6,'Expected six translations: '+row[0]);assert(row.every(v=>v.trim()),'Empty translation: '+row[0]);assert(!keys.has(row[0]),'Duplicate message: '+row[0]);keys.add(row[0])}
for(const m of appClient.matchAll(/t\('([^']*[А-Яа-яЁё][^']*)'\)/g))assert(keys.has(m[1].trim()),'Missing UI translation: '+m[1]);
assert.equal(resolveLanguage('auto',['uk-UA','en-US']),'uk');assert.equal(resolveLanguage('auto',['ht-HT']),'ht');assert.equal(resolveLanguage('auto',['jam-JM']),'jam');assert.equal(resolveLanguage('auto',['hat']),'ht');assert.equal(resolveLanguage('auto',['fr-FR','es-MX']),'es');assert.equal(resolveLanguage('auto',['de-DE']),'en');assert.equal(resolveLanguage('ru',['es']),'ru');
function fixture(saved,preferred=['es-MX']){
  const events=new Map(),storage=new Map();if(saved)storage.set('axrtube.pwa.language.v1',saved);
  const text={nodeValue:'Главная',parentElement:{closest:()=>false}};const user={nodeValue:'Новости',parentElement:{closest:()=>true}};
  const doc={documentElement:{lang:''},body:{},querySelectorAll:()=>[],createTreeWalker:()=>{let at=0;return {nextNode:()=>[text,user][at++]||null}}};
  const win={localStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v)},Event:class{constructor(type){this.type=type}},dispatchEvent:event=>events.get(event.type)?.(),addEventListener:(name,fn)=>events.set(name,fn)};
  const nav={languages:preferred};const api=createI18n(win,doc,nav,languageRows,languageNames,resolveLanguage);return {api,doc,win,nav,text,user,storage,events};
}
let f=fixture();assert.equal(f.api.locale,'es');assert.equal(f.api.choice,'auto');f.api.translateStatic();assert.equal(f.text.nodeValue,'Inicio');assert.equal(f.user.nodeValue,'Новости');assert.equal(f.doc.documentElement.lang,'es');
f.api.setLanguage('uk');assert.equal(f.api.t('Настройки'),'Налаштування');assert.equal(f.text.nodeValue,'Головна');assert.equal(f.api.t(' Подключён YouTube: '),' YouTube підключено: ');assert.equal(f.storage.get('axrtube.pwa.language.v1'),'uk');
assert.equal(f.api.t('Авторское название ролика'),'Авторское название ролика');assert.equal(fixture('uk',['en']).api.locale,'uk');assert.equal(fixture('bad',['ht']).api.locale,'ht');
f.api.setLanguage('auto');assert.equal(f.api.locale,'es');f.nav.languages=['ru-RU'];f.events.get('languagechange')();assert.equal(f.api.locale,'ru');assert.equal(f.text.nodeValue,'Главная');
for(const locale of Object.keys(languageNames)){f.api.setLanguage(locale);assert.equal(f.api.locale,locale);assert(f.api.t('Настройки'));assert.equal(f.doc.documentElement.lang,locale)}
const shipped=await(await app.fetch(new Request('https://lab.test/app.js'))).text();new vm.Script(shipped);assert(shipped.includes('axrtube.pwa.language.v1'));assert(shipped.includes('language.onchange'));
const engine=await(await app.fetch(new Request('https://lab.test/engine.js'))).text();for(const m of engine.matchAll(/tr\('([^']*[А-Яа-яЁё][^']*)'\)/g))assert(keys.has(m[1].trim()),'Missing player translation: '+m[1]);
console.log('PASS: six complete message columns, shipped UI translation coverage, language priorities/regions/fallback, manual persistence, auto language changes, static labels, user-content exclusion and shipped syntax');
