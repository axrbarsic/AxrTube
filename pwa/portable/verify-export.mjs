import {readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root=fileURLToPath(new URL('../',import.meta.url));
async function inventory(directory=root){
  const result={};
  for(const entry of (await readdir(directory,{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name))){
    const absolute=path.join(directory,entry.name),relative=path.relative(root,absolute).split(path.sep).join('/');
    if(relative==='SHA256SUMS.json')continue;
    if(entry.isSymbolicLink())throw Error('Unexpected symlink: '+relative);
    if(entry.isDirectory())Object.assign(result,await inventory(absolute));
    else result[relative]=createHash('sha256').update(await readFile(absolute)).digest('hex');
  }
  return result;
}
const actual=await inventory();
if(process.argv.includes('--write')){
  await writeFile(path.join(root,'SHA256SUMS.json'),JSON.stringify(actual,null,2)+'\n');
  console.log('Wrote checksums for '+Object.keys(actual).length+' files');
}else{
  const expected=JSON.parse(await readFile(path.join(root,'SHA256SUMS.json'),'utf8'));
  const differences=new Set([...Object.keys(actual),...Object.keys(expected)]);
  for(const name of differences)if(actual[name]!==expected[name])throw Error('Checksum/file mismatch: '+name);
  console.log('PASS: '+Object.keys(actual).length+' exported files match SHA-256 inventory');
}
