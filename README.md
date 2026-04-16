# QuietWrt

QuietWrt is a router-side distraction blocking setup for a `GL.iNet GL-MT3000` running stock GL firmware with `AdGuard Home`.

It keeps four canonical blocklists on the router:

- `always blocked`
- `workday blocked`
- `after work blocked`
- `password vault blocked`

It can also enforce a nightly curfew by blocking `LAN -> WAN` traffic from `19:00` to `04:00` when overnight blocking is enabled.

## Schedule

- `04:00` to `16:30`: `always + workday`
- `16:30` to `19:00`: `always + after work`
- `09:45` to `09:30`: `always + password vault`
- `19:00` to `04:00`: internet off when overnight blocking is enabled

You can change the `workday`, `after work`, `password vault`, and `overnight` windows later from the PowerShell CLI or with `quietwrtctl schedule ...`.

## How It Works

- `AdGuard Home` handles domain blocking
- QuietWrt fails closed if `AdGuard Home` protection is disabled
- QuietWrt stores canonical list files in `/etc/quietwrt/`
- firewall rules reduce DNS bypass and enforce the nightly curfew
- a boot-time sync plus recurring sync jobs keep policy aligned after reboot and across schedule transitions
- a small LAN page can append new entries to any scheduled blocklist
- a Windows PowerShell CLI installs, updates, toggles, edits schedule windows, backs up, and restores QuietWrt over SSH

Fresh installs default to:

- `always`: enabled
- `workday`: enabled
- `after work`: enabled
- `password vault`: enabled
- `overnight`: disabled

## Run It

From the repo root:

```powershell
pwsh ./tools/quietwrt.ps1
```

The local CLI can:

- install or update QuietWrt
- enable or disable the `always`, `workday`, `after work`, `password vault`, and `overnight` toggles
- change the `workday`, `after work`, `password vault`, and `overnight` schedule windows
- save router blocklist backups into `backups/`
- restore the newest matching `quietwrt-always-*`, `quietwrt-workday-*`, `quietwrt-after-work-*`, and `quietwrt-password-vault-*` backups

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
