// Export-only adapter. Original Worker source is unchanged.
// Bind locally; terminate HTTPS and apply traffic limits at your reverse proxy.
import {createServer} from 'node:http';
import {Readable} from 'node:stream';
import app from '../source/dist/server/index.js';

const port=Number(process.env.PORT||8789);
if(!Number.isInteger(port)||port<1||port>65535)throw Error('Invalid PORT');
// Worker expects the public HTTPS origin, even behind a local HTTP proxy.
const origin=new URL(process.env.PUBLIC_ORIGIN||'https://127.0.0.1:'+port).origin;
if(!origin.startsWith('https://'))throw Error('PUBLIC_ORIGIN must be HTTPS');
const env=Object.fromEntries(['GOOGLE_OAUTH_ENABLED','GOOGLE_OAUTH_PERSONAL_HOME_ENABLED','GOOGLE_OAUTH_CLIENT_ID','GOOGLE_OAUTH_CLIENT_SECRET','GOOGLE_OAUTH_COOKIE_KEY'].map(key=>[key,process.env[key]||'']));
const server=createServer(async(req,res)=>{
  try{
    if(!req.url?.startsWith('/')||req.url.startsWith('//')){res.writeHead(400);res.end('Bad path');return}
    const method=req.method||'GET';
    const request=new Request(new URL(req.url,origin),{method,headers:req.headers,...(!['GET','HEAD'].includes(method)?{body:Readable.toWeb(req),duplex:'half'}:{})});
    const response=await app.fetch(request,env);
    res.statusCode=response.status;
    for(const [key,value] of response.headers)if(key!=='set-cookie')res.setHeader(key,value);
    const cookies=response.headers.getSetCookie();if(cookies.length)res.setHeader('set-cookie',cookies);
    if(!response.body){res.end();return}
    const stream=Readable.fromWeb(response.body);
    stream.on('error',()=>res.destroy());res.on('close',()=>stream.destroy());stream.pipe(res);
  }catch{if(!res.headersSent){res.writeHead(500);res.end('Server error')}else res.destroy()}
});
server.listen(port,'127.0.0.1',()=>console.log('AxrTube adapter listening on http://127.0.0.1:'+port));
