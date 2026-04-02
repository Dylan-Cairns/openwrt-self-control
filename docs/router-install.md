# Router Install

This document describes the current end-to-end setup for the `GL.iNet GL-MT3000` on stock GL firmware.

It assumes:

- the router is being used in `Router` mode
- `AdGuard Home` is the blocking engine
- `IPv6` is disabled
- the main blocklist is stored outside this repo
- the local management app is deployed from `app/focus.cgi`

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

## 2. Enable AdGuard Home

1. Open `APPLICATIONS -> AdGuard Home`.

2. Turn `AdGuard Home` on.

3. Click `Apply`.

4. Click `Settings Page`.

5. In AdGuard Home, open `Filters -> Custom filtering rules`.

6. Paste the current router-ready blocklist from your external source.
   The rules should already be in AdGuard format like:

   ```txt
   ||example.com^
   ||www.example.org^
   ```

7. Save the custom filtering rules.

8. Confirm blocking works from a client on the MT3000 network.

## 3. Add Firewall Hardening

These rules do two things:

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
```

```sh
uci set firewall.dns_int="redirect"
```

```sh
uci set firewall.dns_int.name="Intercept-DNS"
```

```sh
uci set firewall.dns_int.family="ipv4"
```

```sh
uci set firewall.dns_int.proto="tcp udp"
```

```sh
uci set firewall.dns_int.src="lan"
```

```sh
uci set firewall.dns_int.src_dport="53"
```

```sh
uci set firewall.dns_int.target="DNAT"
```

Create the `DoT` block rule:

```sh
uci -q delete firewall.dot_fwd
```

```sh
uci set firewall.dot_fwd="rule"
```

```sh
uci set firewall.dot_fwd.name="Deny-DoT"
```

```sh
uci set firewall.dot_fwd.family="ipv4"
```

```sh
uci set firewall.dot_fwd.src="lan"
```

```sh
uci set firewall.dot_fwd.dest="wan"
```

```sh
uci set firewall.dot_fwd.dest_port="853"
```

```sh
uci set firewall.dot_fwd.proto="tcp udp"
```

```sh
uci set firewall.dot_fwd.target="REJECT"
```

Commit and restart the firewall:

```sh
uci commit firewall
```

```sh
service firewall restart
```

## 4. Deploy The Local Management App

The app is a single CGI script served by the router's built-in `uhttpd`.

Copy the script from this repo to the router:

```sh
scp -O app/focus.cgi root@192.168.8.1:/www/cgi-bin/focus
```

Make it executable:

```sh
ssh root@192.168.8.1 "chmod 755 /www/cgi-bin/focus"
```

Back up the AdGuard Home config once:

```sh
ssh root@192.168.8.1 "cp /etc/AdGuardHome/config.yaml /etc/AdGuardHome/config.yaml.bak"
```

Open the app:

- `https://192.168.8.1:8443/cgi-bin/focus`

The page should:

- show the current custom rules
- show `Protection: enabled`
- allow one new domain, hostname, or URL to be added at a time

The app writes changes to:

- `/etc/AdGuardHome/config.yaml`

and restarts AdGuard Home after each successful add.

## 5. Verify The Final State

Check these from a client connected to the MT3000:

1. A blocked site is blocked.
2. A manually added site from `/cgi-bin/focus` is blocked.
3. Your work VPN still connects.
4. A client manually pointed at `8.8.8.8` still gets filtered.
5. `DNS over TLS` on port `853` no longer works.

## 6. Useful Recovery Commands

Restore the AdGuard Home config backup:

```sh
cp /etc/AdGuardHome/config.yaml.bak /etc/AdGuardHome/config.yaml
```

Restart AdGuard Home:

```sh
/etc/init.d/adguardhome restart
```

Show the local app restart log:

```sh
cat /tmp/focus-adguard-restart.log
```
