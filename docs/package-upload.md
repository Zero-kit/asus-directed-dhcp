# 仅通过插件包上传的交付流程

用户无法上传独立 sh，因此设备侧信息检查改为软件中心离线包。无需 SSH 上传文件或手工运行脚本。

## 环境检查包

构建：`sh tools/build-probe.sh`。

产物：`dist/axdhcp_probe-0.1.3.tar.gz`。包内单一目录 `axdhcp_probe/`，包含 install.sh、uninstall.sh、scripts/axdhcp_probe_collect.sh、webs/Module_axdhcp_probe.asp、version 和内容为 hnd 的 .valid。.valid 是平台标识，不是签名或兼容性证明。0.1.1 包因缺少 Web 页面被拒绝；0.1.2 已通过结构检查但因固件没有 `id` applet 在安装脚本第一步退出。0.1.3 改用 `/proc/self/status` 读取 UID。

在软件中心“离线安装”上传本包，查看安装日志，复制 `AXDHCP_PROBE_BEGIN` 到 `AXDHCP_PROBE_END` 的内容。SSID/MAC/BSSID 可先遮蔽，保留接口名和角色，保持同一地址的脱敏标记一致。如日志不完整或软件中心拒绝包，请提供错误文字；不需要修改校验或绕过平台检查。

本包的 install.sh 是一次性检查入口，仅对 RT-AX86U / aarch64 / Linux 4.1.52 / 存在 KoolShare 框架时运行。它输出受限环境报告，不执行 base.sh，不创建启动项，不启动 dnsmasq、变更过滤规则或网络。采集后安装静态说明页与卸载入口，并设置本模块 title/description/version；软件中心会补齐模块注册信息，显示环境检查卡片。完成后可通过软件中心卸载；卸载只移除本检查插件的两个确切文件与五个模块元数据键。软件中心自身的上传、皮肤初始化与临时文件清理行为由其安装器管理。

报告不导出完整 NVRAM/dbus、认证头、口令或 token。收集范围沿用 tools/collect-env.sh，增加 /bin/sh 链接和 BusyBox 版本。缺失工具信息同样有助于适配。

## 正式插件包

正式 axdhcp 包仍需要完成实际软件中心的安装/卸载注册、ASP 页面、认证/API 调用和后端转换。网络测试按钮只有在接入契约确认后开放；安装本身保持 DHCP 关闭。

环境报告只能解决部分版本和目录证据；若仍缺请求结构或鉴权证据，后续通过浏览器中正常操作的脱敏请求或插件包检查补齐。不能把目录/checksum 当成 API 兼容性证明。

现有 `axdhcp-0.1.1-stage1-review.tar.gz` 继续作为源码审查包，不用于离线安装。环境检查包也不包含 DHCP 后端，不能当作正式功能包。

来源：2026-10-04 读取 https://raw.githubusercontent.com/koolshare/rogsoft/master/README.md、aliddns/aliddns/install.sh 和 softcenter/softcenter/scripts/ks_tar_install.sh；后者第 11 项校验匹配本机错误，要求 webs/Module_<模块名>.asp 与 scripts 目录，安装后自动注册模块。未固定 commit，故兼容性仍按未验证记录。安装逻辑自行编写，仅参考公开包布局与平台标识约定。
