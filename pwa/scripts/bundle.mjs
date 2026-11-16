// Small, explicit bundler for the dependency-free Worker. No runtime imports.
import {readFile,writeFile} from 'node:fs/promises';
const root=new URL('../',import.meta.url);
let entry=await readFile(new URL('worker/index.js',root),'utf8');
const modules=['catalog.js','youtube-account.js','transcript.js','comments.js','app-shell.js','app-client.js','app-icon.js'];
const sources=[];
for(const file of modules){
  const source=await readFile(new URL('worker/'+file,root),'utf8');
  if(/^import /m.test(source))throw Error('Nested imports need an explicit build rule');
  sources.push(source.replace(/^export /gm,''));
  const importLine=entry.split('\n').find(line=>line.startsWith('import ')&&line.endsWith("from './"+file+"';"));
  if(!importLine)throw Error('Missing explicit import for '+file);
  entry=entry.replace(importLine,'');
}
await writeFile(new URL('dist/server/index.js',root),sources.join('\n')+'\n'+entry);
