# QuietWrt App

This directory contains the router-side QuietWrt app and shared policy code.

## Files

- `quietwrt.cgi`
  - Lua CGI entrypoint for `uhttpd`
  - renders the LAN-only page
  - handles add-entry submissions
- `quietwrtctl.lua`
  - Lua CLI entrypoint for router-side install and scheduled sync
- `quietwrt/`
  - shared modules for validation, schedule logic, AdGuard config updates, storage, and rendering

## Router Layout

The current app is a multi-file deployment:

- copy `quietwrt.cgi` to `/www/cgi-bin/quietwrt`
- copy `quietwrtctl.lua` to `/usr/bin/quietwrtctl`
- copy `quietwrt/` to `/usr/lib/lua/quietwrt/`

## Responsibilities

- keep canonical source lists in `/etc/quietwrt/`
- compile the active AdGuard rules for the current time window
- install cron-based sync points at `04:00`, `16:30`, and `18:30`
- enforce the nightly internet curfew with a firewall rule
- show both blocklists and the current effective mode in the web UI

## Local Testing

Run the local suite with:

```powershell
lua tests\run.lua
```

## Notes

- the web page is still intentionally small and LAN-only
- source-of-truth data now lives in `/etc/quietwrt/`, not directly in AdGuard `user_rules`
- non-block AdGuard `user_rules` are preserved in `/etc/quietwrt/passthrough-rules.txt`
