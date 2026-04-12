# Router Install And Operation

This is the main operator guide for `QuietWrt`.

QuietWrt is designed around a `GL.iNet GL-MT3000` running stock GL firmware with `AdGuard Home` enabled. There is no uninstall flow. If you want to fully remove QuietWrt from the router, use your normal router reset / rebuild process.

## 1. Router Prerequisites

Before installing QuietWrt, confirm these in the GL.iNet admin UI:

1. the router is in `Router` mode
2. `SSH Local Access` is enabled
3. `WAN Remote Access` stays off
4. `IPv6` is disabled
5. `Override DNS Settings for All Clients` is enabled
6. the router timezone is correct
7. `AdGuard Home` is enabled and protection is on

## 2. Local Machine Prerequisites

On the Windows machine where you will run the local CLI:

1. install `PowerShell 7`
2. install `Posh-SSH`
3. clone this repo

Install `Posh-SSH` once with:

```powershell
Install-Module -Name Posh-SSH -Scope CurrentUser
```

## 3. Install Or Update QuietWrt

From the repo root:

```powershell
pwsh ./tools/quietwrt.ps1
```

The CLI prompts for:

- router host
  default: `192.168.8.1`
- router username
  default: `root`
- router password

Choose:

```text
1. Install/Update QuietWrt
```

Install/update uploads these router-side files:

- `app/quietwrt.cgi` -> `/www/cgi-bin/quietwrt`
- `app/quietwrtctl.lua` -> `/usr/bin/quietwrtctl`
- `app/quietwrt.init` -> `/etc/init.d/quietwrt`
- `app/quietwrt/*.lua` -> `/usr/lib/lua/quietwrt/`

It then:

- creates or validates the canonical QuietWrt files in `/etc/quietwrt/`
- writes persistent toggle state in UCI under `quietwrt.settings.*`
- installs the managed cron block
- enables the QuietWrt boot sync init script
- installs or refreshes the managed firewall sections
- applies the current mode immediately

If `AdGuard Home` protection is disabled, install now fails closed instead of reporting a healthy QuietWrt install.

## 4. Daily Control Menu

The local CLI keeps one SSH session and one SFTP session open and offers:

```text
1. Install/Update QuietWrt
2. Enable/Disable always-on blocklist
3. Enable/Disable workday blocklist
4. Enable/Disable overnight blocking
5. Backup both blocklists to this PC
6. Restore latest backup
```

After any state-changing action, it prints the refreshed router status.

## 5. Backup And Restore

Backups are stored locally in the repo `backups/` directory.

Backup filenames are:

- `quietwrt-always-YYYY-MM-DD-HHMMSS.txt`
- `quietwrt-workday-YYYY-MM-DD-HHMMSS.txt`

The restore option:

- looks in `backups/`
- chooses the newest matching `quietwrt-always-*` file
- chooses the newest matching `quietwrt-workday-*` file
- shows the selected filenames before restoring
- works with either file or both
- leaves the other router-side list untouched if only one backup file exists
- runs one sync after the restore completes

## 6. Schedule And Reconciliation

QuietWrt modes are:

- `04:00` to `16:30`: `always + workday`
- `16:30` to `18:30`: `always` only
- `18:30` to `04:00`: internet off

QuietWrt reconciles state in three ways:

- immediately during install/update
- on boot through `/etc/init.d/quietwrt`
- through cron at `04:00`, `16:30`, `18:30`, and every `10` minutes as a backstop

## 7. Managed Router State

Canonical QuietWrt data lives here:

- `/etc/quietwrt/always-blocked.txt`
- `/etc/quietwrt/workday-blocked.txt`
- `/etc/quietwrt/passthrough-rules.txt`

QuietWrt-managed firewall sections are:

- `firewall.quietwrt_dns_int`
- `firewall.quietwrt_dot_fwd`
- `firewall.quietwrt_curfew`

QuietWrt UCI state lives under:

- `quietwrt.settings.always_enabled`
- `quietwrt.settings.workday_enabled`
- `quietwrt.settings.overnight_enabled`
- `quietwrt.settings.schema_version`

## 8. Manual List Editing

You can edit the canonical files directly on the router, then run:

```sh
/usr/bin/quietwrtctl sync
```

Rules to keep in mind:

- `always-blocked.txt` and `workday-blocked.txt` must contain canonical lowercase hostnames
- `passthrough-rules.txt` is for non-block AdGuard rules that should be preserved
- bad manual edits fail closed; QuietWrt will report an error instead of silently rebuilding lossy state

The local web page is append-only by design:

- it can add entries to `always` or `workday`
- it cannot delete entries
- it cannot edit passthrough rules
- it cannot disable enforcement

## 9. Verify A Working Install

After install, confirm:

1. a site added to `Always blocked` is blocked during daytime hours
2. a site added to `Workday blocked` is blocked before `16:30`
3. a `Workday blocked` site is no longer blocked between `16:30` and `18:30`
4. internet access is unavailable between `18:30` and `04:00` when overnight blocking is enabled
5. router-local access to `https://<router-ip>:8443/cgi-bin/quietwrt` still works during the curfew window
6. direct client DNS on `53` is intercepted
7. direct `DoT` on `853` is blocked

## 10. Direct Router Commands

Useful direct commands:

```sh
/usr/bin/quietwrtctl install
/usr/bin/quietwrtctl sync
/usr/bin/quietwrtctl status
/usr/bin/quietwrtctl status --json
/usr/bin/quietwrtctl set always on
/usr/bin/quietwrtctl set always off
/usr/bin/quietwrtctl set workday on
/usr/bin/quietwrtctl set workday off
/usr/bin/quietwrtctl set overnight on
/usr/bin/quietwrtctl set overnight off
/usr/bin/quietwrtctl restore --always /path/to/quietwrt-always-YYYY-MM-DD-HHMMSS.txt
/usr/bin/quietwrtctl restore --workday /path/to/quietwrt-workday-YYYY-MM-DD-HHMMSS.txt
cat /tmp/quietwrt-adguard-restart.log
cat /tmp/quietwrt-boot-sync.log
```
