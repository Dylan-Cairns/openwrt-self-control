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
- applies the current schedule state immediately

Fresh installs currently default to:

- `always`: enabled
- `workday`: enabled
- `after work`: enabled
- `overnight`: disabled

This keeps the nighttime curfew off until you explicitly enable it after confirming the rest of the install behaves as expected.

If `AdGuard Home` protection is disabled, install now fails closed instead of reporting a healthy QuietWrt install.

## 4. Daily Control Menu

The local CLI keeps one SSH session plus an SCP-backed file transfer connection open and offers:

```text
1. Install/Update QuietWrt
2. Enable/Disable always-on blocklist
3. Enable/Disable workday blocklist
4. Enable/Disable after-work blocklist
5. Enable/Disable overnight blocking
6. Set workday window
7. Set after-work window
8. Set overnight window
9. Backup all blocklists to this PC
10. Restore latest backup
```

After any state-changing action, it prints the refreshed router status.

## 5. Backup And Restore

Backups are stored locally in the repo `backups/` directory.

Backup filenames are:

- `quietwrt-always-YYYY-MM-DD-HHMMSS.txt`
- `quietwrt-workday-YYYY-MM-DD-HHMMSS.txt`
- `quietwrt-after-work-YYYY-MM-DD-HHMMSS.txt`

The restore option:

- looks in `backups/`
- chooses the newest matching `quietwrt-always-*` file
- chooses the newest matching `quietwrt-workday-*` file
- chooses the newest matching `quietwrt-after-work-*` file
- shows the selected filenames before restoring
- works with either file or both
- leaves the other router-side list untouched if only one backup file exists
- runs one sync after the restore completes

## 6. Schedule And Reconciliation

Fresh installs default to these windows:

- `04:00` to `16:30`: `always + workday`
- `16:30` to `19:00`: `always + after work`
- `19:00` to `04:00`: internet off when overnight blocking is enabled

QuietWrt reconciles state in three ways:

- immediately during install/update
- on boot through `/etc/init.d/quietwrt`
- through cron at each configured window boundary and every `10` minutes as a backstop

## 7. Managed Router State

Canonical QuietWrt data lives here:

- `/etc/quietwrt/always-blocked.txt`
- `/etc/quietwrt/workday-blocked.txt`
- `/etc/quietwrt/after-work-blocked.txt`
- `/etc/quietwrt/passthrough-rules.txt`

QuietWrt-managed firewall sections are:

- `firewall.quietwrt_dns_int`
- `firewall.quietwrt_dot_fwd`
- `firewall.quietwrt_curfew`

QuietWrt UCI state lives under:

- `quietwrt.settings.always_enabled`
- `quietwrt.settings.workday_enabled`
- `quietwrt.settings.after_work_enabled`
- `quietwrt.settings.overnight_enabled`
- `quietwrt.settings.workday_start`
- `quietwrt.settings.workday_end`
- `quietwrt.settings.after_work_start`
- `quietwrt.settings.after_work_end`
- `quietwrt.settings.overnight_start`
- `quietwrt.settings.overnight_end`
- `quietwrt.settings.schema_version`

## 8. Manual List Editing

You can edit the canonical files directly on the router, then run:

```sh
/usr/bin/quietwrtctl sync
```

Rules to keep in mind:

- `always-blocked.txt`, `workday-blocked.txt`, and `after-work-blocked.txt` must contain canonical lowercase hostnames
- `passthrough-rules.txt` is for non-block AdGuard rules that should be preserved
- bad manual edits fail closed; QuietWrt will report an error instead of silently rebuilding lossy state

The local web page is append-only by design:

- it can add entries to `always`, `workday`, or `after work`
- it cannot delete entries
- it cannot edit passthrough rules
- it cannot disable enforcement

## 9. Verify A Working Install

After install, confirm:

1. a site added to `Always blocked` is blocked during daytime hours
2. a site added to `Workday blocked` is blocked before `16:30`
3. a site added to `After work blocked` is blocked between `16:30` and `19:00`
4. internet access is unavailable between `19:00` and `04:00` when overnight blocking is enabled
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
/usr/bin/quietwrtctl set after_work on
/usr/bin/quietwrtctl set after_work off
/usr/bin/quietwrtctl set overnight on
/usr/bin/quietwrtctl set overnight off
/usr/bin/quietwrtctl schedule workday 0400 1630
/usr/bin/quietwrtctl schedule after_work 1630 1900
/usr/bin/quietwrtctl schedule overnight 1900 0400
/usr/bin/quietwrtctl restore --always /path/to/quietwrt-always-YYYY-MM-DD-HHMMSS.txt
/usr/bin/quietwrtctl restore --workday /path/to/quietwrt-workday-YYYY-MM-DD-HHMMSS.txt
/usr/bin/quietwrtctl restore --after-work /path/to/quietwrt-after-work-YYYY-MM-DD-HHMMSS.txt
cat /tmp/quietwrt-adguard-restart.log
cat /tmp/quietwrt-boot-sync.log
```
