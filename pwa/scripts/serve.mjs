// Development only. Never needed by the deployed PWA.
import {createServer} from 'node:http';
import {Readable} from 'node:stream';
import app from '../worker/index.js';
const server=createServer(async(req,res)=>{
  try{
    const method=req.method||'GET';
    const request=new Request('http://127.0.0.1:8789'+req.url,{method,headers:req.headers,...(!['GET','HEAD'].includes(method)?{body:Readable.toWeb(req),duplex:'half'}:{})});
    const response=await app.fetch(request);
    res.writeHead(response.status,Object.fromEntries(response.headers));
    if(!response.body){res.end();return}
    const stream=Readable.fromWeb(response.body);stream.on('error',()=>res.destroy());res.on('close',()=>stream.destroy());stream.pipe(res);
  }catch{if(!res.headersSent)res.writeHead(500);res.end('Local server error')}
});
server.listen(8789,'127.0.0.1',()=>console.log('Local: http://127.0.0.1:8789'));
