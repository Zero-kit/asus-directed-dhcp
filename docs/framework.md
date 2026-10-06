# 软件中心框架证据与接入清单

工作区最初为空，无可信本机插件模板。公开研究时间：2026-10-03（Asia/Shanghai）。

| 来源 | 观察结果 | 可用性与版本限制 |
|---|---|---|
| https://github.com/koolshare/rogsoft/blob/master/README.md | RT-AX86U 对应 p1axhnd.675x，API 1.5、`.valid` 包验证、平台适配有区别 | raw master 读取成功，未固定 commit，不能视作当前 388.11 模板 |
| https://github.com/koolshare/rogsoft/blob/master/aliddns/aliddns/install.sh | base.sh、dbus 模块注册、res/scripts/webs、init.d/S98 示例 | 只研究，不复用其删除/启动/NVRAM 修改操作 |
| https://github.com/koolshare/rogsoft/blob/master/aliddns/aliddns/webs/Module_aliddns.asp | 页面使用 `/_api/`、softcenter.js、固件菜单/皮肤 | 不假设当前设备 API、鉴权与请求封装相同 |
| https://api.github.com/repos/koolshare/rogsoft/commits/master | API 请求遭遇 rate limit | 未取得 commit SHA，所以来源版本诚实记为未固定的 master |
| https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html | DHCP-only、conf-file、ignore MAC、client ID 和 server identifier 选项参考 | 上游文档；本机 2.91/固件补丁实际语法需 `--test` |

本项目不附 `.valid`，安装脚本默认拒绝软件中心离线安装。`adapters/koolshare/axdhcp-api.sh` 返回 78：明确占位，不读写 dbus、不 dispatch shell、不接受认证未知的 Web 操作。

2026-10-04 更新：上述限制指功能审查包。`axdhcp_probe` 0.1.1 被设备以缺少 Web 页面拒绝。0.1.2 增加匹配模块名的 ASP、scripts 目录及卸载入口，通过安装日志取得只读报告并注册环境检查说明页。它不包含 DHCP 后端，也不开放未知鉴权的 API。公开 ks_tar_install.sh 对页面/scripts 的校验与设备日志相符，且安装后会自动注册模块。详见 [插件包上传](package-upload.md)。新包实际上传接受情况仍待设备确认。

基于已取得的 `base.sh`，API 1.5 适配候选使用 POST `/_api/`、JSON `{id,method,params,fields}`，脚本通过 localhost:3030 `/_resp/<id>` 回传。公开 aliddns 页面和配置脚本支持该契约；axdhcp 候选仅提供 `read`、`save` 两个动作，save 强制 `enabled=0`，不执行网络测试。正式包内 `/koolshare/axdhcp` 保存后端与配置，`/koolshare/scripts/axdhcp_api.sh` 负责 API。由于实际 httpdb/skipd 字段仍未在本机抓取验证，该包标为 integration candidate，不可视为功能验收通过。

## 只读采集能提供的证据

设备实测 2026-10-04 23:36（用户安装日志）：axdhcp_probe 0.1.3 成功解包、执行报告并完成软件中心安装；版本 softcenter_version=1.9.58，BusyBox v1.25.1，/bin/sh 指向 busybox，aarch64 / Linux 4.1.52，productid=RT-AX86U，model=RT-AX86U_EPA，buildno=388.11。id 与 cksum 不可用；已移除目标 UID 检查对 id 的依赖，采集 checksum 现在优先 cksum、缺失时使用 md5sum（设备安装日志已显示 md5sum 可用）。卸载尚未验证。

采集设备的 eth6 为下游 2.4 GHz AP，eth7 为上游 5 GHz 回程，wl1.1 为下游 5 GHz AP，均在 br0。桥地址和默认网关属于同一 /24 子网，ip_forward=0。eth6 与 br0 MAC 相同，eth7 与 wl1.1 MAC 相同；日志只能证明本机接口共享 MAC，不能单凭这些地址证明客户端 MAC 代理行为。三条 ebtables filter 父链为空，dnsmasq 2.91 配置含 no-dhcp-interface=br0，同时存在 conf-dir。conf-dir 指向路径、目录内 DHCP/自定义指令及实际服务清单仍需受限检查；当前后端 preflight 会因 conf-dir 门禁拒绝测试，不应删除系统配置绕过。

安装可用不等于 API 已适配：base.sh 与 softcenter.js 仅取得文件 metadata，实际请求结构、http_response 契约与鉴权/CSRF 仍未确认。报告确认 jq、dbus、httpdb、skipd 可用，但不自动授予 Web 网络操作权限。

运行 `tools/collect-env.sh` 会列出 /koolshare 各相关目录文件名、启动链接、已知 software-center 版本键、dbus/httpdb 路径、base.sh/softcenter.js/主模块页面与 hook 的 metadata/cksum、接口/NVRAM 白名单和过滤规则。不会导出全部 dbus/NVRAM、密码、token、全部配置或所有进程命令行。

框架校验还需要：

1. 软件中心实际版本、固件 build/extendno 与 /bin/sh 实现、BusyBox 版本、`--Lx` 的原样输出。
2. 本机 base.sh、softcenter.js 和一个已安装插件中相关 dispatch/API 部分的脱敏最小片段（只需初始化、读取本插件前缀、请求体结构、http_response 参数）。采集脚本只给 checksum，不擅自输出完整脚本。
3. 已认证浏览器内对已安装插件的一次正常只读请求的 URL、方法与去认证/去密钥后的 JSON schema。不要分享 Cookie、Authorization、token 或口令。
4. 安装/卸载入口布局、包签名或 `.valid` 要求、start/stop hook 的参数契约；已存在钩子可由用户提供与软件中心调用相关的脱敏小段。
5. 本机 Web 会话/CSRF 防护和 backend dispatch 白名单如何保证未经认证请求不能执行测试/停止。

不需要安装任何无关插件。公开模板后续应固定 commit、记录 license，再按当前平台确认。

## 已定义但未接线的适配契约

| 动作 | 独立后端 | 接入要求 |
|---|---|---|
| config.read / config.save | 严格 key=value 配置；save 不启动 | 仅 axdhcp 字段，生成数据文件，不 eval/拼接命令；后端最终校验 |
| filters.test | filters-test + 网络确认 | 明确现场操作确认，测试倒计时，不能据此自动声明硬件通过 |
| service.test | test + 网络及路径确认 | pool/DNS 确认、前置路径验证、最大五分钟 |
| service.stop | stop | 需认证；错误及残留规则必须可见 |
| status / counters / leases / logs | 同名只读命令 | JSON 结构化转换，textContent/HTML escaping，限长，不返回敏感环境 |
| autostart | 第一阶段拒绝非零配置 | 后续完整验收才开放，不能使用 Web 勾选绕过 |

前端将主状态与服务状态分开：unverified 未验证、testing 临时测试中、service=started 服务已启动、verified 验证通过（本阶段禁止）、fault 故障。保存成功不变更验证级别。
