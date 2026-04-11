# Router Enforcement Design

## Summary

The current design uses the stock `GL.iNet` firmware on the `GL-MT3000` in `Router` mode.

Enforcement is:

- `AdGuard Home` for domain blocking
- firewall rules to reduce DNS bypass
- a scheduled firewall curfew for full nightly internet shutdown
- `IPv6` disabled

## Responsibilities

- send LAN DNS traffic through the router
- block domains from the active policy
- preserve passthrough AdGuard rules
- disable all `LAN -> WAN` internet access from `18:30` to `04:00`
- keep enforcement working across reboot and failed updates

## DNS

`AdGuard Home` remains the main domain blocking engine.

- clients get the router as their DNS server
- the policy manager writes the active `user_rules` set
- active `user_rules` depend on the current mode:
  - `always + workday`
  - `always only`
  - `internet off`

## Firewall

The router should enforce:

- LAN clients can query the router for DNS
- direct WAN `TCP/UDP 53` is redirected or blocked
- direct WAN `TCP/UDP 853` is blocked
- a managed `LAN -> WAN` reject rule named `QuietWrt-Internet-Curfew`

The curfew rule is:

- disabled from `04:00` to `18:30`
- enabled from `18:30` to `04:00`

This blocks internet access while still allowing access to the router itself.

## Schedule

`cron` runs `quietwrtctl sync` at:

- `04:00`
- `16:30`
- `18:30`

Each run:

- computes the current mode
- rewrites AdGuard `user_rules`
- enables or disables the firewall curfew rule

## Boot And Failure Behavior

- canonical blocklist files live in `/etc/quietwrt/`
- AdGuard config changes are written atomically
- if AdGuard restart fails, the previous config is restored
- running `quietwrtctl install` re-installs the schedule and applies the current mode

## Acceptance Criteria

- a normal LAN client is filtered by the correct active blocklists for the current time
- direct external DNS on `53` does not bypass filtering
- direct `DoT` on `853` does not bypass filtering
- internet is fully unavailable from `18:30` to `04:00`
- a bad apply does not leave AdGuard in a broken state
