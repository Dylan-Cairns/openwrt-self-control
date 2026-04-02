# MT3000 Focus Router

This repo documents a distraction-blocking setup built around a `GL.iNet GL-MT3000`.

## Goal

- keep a single always-on blocklist on the router
- make bypass harder than device-side blocking
- preserve narrow exceptions for required services such as a work VPN
- provide a small LAN-only page that shows the current blocklist and lets new entries be appended

## V1 Design

- `local blocklist`
  - manually maintained list of blocked domains
- `exception list`
  - narrow carve-outs for required services
- `policy manager`
  - validates inputs, builds router-ready policy, applies it, keeps a last-known-good version
- `router enforcement`
  - `AdGuard Home` for domain blocking
  - firewall rules to reduce bypass
  - `IPv6` disabled in v1
- `local management app`
  - LAN-only
  - read-only blocklist view
  - one append-only add-entry action

## Operating Model

- the router is the enforcement point
- client devices are not trusted
- blocklist changes are manual or come from the local app
- the active policy should survive reboot and bad updates

## Docs

- `docs/technical-architecture.md`
- `docs/router-enforcement-design.md`
- `docs/blocklist-maintenance-design.md`
- `docs/local-management-app-design.md`
