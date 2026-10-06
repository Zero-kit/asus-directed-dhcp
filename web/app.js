"use strict";
const form = document.querySelector("#config");
const message = document.querySelector("#message");
let latestRouterResult=null;
let operationBusy=false;
let refreshBusy=false;
let requestQueue=Promise.resolve();
function callRouter(...args) {
  const request=requestQueue.then(()=>window.axdhcpAPI(...args));
  requestQueue=request.catch(()=>{});
  return request;
}
function updateControls() {
  const status=window.axdhcpPresentation.parseStatus(latestRouterResult?.status || "");
  form.querySelector("button[type=submit]").disabled=operationBusy || (Boolean(window.axdhcpAPI) && detectedInterfaces.length===0);
  document.getElementById("run-service").disabled=operationBusy || !window.axdhcpAPI || status.generation!==undefined;
  document.getElementById("stop-service").disabled=operationBusy || !window.axdhcpAPI;
}
const key = "axdhcp-stage1-preview-config-v1";
let bands=[];
let detectedInterfaces=[];
const defaults = Object.fromEntries(Array.from(form.elements).filter(e => e.name).map(e => [e.name, e.type === "checkbox" ? "0" : e.value]));
function ipv4(s) {
  const a = s.split(".");
  if (a.length !== 4 || a.some(x => !/^(0|[1-9][0-9]{0,2})$/.test(x) || Number(x) > 255)) throw new Error("请输入有效 IPv4 地址");
  return a.reduce((v,x) => v*256+Number(x),0);
}
function validate(c) {
  const iface=name=>/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$/.test(name);
  const members=c.downstream.split(",");
  if(!iface(c.bridge) || !iface(c.backhaul) || c.bridge===c.backhaul || members.length>8 || new Set(members).size!==members.length || members.some(name=>!iface(name) || name===c.bridge || name===c.backhaul)) throw new Error("请选择网络桥、上游回程及至少一个下游 Wi-Fi；角色不能重复");
  if(window.axdhcpAPI) {
    const bridge=detectedInterfaces.find(item=>item.name===c.bridge && item.kind==="bridge");
    const backhaul=detectedInterfaces.find(item=>item.name===c.backhaul && item.bridge===c.bridge && (item.role==="uplink" || item.kind==="ethernet"));
    if(!bridge || !backhaul || members.some(name=>!detectedInterfaces.some(item=>item.name===name && item.bridge===c.bridge && item.kind==="wifi" && item.role==="ap"))) throw new Error("所选接口已不存在、未加入该桥或角色未确认，请重新识别并选择");
  }
  if(!["0","1"].includes(c.autostart)) throw new Error("开机自动运行设置无效");
  if(c.autostart==="1" && (c.pool_confirmed!=="1" || c.dns_confirmed!=="1")) throw new Error("开机自动运行需确认地址池和 DNS");
  const s=ipv4(c.pool_start), e=ipv4(c.pool_end), g=ipv4(c.gateway), mask=ipv4(c.netmask), block=4294967296-mask;
  if (mask<2147483648 || mask>4294967292 || !Number.isInteger(Math.log2(block))) throw new Error("请输入连续的子网掩码（/1 至 /30）");
  const net=Math.floor(s/block)*block, broadcast=net+block-1;
  if (s>e || e-s>1023 || s===net || e===broadcast || Math.floor(e/block)*block!==net || Math.floor(g/block)*block!==net || g===net || g===broadcast || (g>=s && g<=e)) throw new Error("地址池、网关或保留地址重叠，请检查");
  const unicast = v => v>=16777216 && v<3758096384 && Math.floor(v/16777216)!==127 && Math.floor(v/65536)!==43518;
  if (![s,e,g].every(unicast)) throw new Error("地址需为有效单播地址");
  const dns=c.dns.split(",");
  if (dns.length>3 || dns.some(x=>!unicast(ipv4(x)))) throw new Error("DNS 需为 1 至 3 个单播地址，以逗号分隔");
  for (const [name,min,max] of [["lease_seconds",120,86400],["test_seconds",30,300]]) {
    if (!/^[0-9]+$/.test(c[name]) || Number(c[name])<min || Number(c[name])>max) throw new Error("租约或测试时间超出允许范围");
  }
}
function applyConfig(saved) {
  for (const [iface, input] of bands) input.checked=saved.downstream.split(",").includes(iface);
  for (const [k,v] of Object.entries(saved)) {
    const e=form.elements.namedItem(k); if (!e) continue;
    if (e.type === "checkbox") e.checked=v==="1"; else e.value=String(v);
  }
}
function interfaceLabel(item) {
  const role={bridge:"网络桥",uplink:"上游 Wi-Fi",ap:"下游 Wi-Fi",unknown:"角色未确定"}[item.role] || "角色未确定";
  return item.kind==="bridge"?`网络桥 · ${item.name}`:item.kind==="ethernet"?`有线接口 · ${item.name}（请确认连接上游）`:`${item.band} · ${item.ssid || "SSID 未读取"} · ${item.name} · ${role}`;
}
function fillOptions(select,items,selected) {
  select.replaceChildren();
  const placeholder=document.createElement("option");placeholder.value="";placeholder.textContent="请选择";select.appendChild(placeholder);
  for(const item of items) {
    const option=document.createElement("option");option.value=item.name;option.textContent=interfaceLabel(item);select.appendChild(option);
  }
  if(selected && !items.some(item=>item.name===selected)) {
    const unavailable=document.createElement("option");unavailable.value=selected;unavailable.textContent=`${selected} · 未识别或不可用`;select.appendChild(unavailable);
  }
  select.value=selected || "";
}
function populateMembers(bridge,backhaul,selected=[]) {
  const candidates=detectedInterfaces.filter(item=>item.bridge===bridge && (item.role==="uplink" || item.kind==="ethernet"));
  fillOptions(form.elements.namedItem("backhaul"),candidates,backhaul);
  const panel=document.getElementById("downstream-options");panel.replaceChildren();bands=[];
  for(const item of detectedInterfaces.filter(item=>item.bridge===bridge && item.kind==="wifi")) {
    const label=document.createElement("label"),input=document.createElement("input"),text=document.createElement("span");
    input.type="checkbox";input.value=item.name;input.disabled=item.role!=="ap" || item.name===backhaul;input.checked=selected.includes(item.name);
    text.textContent=interfaceLabel(item);label.appendChild(input);label.appendChild(text);panel.appendChild(label);bands.push([item.name,input]);
  }
  if(!bands.length) panel.textContent="该桥没有识别到 Wi-Fi 接口，请核查诊断信息。";
}
function populateInterfaces(config) {
  fillOptions(form.elements.namedItem("bridge"),detectedInterfaces.filter(item=>item.kind==="bridge"),config.bridge);
  populateMembers(config.bridge,config.backhaul,config.downstream.split(","));
  const uplinks=detectedInterfaces.filter(item=>item.role==="uplink");
  document.getElementById("interface-help").textContent=detectedInterfaces.length?(uplinks.length===1?`推荐回程：${uplinks[0].name} · ${uplinks[0].ssid || "上游 Wi-Fi"}`:"请按实际连接选择回程；角色未确定的 Wi-Fi 暂不可选。"):"未取得接口信息，请展开诊断检查。";
}
form.elements.namedItem("bridge").addEventListener("change",()=>populateMembers(form.elements.namedItem("bridge").value,"",[]));
form.elements.namedItem("backhaul").addEventListener("change",()=>populateMembers(form.elements.namedItem("bridge").value,form.elements.namedItem("backhaul").value,bands.filter(([,input])=>input.checked).map(([name])=>name)));
document.getElementById("discover-interfaces").addEventListener("click",async()=>{
  if(!window.axdhcpAPI || operationBusy) return;
  const selected=currentConfig();
  if(!await refreshRouter(true,true)) return;
  populateInterfaces(selected);
  message.textContent="接口信息已刷新，请核对选择后保存；当前服务未改变。";
});
function renderRouter(result, preserveEdits=false) {
  latestRouterResult=result;
  const c=Object.fromEntries(result.config.trim().split("\n").map(line=>{const p=line.indexOf("=");return [line.slice(0,p),line.slice(p+1)];}));
  if(Array.isArray(result.interfaces)) detectedInterfaces=result.interfaces;
  if(!preserveEdits) { populateInterfaces(c); applyConfig(c); }
  const status=window.axdhcpPresentation.parseStatus(result.status);
  document.getElementById("service-state").textContent=window.axdhcpPresentation.stateLabel(status);
  const lastError=document.getElementById("last-error");
  lastError.hidden=!status.last_error;
  lastError.textContent=status.last_error?`最近操作失败：${window.axdhcpPresentation.errorMessage(status.last_error)}`:"";
  updateControls();
  const rows=document.getElementById("lease-rows"); rows.replaceChildren();
  const leases=window.axdhcpPresentation.leases(result.leases);
  for (const lease of leases) {
    const tr=document.createElement("tr");
    for(const value of [lease.ip,lease.mac,lease.hostname,window.axdhcpPresentation.leaseTime(lease.expires)]) {
      const td=document.createElement("td"); td.textContent=value; tr.appendChild(td);
    }
    rows.appendChild(tr);
  }
  if(!leases.length) {
    const tr=document.createElement("tr"),td=document.createElement("td");td.colSpan=4;td.className="empty";
    td.textContent=result.leases.trim()?"租约数据格式异常，请查看诊断报告":"暂无租约";tr.appendChild(td);rows.appendChild(tr);
  }
  for (const [id,text] of [["rules",result.counters || "尚未部署规则"],["logs",result.logs || "暂无运行日志"]]) {
    const panel=document.getElementById(id), pre=document.createElement("pre");
    pre.textContent=text; panel.replaceChildren(pre);
  }
}
async function refreshRouter(preserveEdits=false, rediscover=false) {
  if(refreshBusy) return false;
  refreshBusy=true;
  try {
    const result=await callRouter("read",null,preserveEdits && !rediscover?"status-only":undefined); renderRouter(result,preserveEdits);
    if(!preserveEdits) message.textContent="已读取路由器配置和运行状态";
    return true;
  }
  catch(error) { message.textContent=window.axdhcpPresentation.errorMessage(error.message); return false; }
  finally { refreshBusy=false; }
}
if (window.axdhcpAPI) {
  form.querySelector("button[type=submit]").disabled=true;
  refreshRouter();
} else try {
  const raw = localStorage.getItem(key);
  if (raw) {
    applyConfig(JSON.parse(raw));
  }
} catch { message.textContent="本地配置无法读取，已使用默认值"; }
function currentConfig() {
  const c = {...defaults};
  for (const e of form.elements) if (e.name) c[e.name]=e.type==="checkbox" ? (e.checked?"1":"0") : e.value;
  // Saving prepares an eligible configuration; only run/boot launches DHCP.
  c.enabled="1";
  c.downstream=bands.filter(([,input])=>input.checked).map(([iface])=>iface).join(",");
  return c;
}
form.addEventListener("submit", async event => {
  event.preventDefault();
  if(operationBusy) return;
  const c=currentConfig();
  try {
    validate(c);
    if(c.autostart==="1" && !window.confirm("保存后，每次重启路由器都会自动启动华硕发地址。目前客户端分配及上下游互不影响仍未验收。确认启用开机自动运行？")) return;
    operationBusy=true;updateControls();
    if (window.axdhcpAPI) {
      const result=await callRouter("save",c); message.textContent=result.message;
    } else { localStorage.setItem(key,JSON.stringify(c)); message.textContent="已保存至本地浏览器；路由器配置未修改"; }
  }
  catch (error) { message.textContent=window.axdhcpPresentation.errorMessage(error.message); }
  finally { operationBusy=false;updateControls(); }
});
const tabs = Array.from(document.querySelectorAll("[role=tab]"));
document.getElementById("copy-diagnostics").addEventListener("click",async()=>{
  const report=["AXDHCP 诊断报告",new Date().toISOString(),document.getElementById("check-report").textContent,
    ...["status","config","leases","counters","logs"].map(k=>`\n${k}\n${latestRouterResult?.[k] || "未读取"}`),`\n接口\n${JSON.stringify(detectedInterfaces,null,2)}`].join("\n");
  try { await navigator.clipboard.writeText(report); message.textContent="诊断报告已复制，分享前请脱敏"; }
  catch { document.getElementById("check-report").textContent=report; message.textContent="浏览器无法自动复制，请手动选中报告复制"; }
});
for (const [id,action] of [["run-service","run"],["stop-service","stop"]]) {
  document.getElementById(id).addEventListener("click",async()=>{
    if(!window.axdhcpAPI || operationBusy) return;
    let runConfig=null;
    if(action==="run") {
      runConfig=currentConfig();
      try {
        validate(runConfig);
        if(runConfig.pool_confirmed!=="1" || runConfig.dns_confirmed!=="1") throw new Error("请先核查地址池和 DNS，并勾选两项确认。");
      } catch(error) { message.textContent=window.axdhcpPresentation.errorMessage(error.message); return; }
      const bootText=runConfig.autostart==="1"?"已勾选开机自动运行，重启后也会自动启动。":"重启后需手动启动。";
      if(!window.confirm(`将保存当前配置并启动华硕持续发地址，直到停止或发生故障。${bootText}客户端分配及上下游互不影响尚未验收，可能影响获取地址。确认启动？`)) return;
    }
    operationBusy=true;updateControls();
    message.textContent=action==="run"?"正在保存并启动，请稍候…":"正在执行，请稍候…";
    try {
      if(runConfig) {
        await callRouter("save",runConfig);
      }
      const confirmation=action==="run"?"network-change-and-unverified-paths-acknowledged":undefined;
      const result=await callRouter(action,null,confirmation);
      await refreshRouter(); message.textContent=result.message;
    } catch(error) {
      const failure=window.axdhcpPresentation.errorMessage(error.message);
      await refreshRouter(true); message.textContent=failure;
    }
    finally {
      operationBusy=false;
      updateControls();
    }
  });
}
if(window.axdhcpAPI) setInterval(()=>{ if(!operationBusy) return refreshRouter(true); },5000);
document.getElementById("check-env").addEventListener("click",async()=>{
  const report=document.getElementById("check-report");
  if(!window.axdhcpAPI) { report.textContent="本地预览未连接路由器"; return; }
  const button=document.getElementById("check-env"); button.disabled=true;
  try { const result=await callRouter("check"); report.textContent=result.logs; message.textContent=result.message; }
  catch(error) { report.textContent=error.message; }
  finally { button.disabled=false; }
});
function selectTab(button) {
  for (const b of tabs) {
    const active=b===button; b.setAttribute("aria-selected",String(active)); b.tabIndex=active?0:-1;
    document.getElementById(b.getAttribute("aria-controls")).hidden=!active;
  }
}
for (const [i,b] of tabs.entries()) {
  b.tabIndex=i===0?0:-1;
  b.addEventListener("click",()=>selectTab(b));
  b.addEventListener("keydown",e=>{
    if (!["ArrowLeft","ArrowRight","Home","End"].includes(e.key)) return;
    e.preventDefault(); const next=e.key==="Home"?0:e.key==="End"?tabs.length-1:(i+(e.key==="ArrowRight"?1:-1)+tabs.length)%tabs.length;
    selectTab(tabs[next]); tabs[next].focus();
  });
}
document.getElementById("refresh").addEventListener("click",()=>{ if(operationBusy) return; if(window.axdhcpAPI) refreshRouter(); else message.textContent="未连接路由器，尚无实时数据"; });
