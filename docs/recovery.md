# 故障恢复手册

正常顺序是先停止插件 DHCP，再撤销专属过滤。**不要 killall dnsmasq；不要清空任何全局表；不要修改系统 dnsmasq 配置或停止 udhcpc。**

## 正常停止

```sh
sh /jffs/axdhcp/backend/axdhcp.sh stop
sh /jffs/axdhcp/backend/axdhcp.sh status
```

重复 stop 是幂等操作。检查 AXDI/AXDF/AXDO 与自有跳转消失，系统 dnsmasq PID/53 端口与配置保持正常。保留的测试租约并不会因停服立即失效；客户端需重新申请 DHCP。默认最多 300 秒回滚，计时基于 /proc/uptime，NTP 调时不延长窗口。

## fault 或停止失败

先只读查看 `/tmp/axdhcp/state`、generation、dns.identity、lock/owner、control.log、三专属链与父链。`dns.identity` 为 PID、/proc starttime、generation，不仅是 PID。后端只有在可执行文件 basename=dnsmasq、启动时间与精确 `--conf-file=/tmp/axdhcp/dnsmasq.conf` 参数匹配时才发信号。

如果身份确认失败并且原 starttime 的进程仍存在，后端拒绝撤销过滤。由现场人员查看 `/proc/<PID>/exe`、`/proc/<PID>/stat`、cmdline 中的确切配置文件并确认是插件实例，再仅终止该 PID。不要终止相同 PID 下后来重用的系统进程。确认插件实例已经死亡后，再运行 stop；若身份异常需用户审查后修复专属 runtime 元数据。

`dns.launching` 在创建进程之前记录代次。如果此标记或插件 PID 文件存在却丢失 dns.identity，后端按进程身份未知处理并保留过滤。需现场查清是否仍有精确配置参数的实例，确认全部停止后才能人工移走这几个专属记录并再次 stop；不要把缺失身份文件当成“没有进程”。

## stale lock

`/tmp/axdhcp/lock/owner` 记录控制进程 PID 和启动时间。SIGKILL/设备异常可能留下锁，后端不自动夺锁。timer/watchdog 在锁超时情况下只针对本代停止 DHCP，保留过滤，写 fault 记录；**此时网络尚未完整恢复**。

先确认 owner PID 不存在，或启动时间不同，且没有正在执行的 axdhcp 控制操作。只有确认锁已失效后，人工移走精确 `/tmp/axdhcp/lock` 目录到例如 `/tmp/axdhcp/lock.recovery.<记录时间>`，再 stop。不要删整个 runtime 目录，否则会丢失进程身份和规则所有权信息。不要在活控制进程存在时解除锁。

## 自有规则残留

如果 stop 报告清理不完整，先确认插件 DHCP 已停止。检查 `/tmp/axdhcp/rules.owned`，只撤销其中记录的 jump 和 chain。本阶段预期跳转为：

```sh
ebtables -t filter -D INPUT -p IPv4 --ip-proto udp --ip-dport 67 --logical-in br0 -j AXDI
ebtables -t filter -D OUTPUT -p IPv4 --ip-proto udp --ip-sport 67 --logical-out br0 -j AXDO
ebtables -t filter -D FORWARD --logical-in br0 -j AXDF
```

现场确认链属于本插件且没有其他引用后，可以依次 `-F AXDI; -X AXDI`，对 AXDO、AXDF 同样执行（每条命令分别执行）。不能仅凭链名推断所有权；启动检测到既存同名链会拒绝接管。手工删除元数据前务必保存日志并复查所有残留。

规则创建和写入所有权记录之间被强制杀死的极小窗口可能留下未记录的空链/跳转，timer 无法自动安全判断所有权。这也是需要现场恢复、不得永久部署的原因之一。通过记录的测试前后规则快照和日志核对后再处理。

## 卸载与恢复安装文件

`sh /jffs/axdhcp/uninstall.sh --standalone` 先 stop，成功后将准确的安装目录移为 `/jffs/axdhcp.retired.<时间>.<PID>`，不递归删除文件。可以从这个目录恢复配置与文件；runtime 日志保留到重启。失败时安装目录保留。

重启可能清空 /tmp 与固件临时 ebtables，但会影响网络和远程访问，须用户另行决定，不作为本插件自动恢复动作。0.4.1 软件中心包支持保存后的可选开机运行；如需重启后保持停止，先停止服务，取消“开机自动运行”并保存。开机任务等待网络期间，停止或保存配置会取消该任务。独立审查包不安装软件中心钩子。
