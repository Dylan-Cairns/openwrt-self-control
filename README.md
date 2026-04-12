# QuietWrt

QuietWrt is a router-side distraction blocking setup for a `GL.iNet GL-MT3000` running stock GL firmware with `AdGuard Home`.

It keeps two canonical blocklists on the router:

- `always blocked`
- `workday blocked`

It also enforces a nightly curfew by blocking `LAN -> WAN` traffic from `18:30` to `04:00`.

## Schedule

- `04:00` to `16:30`: `always + workday`
- `16:30` to `18:30`: `always` only
- `18:30` to `04:00`: internet off

## How It Works

- `AdGuard Home` handles domain blocking
- QuietWrt fails closed if `AdGuard Home` protection is disabled
- QuietWrt stores canonical list files in `/etc/quietwrt/`
- firewall rules reduce DNS bypass and enforce the nightly curfew
- a boot-time sync plus recurring sync jobs keep policy aligned after reboot and across schedule transitions
- a small LAN page can append new entries to either list
- a Windows PowerShell CLI installs, updates, toggles, backs up, and restores QuietWrt over SSH

## Run It

From the repo root:

```powershell
pwsh ./tools/quietwrt.ps1
```

The local CLI can:

- install or update QuietWrt
- enable or disable the `always`, `workday`, and `overnight` toggles
- save router blocklist backups into `backups/`
- restore the newest matching `quietwrt-always-*` and `quietwrt-workday-*` backups

Detailed setup and operating instructions live in `docs/router-install.md`.

## Tests

Lua:

```powershell
lua tests\run.lua
```

PowerShell:

```powershell
powershell -NoProfile -Command "Invoke-Pester -Path .\tests\powershell\quietwrt.Tests.ps1 -EnableExit"
```
