"use strict";
window.axdhcpPresentation = {
  parseStatus(text) {
    return Object.fromEntries(String(text).trim().split("\n").filter(line=>line.includes("=")).map(line=>{
      const p=line.indexOf("="); return [line.slice(0,p),line.slice(p+1)];
    }));
  },
  stateLabel(status) {
    if(status.state==="fault" || status.rules==="fault") return "故障 · 需要恢复";
    if(status.service==="started") return "DHCP 运行中";
    if(status.boot_pending==="1") return "开机启动中 · 等待网络";
    if(status.generation && status.mode==="filters") return "过滤测试中";
    if(status.last_error) return "已停止 · 上次操作失败";
    return "已停止";
  },
  errorMessage(text) {
    const message=String(text);
    const hints=[
      ["Configuration is disabled", "已保存的配置尚未启用，请重新点击“启动”；若仍失败，请复制诊断报告。"],
      ["Confirm pool ownership and DNS service first", "请核查地址池无占用、DNS 可用，勾选两项确认并保存。"],
      ["autostart requires enabled", "开机自动运行需要同时启用服务，并确认地址池和 DNS。"],
      ["Interface identity or network environment rejected", "网络尚未就绪或接口与已适配环境不一致，请运行只读检查并复制诊断报告。"],
      ["Default route mismatch", "配置中的默认网关与路由器实际默认路由不一致，或存在多个默认路由。请核对下面的预期值与实际值。"],
      ["Cannot read default route", "无法读取路由器默认路由，请查看下方原始信息并复制诊断报告。"],
      ["Isolated dnsmasq configuration check failed", "DHCP 配置校验失败，服务未启动。下方原始信息是 dnsmasq 给出的具体原因。"],
      ["DHCP configuration generation failed", "生成 DHCP 配置时失败，还没有启动服务。下方会指出具体接口或文件。"],
      ["unknown user or group", "dnsmasq 使用的用户或组在固件中不存在，服务无法启动。请保留下方具体账号名称。"],
      ["DHCP startup failed", "DHCP 启动检查失败，服务没有确认运行。请复制下方完整信息和运行日志，以区分进程退出和识别失败。"],
      ["Existing transaction needs stop/recovery", "还有旧的运行任务，请先点击“停止并恢复”再启动。"],
      ["Stop the active transaction before saving", "请先停止正在运行的服务，再修改并保存配置。"],
      ["Residual transaction requires recovery", "检测到上次运行的残留，请先点击“停止并恢复”。"],
      ["Boot startup timed out", "开机后等待网络超时，未启动 DHCP。请检查上游连接并查看诊断报告。"],
      ["Boot startup worker exited", "开机启动任务已退出，请先停止并恢复，再手动启动。"]
    ];
    const hint=hints.find(([match])=>message.includes(match));
    return hint?`${hint[1]}\n原始信息：${message}`:message;
  },
  leaseTime(value) {
    if(!Number.isSafeInteger(value) || value<0) return "未知";
    if(value===0) return "无限期";
    // Firmware built with HAVE_BROKEN_RTC stores duration, not an epoch.
    // This plugin permits finite lease durations up to 86400 seconds.
    if(value<=86400) {
      const hours=Math.floor(value/3600),minutes=Math.floor(value%3600/60),seconds=value%60;
      const duration=[hours?`${hours} 小时`:"",minutes?`${minutes} 分钟`:"",seconds?`${seconds} 秒`:""].filter(Boolean).join(" ");
      return `租约时长：${duration}`;
    }
    if(value<946684800) return "时间异常，请检查路由器系统时间";
    const date=new Date(value*1000);
    return Number.isNaN(date.getTime())?"未知":`到期：${date.toLocaleString()}`;
  },
  leases(text) {
    return String(text).trim().split("\n").filter(Boolean).flatMap(line=>{
      const fields=line.trim().split(/\s+/);
      if(fields.length<4 || !/^\d+$/.test(fields[0]) || !/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(fields[1])) return [];
      const expires=Number(fields[0]);
      return [{ip:fields[2],mac:fields[1],hostname:fields[3]==="*"?"—":fields[3],expires}];
    });
  }
};
