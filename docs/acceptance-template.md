# 现场验收记录模板

状态：NOT RUN。所有空白条目均未验证；不能依据进程启动自动填写 PASS。

设备/固件/软件中心版本：____  测试日期：____  操作人员：____

网络变更授权范围：____  现场恢复方式：____  generation：____

br0 IP/MAC：____  eth7 / eth6 / wl1.1 BSSID：____  选中下游：____  配置 checksum：____

地址池静态地址/绑定核查依据：____  DNS 可用依据：____

| 项目 | PASS / FAIL / BLOCKED / NOT RUN | 证据位置与观察 |
|---|---|---|
| 未挂接规则能力 | NOT RUN | |
| FORWARD 广播与单播请求 | NOT RUN | |
| FORWARD 广播与单播响应 | NOT RUN | |
| INPUT 未授权入口拒绝 | NOT RUN | |
| OUTPUT 广播与单播仅下游可见 | NOT RUN | |
| raw socket / 博通旁路检查 | NOT RUN | |
| wl1.1 DORA 与服务端标识 | NOT RUN | |
| 小米侧爱快 DORA 与零插件泄漏 | NOT RUN | |
| 华硕 udhcpc 自身 chaddr / 续租 | NOT RUN | |
| 网关 .1 / DNS / 同网段互访 | NOT RUN | |
| 规则计数与实际行为对应 | NOT RUN | |
| 停止恢复 | NOT RUN | |
| 断开管理会话超时恢复 | NOT RUN | |
| 旧代次不回滚新部署 | NOT RUN | |
| 丢规则 / 回程变更停服 | NOT RUN | |
| eth6 DORA 与服务端标识 | NOT RUN | |
| 双频同时分配 / 共享池无重复地址 | NOT RUN | |
| 单频模式未选频段不获插件租约 | NOT RUN | |
| 任一选中接口异常停止整个实例 | NOT RUN | |
| 续租 / 漫游 / 回程重连（后续） | NOT RUN | |
| 重启与开机运行（后续） | NOT RUN | |

结论与剩余阻塞：____。阶段一后端不读取本模板或把硬件状态提升到 verified。
