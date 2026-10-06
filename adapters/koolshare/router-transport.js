"use strict";
window.axdhcpAPI = async (action, config, confirmation) => {
  const id = Date.now() % 100000000;
  const params = [action];
  if (confirmation) params.push(confirmation);
  if (config) {
    const text=Object.entries(config).map(([k,v])=>`${k}=${v}`).join("\n");
    const bytes=new TextEncoder().encode(text);
    params.push("AXDHCP64:"+btoa(Array.from(bytes,b=>String.fromCharCode(b)).join("")));
  }
  const response = await fetch("/_api/", {
    method:"POST", credentials:"same-origin", cache:"no-store",
    headers:{"Content-Type":"application/json"},
    body:JSON.stringify({id,method:"axdhcp_api.sh",params,fields:{}})
  });
  if (!response.ok) throw new Error(`软件中心请求失败 (${response.status})`);
  const data=await response.json();
  let result=data.result;
  if (typeof result === "string" && result.startsWith("AXDHCP64:")) {
    try {
      const bytes=Uint8Array.from(atob(result.slice(9)),c=>c.charCodeAt(0));
      result=JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(bytes));
    } catch { throw new Error("插件响应解码失败，请刷新页面后重试"); }
  }
  if (typeof result === "string") { try { result=JSON.parse(result); } catch { throw new Error("软件中心返回格式待适配，请提供错误文字"); } }
  if (!result || typeof result.ok !== "boolean") throw new Error("软件中心返回格式待适配，请提供错误文字");
  if (!result.ok) throw new Error(result.message || "操作失败");
  return result;
};
