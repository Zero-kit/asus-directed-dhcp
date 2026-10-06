# 人工硬件验收

所有项目当前均为 **NOT RUN / 未验证**。模拟测试不能替代 RT-AX86U 的 Broadcom 数据路径。用户目前可能不在现场；仅采集资料不构成部署授权。

## 测试前必须确认

- 用户明确批准临时网络变更，现场有人、有每个选中频段的下游客户端、上游小米客户端、可用的恢复渠道；仅远程上游管理且无现场协助时不要进行过滤/第二 DHCP 测试。
- 在爱快检查 `.201–250` 的静态配置、绑定、租约和其他设备的固定地址；确保 DHCP `.100–200` 与新池不重叠。arping/ping/ARP 表只作辅助。
- `.1` 的 DNS 可用；gateway `.1`；br0 实际地址不落入新池；记录运行时接口、SSID/BSSID、MAC。
- 保存已有 INPUT/FORWARD/OUTPUT 输出、系统 dnsmasq PID/配置摘要、br0 IP、route 和自己的管理连通性；不要以恢复时全表清空为方案。
- 确认回滚脚本、nohup、/proc 身份读取、`--Lx` 与 counter 输出兼容。先读恢复手册。

## 分阶段执行

1. **未挂接能力检查**：人工运行 `sh tools/probe-rules.sh --detached-chain-confirmed`。AXDP 从未挂到父链，结束即删除。确认 logical-in/logical-out/-i/-o、--Lx/--Lc 支持；只说明语法支持。
2. **单独过滤**：将样例编辑为 enabled=1、pool_confirmed=1、dns_confirmed=1，保持 autostart=0。保存后显式授权命令 `sh /jffs/axdhcp/backend/axdhcp.sh filters-test --network-change-confirmed`。使用既有 DHCP 服务与受控合法测试报文核对 broadcast/unicast request、response。此阶段不启动第二 DHCP。
3. **原始路径前提**：用可信且经过审查的测试工具从本机发送与 DHCP raw socket 路径相同的受控响应，验证 OUTPUT 只达 wl1.1、上游没有副本；用抓包或日志确认未授权 ingress 的 raw capture/本机应答约束。缺少工具或人员应记录阻塞，不能直接勾选确认。完整原始 dnsmasq 特定路径仍需下一步验证。
4. **结束过滤阶段**：`sh /jffs/axdhcp/backend/axdhcp.sh stop`，检查三跳转与三专属链全部撤销、服务未运行、网络恢复。filters 与 dhcp 事务不能直接切换，需先 stop。
5. **wl1.1 临时 DHCP**：只有上面路径前提有记录并用户授权后才执行 `sh /jffs/axdhcp/backend/axdhcp.sh test --network-change-confirmed --filter-paths-confirmed`。确认输出 generation、seconds，并分别查看 status、counters、leases、logs。不要把 service=started 判为通过。
6. **华硕客户端**：在 ASUS-5G 客户端主动 release/renew（或关闭 Wi-Fi 后清除租约再重连），记录完整 DORA、server identifier=当前 br0 地址、IP `.201–250`、mask `/24`、gateway `.1`、DNS 配置值。
7. **小米客户端**：主动重新申请 DHCP，仍由爱快 `.1` 提供 `.100–200`；上游抓包中不得出现华硕插件 OFFER/ACK/NAK，插件日志不应为该客户端分配地址。
8. **来源验证**：使用 DHCP 日志关联客户端 MAC 和服务端标识，或分析 UDP 67/68 的 capture、广播与单播各项。仅当前 IP 范围不能判断 DHCP 来源。AF_PACKET 可在过滤前捕获，所以抓包位置必须记录；上游、下游客户端最终可见报文比单一 br0 抓包更有判定力。
9. **华硕自身 udhcpc**：记录自己的 chaddr/client ID、响应 source、server identifier。自然或经单独授权的续租必须由爱快完成，br0 管理地址、default route 稳定；插件不得响应本机 chaddr。不通过停止 udhcpc 来“验证”。
10. **普通流量**：上下游客户端访问互联网、DNS、彼此同网段服务均正常；ip_forward 仍 0，NAT/系统 dnsmasq 未改变。
11. **停止与超时**：先人工 stop，记录先停实例后撤销规则；再次授权测试并断开 SSH/关闭页面，五分钟内 timer 独立停止与撤销。保存旧 generation，在下一次事务调用 rollback 旧代次，不能影响新事务。测试自身需再次申请 DHCP 恢复上游租约。
12. **故障注入**：具备现场恢复与再次授权后，在临时窗口移除一条自有规则、改变接口状态或模拟 watchdog/timer 异常，确认停插件 DHCP、fault 可见；不要修改全局加速、系统 DHCP 或清空全局防火墙。测试仅有约 2 秒检测周期，不代表无泄漏保证。
13. **双频验收与后续阶段**：分别使用 `downstream=eth6`、`downstream=wl1.1`、`downstream=eth6,wl1.1` 重复上面的过滤与 DHCP 验收，每次先停止旧事务。对 eth6 / ASUS-F8 和 wl1.1 / ASUS-5G 分别记录广播、单播、DORA、未选频段不获插件租约与停服恢复；双频同时申请应由同一实例分配不同地址，共用租约表。任一选中接口故障应停止整个实例。T1 单播/T2 广播续租、两方向 Wi-Fi 漫游、回程重连、管理地址变化及重启仍待后续验收；autostart 门禁保留。

上述步骤 3、5、6 中的 wl1.1 / ASUS-5G 示例同样适用于选中的 eth6 / ASUS-F8；双频模式必须对两个频段分别提供真实路径证据。

每次填写 [验收记录](acceptance-template.md)。发现上游收到插件应答、未授权入口被分配、华硕拿到自分配租约、规则计数与实际行为不一致或博通绕过，应立即 stop 并判定阻塞。

## 抓包工具获取

优先在已有 Linux/Windows/macOS 客户端使用可信系统仓库的 tcpdump 或官方 Wireshark，在上游和下游同时抓取 `udp port 67 or udp port 68`。只有客户端与交换路径确实可观察目标流量时 capture 才有效；普通 Wi-Fi 网卡可能看不到其他客户端单播，镜像端口/监控模式需要额外设备与授权。

路由器上先检查软件中心或固件是否已有可信工具；可研究官方 Entware aarch64 仓库，但其环境部署、依赖、存储、动态链接器与内核兼容要先评估并取得用户授权。第三方预编译静态 tcpdump 可能存在供应链和 ABI 风险，应固定来源、版本、hash 并审查，不自动下载安装或执行未知二进制。

抓包包含 MAC、主机名、client ID、IP 等信息，只保存必要 DHCP 测试流量，分享前脱敏。无需采集密码或软件中心认证凭据。
