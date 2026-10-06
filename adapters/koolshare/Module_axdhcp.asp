<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta http-equiv="Cache-Control" content="no-cache">
<title>华硕定向 DHCP</title>
<link rel="stylesheet" href="/index_style.css">
<link rel="stylesheet" href="/form_style.css">
<link rel="stylesheet" href="/res/softcenter.css">
<script src="/js/jquery.js"></script>
<script src="/state.js"></script>
<script src="/popup.js"></script>
<script src="/help.js"></script>
<script src="/general.js"></script>
<script src="/res/softcenter.js"></script>
<style>
#axdhcp-frame{display:block;width:100%;border:1px solid #687579;min-height:900px;background:#4d595d;box-sizing:border-box;border-radius:0 0 5px 5px}
.axdhcp-return{display:block;padding:8px 12px;text-align:right;color:#fff;font-size:12px;background:#4d595d;border:1px solid #687579;border-bottom:0;margin-top:8px;border-radius:5px 5px 0 0}
</style>
<script>
function axdhcpMenuHook() {
    tabtitle[tabtitle.length - 1] = new Array("", "华硕定向 DHCP");
    tablink[tablink.length - 1] = new Array("", "Module_axdhcp.asp");
}
function axdhcpInit() { show_menu(axdhcpMenuHook); }
function axdhcpResize(frame) {
    try {
        var doc=frame.contentDocument;
        function resize() { frame.style.height=doc.body.scrollHeight+2+"px"; }
        resize();
        if(window.ResizeObserver) new ResizeObserver(resize).observe(doc.body);
    } catch(error) { /* The frame remains independently scrollable. */ }
}
</script>
</head>
<body onload="axdhcpInit();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<table class="content" align="center" cellpadding="0" cellspacing="0"><tr>
<td width="17"></td>
<td valign="top" width="202"><div id="mainMenu"></div><div id="subMenu"></div></td>
<td valign="top">
<div id="tabMenu" class="submenuBlock"></div>
<a class="axdhcp-return" href="/Module_Softcenter.asp">返回软件中心</a>
<iframe id="axdhcp-frame" title="华硕定向 DHCP 配置" src="/res/axdhcp/index.html" onload="axdhcpResize(this);"></iframe>
</td><td width="10"></td>
</tr></table>
<div id="footer"></div>
</body>
</html>
