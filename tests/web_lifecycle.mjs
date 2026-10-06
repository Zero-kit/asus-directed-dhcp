import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const root=new URL("../",import.meta.url);
const sample=Object.fromEntries(fs.readFileSync(new URL("config/axdhcp.conf.example",root),"utf8").split("\n").filter(line=>line && !line.startsWith("#")).map(line=>line.split("=")));
const settle=()=>new Promise(resolve=>setImmediate(resolve));
const interfaces=[
  {name:"br0",kind:"bridge",role:"bridge",bridge:"",ssid:"",band:""},
  {name:"eth7",kind:"wifi",role:"uplink",bridge:"br0",ssid:"Upstream",band:"5 GHz"},
  {name:"eth6",kind:"wifi",role:"ap",bridge:"br0",ssid:"Downstream",band:"2.4 GHz"},
  {name:"wl1.1",kind:"wifi",role:"ap",bridge:"br0",ssid:'<test "SSID">',band:"5 GHz"}
];
function fixture({failRun=false,confirmed=true,inventory=interfaces,initialConfig=sample,beforeRequest=async()=>{},leaseText=""}={}) {
  const nodes=new Map();
  function element(id) {
    if(!nodes.has(id)) nodes.set(id,{id,value:"",checked:false,disabled:false,hidden:false,textContent:"",listeners:{},children:[],
      addEventListener(event,fn){this.listeners[event]=fn;},replaceChildren(...children){this.children=children;},appendChild(child){this.children.push(child);}});
    return nodes.get(id);
  }
  const form=element("config"),submit=element("submit");
  const fields=Object.entries(initialConfig).filter(([key])=>!["downstream","enabled"].includes(key)).map(([name,value])=>{
    const input=element(name);input.name=name;input.type=["enabled","autostart","pool_confirmed","dns_confirmed"].includes(name)?"checkbox":"text";
    input.value=value;return input;
  });
  fields.namedItem=name=>element(name);
  form.elements=fields;form.querySelector=()=>submit;
  let saved={...initialConfig,pool_confirmed:confirmed?"1":"0",dns_confirmed:confirmed?"1":"0"};
  let status="state=unverified\nservice=stopped\nhardware_verified=0\n";
  const calls=[];let poll;
  const api=async(action,config)=>{
    calls.push({action,config});
    await beforeRequest(action);
    if(action==="save") {saved={...config};return {ok:true,message:"saved"};}
    if(action==="run") {
      if(failRun) {status+="last_error=Configuration is disabled\n";throw new Error("Configuration is disabled");}
      status="state=running\nservice=started\ngeneration=test\nlifetime=continuous\nrules=intact\nhardware_verified=0\n";
      return {ok:true,message:"started"};
    }
    if(action==="read") return {ok:true,config:Object.entries(saved).map(([k,v])=>`${k}=${v}`).join("\n"),status,leases:leaseText,logs:"",counters:"",interfaces:inventory};
    throw new Error(`Unexpected action ${action}`);
  };
  const context=vm.createContext({window:{axdhcpAPI:api,confirm:()=>true},document:{querySelector:selector=>element(selector.slice(1)),getElementById:element,querySelectorAll:()=>[],createElement:()=>element(`new-${nodes.size}`)},setInterval:fn=>{poll=fn;},Date,navigator:{},localStorage:{},console});
  for(const path of ["web/presentation.js","web/app.js"]) vm.runInContext(fs.readFileSync(new URL(path,root),"utf8"),context);
  return {element,calls,poll:()=>poll(),saved:()=>saved};
}

// Reproduce the reported disabled configuration. Start must save enabled=1
// before asking the backend to launch, then retain the active button state.
const success=fixture();await settle();
assert.equal(success.saved().enabled,"0");
await success.element("run-service").listeners.click();
assert.equal(success.calls[1].action,"save");
assert.equal(success.calls[1].config.enabled,"1");
assert.equal(success.calls[2].action,"run");
assert.equal(success.element("service-state").textContent,"DHCP 运行中");
assert.equal(success.element("run-service").disabled,true);

// A backend rejection must be readable and retained across polling, with the
// real stopped status rather than claiming a successful launch.
const failed=fixture({failRun:true});await settle();
await failed.element("run-service").listeners.click();
assert.match(failed.element("message").textContent,/重新点击.*启动/);
assert.match(failed.element("last-error").textContent,/Configuration is disabled/);
assert.equal(failed.element("last-error").hidden,false);
await failed.poll();
assert.match(failed.element("message").textContent,/Configuration is disabled/);
assert.equal(failed.element("service-state").textContent,"已停止 · 上次操作失败");

const blocked=fixture({confirmed:false});await settle();
await blocked.element("run-service").listeners.click();
assert.deepEqual(blocked.calls.map(call=>call.action),["read"]);
assert.match(blocked.element("message").textContent,/两项确认/);

const auto=fixture();await settle();
auto.element("autostart").checked=true;
await auto.element("config").listeners.submit({preventDefault(){}});
assert.equal(auto.saved().autostart,"1");
assert.equal(auto.saved().enabled,"1");
assert.deepEqual(auto.calls.map(call=>call.action),["read","save"]);

const renamed={br0:"br-lan",eth7:"wifi1",eth6:"wifi0","wl1.1":"wifi1.2"};
const customInventory=interfaces.map(item=>({...item,name:renamed[item.name],bridge:renamed[item.bridge] || ""}));
const custom=fixture({inventory:customInventory,initialConfig:{...sample,bridge:"br-lan",backhaul:"wifi1",downstream:"wifi0,wifi1.2"}});await settle();
await custom.element("run-service").listeners.click();
assert.equal(custom.saved().bridge,"br-lan");
assert.equal(custom.saved().backhaul,"wifi1");
assert.equal(custom.saved().downstream,"wifi0,wifi1.2");
assert.equal(custom.element("service-state").textContent,"DHCP 运行中");
const unknown=fixture({inventory:interfaces.map(item=>item.name==="eth6"?{...item,role:"unknown"}:item)});await settle();
await unknown.element("run-service").listeners.click();
assert.deepEqual(unknown.calls.map(call=>call.action),["read"]);
assert.match(unknown.element("message").textContent,/角色未确认/);
const absent=fixture({inventory:[]});await settle();
assert.equal(absent.element("submit").disabled,true);
assert.equal(absent.element("service-state").textContent,"已停止");
console.log("Web start, rejection, confirmation and saved autostart flows passed");

// A slow save must block duplicate submissions and periodic status requests.
let releaseSave;
const saving=fixture({beforeRequest:action=>action==="save"?new Promise(resolve=>{releaseSave=resolve;}):Promise.resolve()});
await settle();
const pendingSave=saving.element("config").listeners.submit({preventDefault(){}});
await settle();
assert.equal(saving.element("submit").disabled,true);
assert.equal(saving.element("run-service").disabled,true);
assert.equal(saving.element("stop-service").disabled,true);
await saving.poll();
await saving.element("config").listeners.submit({preventDefault(){}});
await saving.element("run-service").listeners.click();
assert.deepEqual(saving.calls.map(call=>call.action),["read","save"]);
releaseSave();await pendingSave;
assert.equal(saving.saved().enabled,"1");
assert.equal(saving.saved().autostart,"0");
assert.equal(saving.element("service-state").textContent,"已停止");
assert.equal(saving.element("submit").disabled,false);
assert.equal(saving.element("stop-service").disabled,false);

// Repeated refresh clicks must not send concurrent reads through KoolShare.
let releaseRead;
const reading=fixture({beforeRequest:action=>action==="read"?new Promise(resolve=>{releaseRead=resolve;}):Promise.resolve()});
await settle();
await reading.poll();
reading.element("refresh").listeners.click();
assert.deepEqual(reading.calls.map(call=>call.action),["read"]);
releaseRead();await settle();
assert.equal(reading.element("service-state").textContent,"已停止");
console.log("Web slow save and overlapping refresh protections passed");

// Firmware duration leases must never render as a date in 1970.
const epoch=Math.floor(new Date("2026-10-06T12:00:00Z").getTime()/1000);
const leased=fixture({leaseText:[
  "600 d6:97:84:eb:aa:89 10.0.0.216 Xiaomi-13 *",
  `${epoch} 02:00:00:00:00:01 10.0.0.217 desktop *`,
  "0 02:00:00:00:00:02 10.0.0.218 * *",
  "86400 02:00:00:00:00:03 10.0.0.219 day *",
  "90000 02:00:00:00:00:04 10.0.0.220 bad-clock *"
].join("\n")});
await settle();
const times=leased.element("lease-rows").children.map(row=>row.children[3].textContent);
assert.equal(times[0],"租约时长：10 分钟");
assert.match(times[1],/^到期：/);assert.match(times[1],/2026/);
assert.equal(times[2],"无限期");
assert.equal(times[3],"租约时长：24 小时");
assert.match(times[4],/时间异常/);
assert.ok(times.every(time=>!time.includes("1970")));
await leased.poll();
assert.equal(leased.element("lease-rows").children[0].children[3].textContent,"租约时长：10 分钟");
console.log("Firmware duration and timestamp lease rendering passed");
