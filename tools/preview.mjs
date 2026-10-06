import http from "node:http";
import {readFile} from "node:fs/promises";
import {fileURLToPath} from "node:url";
const files = {"/":"index.html","/index.html":"index.html","/app.js":"app.js","/presentation.js":"presentation.js","/style.css":"style.css"};
const types={html:"text/html; charset=utf-8",js:"text/javascript; charset=utf-8",css:"text/css; charset=utf-8"};
const server=http.createServer(async(req,res)=>{
  const path=new URL(req.url,"http://localhost").pathname;
  if (req.method!=="GET" || !files[path]) { res.writeHead(404); res.end("Not found"); return; }
  try {
    const data=await readFile(fileURLToPath(new URL("../web/"+files[path],import.meta.url)));
    res.writeHead(200,{"Content-Type":types[files[path].split(".").pop()],"Cache-Control":"no-store","X-Content-Type-Options":"nosniff","Content-Security-Policy":"default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'none'; object-src 'none'; frame-ancestors 'none'"});
    res.end(data);
  } catch { res.writeHead(500); res.end("Read error"); }
});
server.listen(Number(process.env.AXDHCP_PREVIEW_PORT||8765),"127.0.0.1",()=>console.log(`AXDHCP preview: http://127.0.0.1:${server.address().port}`));
