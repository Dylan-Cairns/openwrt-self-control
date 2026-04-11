# Router Install

This document describes the current end-to-end setup for the `GL.iNet GL-MT3000` on stock GL firmware.

It assumes:

- the router is being used in `Router` mode
- `AdGuard Home` is the blocking engine
- `IPv6` is disabled
- the local management app is deployed from this repo

## 1. Base Router Setup

1. Connect the router in the real traffic path.
   Use `modem -> MT3000 WAN`.

2. Log into the GL.iNet admin UI.

3. Update to the current stock GL firmware.

4. Confirm the router is in `Router` mode.
   Path: `NETWORK -> Network Mode`

5. Set the router admin password.
   Path: `SYSTEM -> Security`

6. Keep WAN remote access off.
   Path: `SYSTEM -> Security`

7. Enable `SSH Local Access`.
   Path: `SYSTEM -> Security`

8. Disable `IPv6`.
   Path: `NETWORK -> IPv6`

9. Enable router DNS override.
   Path: `NETWORK -> DNS`
   Turn on `Override DNS Settings for All Clients`.

10. Confirm the router timezone is correct.
    The schedule depends on router local time.

## 2. Enable AdGuard Home

1. Open `APPLICATIONS -> AdGuard Home`.

2. Turn `AdGuard Home` on.

3. Click `Apply`.

4. Open the AdGuard Home settings page once.

5. Back up the config:

```sh
cp /etc/AdGuardHome/config.yaml /etc/AdGuardHome/config.yaml.bak
```

## 3. Add Firewall Hardening

These rules:

- redirect direct client DNS on port `53` back to the router
- block `DNS over TLS` on port `853`

SSH to the router:

```sh
ssh root@192.168.8.1
```

Replace `192.168.8.1` if your router uses a different LAN IP.

Create the DNS interception rule:

```sh
uci -q delete firewall.dns_int
uci set firewall.dns_int="redirect"
uci set firewall.dns_int.name="Intercept-DNS"
uci set firewall.dns_int.family="ipv4"
uci set firewall.dns_int.proto="tcp udp"
uci set firewall.dns_int.src="lan"
uci set firewall.dns_int.src_dport="53"
uci set firewall.dns_int.target="DNAT"
```

Create the `DoT` block rule:

```sh
uci -q delete firewall.dot_fwd
uci set firewall.dot_fwd="rule"
uci set firewall.dot_fwd.name="Deny-DoT"
uci set firewall.dot_fwd.family="ipv4"
uci set firewall.dot_fwd.src="lan"
uci set firewall.dot_fwd.dest="wan"
uci set firewall.dot_fwd.dest_port="853"
uci set firewall.dot_fwd.proto="tcp udp"
uci set firewall.dot_fwd.target="REJECT"
uci commit firewall
service firewall restart
```

## 4. Deploy The QuietWrt App

Copy the CGI entrypoint:

```sh
scp -O app/quietwrt.cgi root@192.168.8.1:/www/cgi-bin/quietwrt
ssh root@192.168.8.1 "chmod 755 /www/cgi-bin/quietwrt"
```

Copy the CLI entrypoint:

```sh
scp -O app/quietwrtctl.lua root@192.168.8.1:/usr/bin/quietwrtctl
ssh root@192.168.8.1 "chmod 755 /usr/bin/quietwrtctl"
```

Copy the shared Lua modules:

```sh
ssh root@192.168.8.1 "mkdir -p /usr/lib/lua/quietwrt"
scp -O app/quietwrt/*.lua root@192.168.8.1:/usr/lib/lua/quietwrt/
```

Install the QuietWrt schedule and seed the canonical list files:

```sh
ssh root@192.168.8.1 "/usr/bin/quietwrtctl install"
```

This creates and maintains:

- `/etc/quietwrt/always-blocked.txt`
- `/etc/quietwrt/workday-blocked.txt`
- `/etc/quietwrt/passthrough-rules.txt`

and installs `cron` sync points at:

- `04:00`
- `16:30`
- `18:30`

## 5. Open The App

Open:

- `https://192.168.8.1:8443/cgi-bin/quietwrt`

The page should:

- show the current mode
- show `Protection: enabled`
- show separate `Always blocked` and `Workday blocked` lists
- allow one new domain, hostname, or URL to be added at a time

## 6. Verify The Final State

Check these from a client connected to the MT3000:

1. A site added to `Always blocked` is blocked at `10:00`.
2. A site added to `Workday blocked` is blocked at `10:00`.
3. A `Workday blocked` site is no longer blocked between `16:30` and `18:30`.
4. Internet access is fully unavailable between `18:30` and `04:00`.
5. Router-local access to `https://<router-ip>:8443/cgi-bin/quietwrt` still works during the curfew window.
6. A client manually pointed at `8.8.8.8` still gets filtered.
7. `DNS over TLS` on port `853` no longer works.

## 7. Useful Commands

Show current status:

```sh
/usr/bin/quietwrtctl status
```

Force an immediate resync:

```sh
/usr/bin/quietwrtctl sync
```

Restore the AdGuard config backup:

```sh
cp /etc/AdGuardHome/config.yaml.bak /etc/AdGuardHome/config.yaml
/etc/init.d/adguardhome restart
```

Temporarily disable the curfew rule by hand:

```sh
uci set firewall.quietwrt_curfew.enabled='0'
uci commit firewall
service firewall restart
```

Show the AdGuard restart log:

```sh
cat /tmp/quietwrt-adguard-restart.log
```
