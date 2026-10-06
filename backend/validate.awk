# Parse data only. Output a canonical config, never shell statements.
function fail(s) { print "Invalid configuration: " s > "/dev/stderr"; bad=1 }
function ip(s, a,n,i,v) {
    n=split(s,a,"."); if(n!=4) return -1
    v=0
    for(i=1;i<=4;i++) {
        if(a[i]!~/^[0-9]+$/ || length(a[i])>3 || a[i]+0>255 || (length(a[i])>1 && substr(a[i],1,1)=="0")) return -1
        v=v*256+a[i]
    }
    return v
}
function unicast(v) { return v>=16777216 && v<3758096384 && int(v/16777216)!=127 && int(v/65536)!=43518 }
function iface(s) { return length(s)>0 && length(s)<=15 && s~/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ }
BEGIN {
    order="enabled bridge backhaul downstream pool_start pool_end netmask gateway dns lease_seconds test_seconds autostart pool_confirmed dns_confirmed"
    nkeys=split(order,keys," "); for(i=1;i<=nkeys;i++) allowed[keys[i]]=1
}
/^[ \t]*#/ || /^[ \t]*$/ { next }
{
    if(length($0)>256 || $0~/\r/ || index($0,"=")==0) { fail("malformed line"); next }
    p=index($0,"="); k=substr($0,1,p-1); v=substr($0,p+1)
    if(!(k in allowed) || k in c) { fail("unknown or duplicate key"); next }
    if(v!~/^[A-Za-z0-9.,_-]+$/) { fail("invalid value characters"); next }
    c[k]=v
}
END {
    for(i=1;i<=nkeys;i++) if(!(keys[i] in c)) fail("missing " keys[i])
    for(k in c) if(k=="enabled" || k=="autostart" || k=="pool_confirmed" || k=="dns_confirmed") if(c[k]!~/^[01]$/) fail(k)
    if(c["autostart"]=="1" && (c["enabled"]!="1" || c["pool_confirmed"]!="1" || c["dns_confirmed"]!="1")) fail("autostart requires enabled and pool/DNS confirmations")
    if(!iface(c["bridge"]) || !iface(c["backhaul"]) || c["bridge"]==c["backhaul"]) fail("invalid bridge/backhaul interfaces")
    count=split(c["downstream"],members,",")
    if(count<1 || count>8) fail("select 1..8 downstream interfaces")
    for(i=1;i<=count;i++) {
        if(!iface(members[i]) || members[i]==c["bridge"] || members[i]==c["backhaul"] || members[i] in seen) fail("invalid, overlapping or duplicate downstream interface")
        seen[members[i]]=1
    }
    s=ip(c["pool_start"]); e=ip(c["pool_end"]); g=ip(c["gateway"]); m=ip(c["netmask"])
    # Contiguous mask: 2^32-mask must be a power of two.
    block=4294967296-m; x=block
    if(m<2147483648 || m>4294967292) fail("mask requires /1 through /30")
    else { while(x>1 && x%2==0) x=x/2; if(x!=1) fail("non-contiguous mask") }
    if(!unicast(s) || !unicast(e) || !unicast(g) || s>e || e-s>1023) fail("pool or gateway")
    if(!bad) {
        net=int(s/block)*block; broadcast=net+block-1
        if(int(e/block)*block!=net || int(g/block)*block!=net || s==net || e==broadcast || g==net || g==broadcast || (g>=s && g<=e)) fail("subnet, reserved address or gateway overlap")
        if(bridge_ip!="") {
            b=ip(bridge_ip)
            if(b<0 || int(b/block)*block!=net || b==net || b==broadcast || (b>=s && b<=e) || b==g) fail("bridge address or subnet")
            if(bridge_prefix!="") {
                expected=4294967296; for(i=0;i<bridge_prefix;i++) expected=expected/2
                if(expected!=block) fail("bridge prefix does not match mask")
            }
        }
    }
    nd=split(c["dns"],ds,","); if(nd<1 || nd>3) fail("DNS count")
    for(i=1;i<=nd;i++) if(!unicast(ip(ds[i])) || ip(ds[i])==4294967295) fail("DNS address")
    if(c["lease_seconds"]!~/^[0-9]+$/ || length(c["lease_seconds"])>5 || c["lease_seconds"]+0<120 || c["lease_seconds"]+0>86400) fail("lease_seconds: 120..86400")
    if(c["test_seconds"]!~/^[0-9]+$/ || length(c["test_seconds"])>3 || c["test_seconds"]+0<30 || c["test_seconds"]+0>300) fail("test_seconds: 30..300")
    if(bad) exit 1
    for(i=1;i<=nkeys;i++) print keys[i] "=" c[keys[i]]
}
