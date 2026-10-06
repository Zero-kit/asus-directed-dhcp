# DHCP 报文路径设计审查

审查结论：**有条件的实验设计，硬件路径是阻塞项。当前不得标记验证通过或永久部署。** 只验证过的两条未挂接规则由用户提供，本项目没有远程连接设备。

所有接口留在 br0，保留 10.0.0.0/24、ip_forward=0、无 NAT。下游选择集合 S 可为 eth6（2.4G）、wl1.1（5G）或两者；默认双频，共用一个地址池和租约文件。eth7 是 5 GHz 上游回程，始终排除。`wl ap=1` 不能判定角色。以下策略中的“选中下游”均指 S，未选频段按未授权端口处理。

## 路径与策略

下表描述标准 Linux bridge/netfilter 的预期路径，并非博通实现的观测结论。客户端请求通常 UDP 68→67，响应 67→68；规则按请求目的端口 67、响应源端口 67 匹配，也拒绝下游穿过桥的 DHCP relay/服务器流量。

| 报文 | 预期路径 | 规则 / 保留条件 |
|---|---|---|
| 选中下游广播 DISCOVER / REQUEST | 克隆到本机 INPUT、桥 FORWARD 至其他成员 | INPUT 允许 S，FORWARD 丢弃 S 入口目的端口 67 的全部 IPv4 UDP；防止上游爱快听见请求 |
| 选中下游向旧服务器 .1 单播续租 | FORWARD 至回程，可能有本机副本 | 同一入口请求 DROP 覆盖单播；旧服务器续租被阻止，客户端需等待 T2 rebinding 后广播，可能暂时失去租约，不能强制 NAK |
| 上游广播或单播 OFFER/ACK/NAK 发往选中下游 | eth7 等入口，经 FORWARD 至 S | 所有 S 出口的 UDP 源端口 67 DROP，不依赖广播标志或目的 MAC |
| 未授权端口请求到华硕本地 | INPUT，logical-in=br0 | INPUT 链只让 S RETURN，其余 DROP；包括 eth7、未选频段和有线成员。不能用 interface=br0 区分物理入口 |
| 插件发给选中下游的本地广播/单播响应 | OUTPUT，logical-out=br0，物理出口 S | OUTPUT 只让 S RETURN；其余出口 DROP，防止本地 DHCP 污染上游 |
| 华硕 udhcpc 广播申请、单播续租 | 本机 OUTPUT，UDP 源端口 68、目的端口 67，经 eth7 | OUTPUT 跳转只匹配源端口 67，udhcpc 请求不受影响 |
| 爱快给华硕 udhcpc 的广播/单播响应 | INPUT，UDP 源端口 67、目的端口 68 | INPUT 跳转只匹配目的端口 67，回复保持可达 |
| 小米侧客户端请求在桥上泛洪到本机 | INPUT 和 FORWARD | 插件 INPUT 拒绝；FORWARD 对不涉及 S 的 DHCP 继续 RETURN，上游仍可分配 .100–200 |
| 选中下游客户端请求向另一频段 / 其他成员转发 | FORWARD | S 入口请求 DROP；双频共用本地服务，不依赖请求跨频段转发 |
| 未选频段 / 有线客户端请求至 S | FORWARD | 请求可能可达 S 客户端，但插件本机 INPUT 拒绝；S 入口服务器回复 DROP，避免下游 rogue DHCP 对外传播 |
| 同一无线接口内的客户端之间 DHCP | 可能在无线驱动内部直接转发 | ebtables 不保证覆盖，独立 DHCP 服务器与恶意 DHCP 无法在此层获得完整隔离保证 |

普通 ARP、TCP、DNS、IPv6、互联网及同网段互访不由这些链匹配。DHCP 本身的定向限制是预期变化；不添加 ARP 欺骗或客户端隔离。

## 实际规则结构

```text
INPUT   first: IPv4 UDP dport 67 logical-in br0 -> AXDI
  AXDI: for each interface in S: ingress RETURN; otherwise DROP
FORWARD first: logical-in br0 -> AXDF
  AXDF: for each interface in S:
        IPv4 UDP dport 67 ingress DROP
        IPv4 UDP sport 67 egress DROP
        IPv4 UDP sport 67 ingress DROP
        otherwise RETURN
OUTPUT  first: IPv4 UDP sport 67 logical-out br0 -> AXDO
  AXDO: for each interface in S: egress RETURN; otherwise DROP
```

链名 4 字符；只删除自有跳转和本事务成功创建的链。`RETURN` 遵从原有后续防火墙，不隐含全局 ACCEPT。插入首位以免原有 ACCEPT 提前放行；运行中监控首位、自有跳转数量和规则文本。使用 legacy `--Lx` 比较规则，`--Lc` 读计数；**不使用 `-C`，legacy ebtables 的 `-C` 是修改计数。** logical-in/out 与 OUTPUT 物理 `-o` 是否可用需要 detached probe 及实际报文测试。

## 独立 dnsmasq 与华硕自身 DHCP

只用 `--conf-file=/tmp/axdhcp-runtime/dnsmasq.conf` 加显式参数，`port=0`、no-resolv、no-hosts，不追加默认配置、conf-dir、RA、TFTP 或 authoritative。独立配置/PID/租约/日志，不修改或停止系统 dnsmasq。`bind-interfaces` 与 interface=br0 限定逻辑接口，**不能限定 wl1.1 物理入口**。0.4.6 通过空 `user=`/`group=` 保留启动控制进程已验证的 UID 0 身份，避免固件没有 root 账号名的问题，以支持原始 DHCP 套接字和 0700 私有 runtime 内的租约/日志写入；没有宣称降权沙箱，后续若改为专属用户需确认固件账号与 capabilities 支持。

本机 OUTPUT 的 udhcpc 请求可能被 packet socket 看见，不能指望 INPUT DROP 自动排除。启动时枚举本机所有链路 MAC，生成 `dhcp-host=MAC,ignore`，使用 `dhcp-ignore-clid` 按 chaddr 排除本机；不把其他客户端 ID 写入日志。此策略必须核验 udhcpc 实际 chaddr 是否为这些本机 MAC，尤其博通的 MAC 转换/proxy 行为。出现自响应、身份重写或未授权请求可触发插件应答，即为失败。

server-identifier 使用实时 br0 地址，客户端 option 3 gateway 固定 .1。lease 600 秒默认适合实验窗口，但停止 DHCP 后已经分配的租约不会被撤销，测试最多 300 秒并不意味着客户端地址同时恢复。

## 不能由规则文本证明的阻塞项

1. Linux AF_PACKET 接收可在 INPUT/netfilter 拒绝前观察数据；dnsmasq 的 DHCP socket 组合和本固件补丁可能影响实际路径。输入规则计数增加不能证明 dnsmasq 没看见上游请求。
2. DHCP 广播发送可能走 AF_PACKET/raw socket，绕过 bridge OUTPUT；某些单播走 UDP/IP socket 路径。OUTPUT 计数为 0 或上游可见插件应答均不能通过验收。
3. Broadcom runner/flow cache、无线硬件内部转发、repeater/MAC proxy 与回程泛洪可能绕开 FORWARD，或使物理 -i/-o 不再是预期接口。
4. 同一物理无线接口客户端流量可能由驱动直接处理。广播沿回程再回到其他无线入口的副本可能进入不同路径。
5. DHCP 上游单播续租会被设计阻止，客户端广播 rebinding、保留旧 IP、切换 SSID、服务器 identifier 的路由均需真实观察。
6. 不改变全局硬件加速。若实验表明必须关闭，应先解释全网吞吐/CPU 影响并取得单独授权；不能把关闭视作插件隐含操作。

`--filter-paths-confirmed` 是操作人员提供的限时实验前提声明，不是后端自动验收证明。限时实验先测试真实 INPUT/FORWARD/OUTPUT、broadcast/unicast，并确认 packet-socket 类发送没有泄漏。若缺少本地原始发送工具或抓包证据，不可仅凭过滤计数宣称已确认。0.4.0 根据用户要求提供独立长期启动，允许客户端验收延后，改用明确的 `--unverified-paths-acknowledged` 风险确认；并未证明原始套接字或硬件路径隔离。dnsmasq 特定发送与接收路径仍须实际验证；任何泄漏立即停止，并判定本方案不适用于当前固件。

## 生命周期与故障边界

保存是严格 key=value 数据解析，不 source、不 eval；字段白名单、重复/未知键拒绝。实时校验网段、桥 prefix、网关、管理 IP、网络/广播地址、地址池大小、DNS、lease、接口角色。pool_confirmed 与 dns_confirmed 默认 0，ping 不回应不构成空闲证明。

部署顺序：锁 → 环境/配置检查 → 建立代次与单调时钟截止时间 → 脱离会话的回滚任务存活检查 → 所有过滤链及跳转 → DHCP 语法检查/实例 → 看门狗 → ready。实际配置语法检查在部署前执行，只作检查不服务。失败先停 DHCP 再清理；不能确认停服时保留过滤并报告故障。

约每 2 秒检查规则文本、跳转位置、NVRAM 角色、IP/MAC/默认路由、回程/下游 BSSID 和必要进程。变化先停止 DHCP。独立 timer 约每秒检查 watchdog 存活与截止时间，两者都不重新读取用户配置；退出本代事务也尝试停本代进程。未捕获的瞬时断连、驱动绕过、两个监督进程同时被强制杀死、规则清除与下一次检查之间的窗口无法被 shell 保证消除。锁被异常进程占用时只停本代 DHCP 并保留规则，需要手工恢复。不是内核级无泄漏保证。

PID 与 /proc 启动时间、可执行文件、精确配置参数同时检查；不用 killall。旧 timer 的 token 必须匹配 DNS identity 中的代次，不能杀新实例。正常清理由 mkdir 互斥锁保护。stale lock 不自动抢夺，防止误解并发状态；恢复手册提供检查方式。

阶段一系统 DHCP 排除检查是保守的已知配置门禁，并不等同于全面证明没有其他 DHCP 进程；用户应核验运行时服务、UDP 67 socket、DHCP capture 与系统配置一致。后续版本应基于采集结果完善固件补丁/服务清单确认。
