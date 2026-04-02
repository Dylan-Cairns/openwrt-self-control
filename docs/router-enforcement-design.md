# Router Enforcement Design

## Summary

Version 1 uses the stock `GL.iNet` firmware on the `GL-MT3000` in `Router` mode.

Enforcement is:

- `AdGuard Home` for domain blocking
- firewall rules to reduce DNS bypass
- `IPv6` disabled

## Responsibilities

- send LAN DNS traffic through the router
- block domains from the active blocklist
- honor explicit exceptions
- keep enforcement working across reboot and failed updates

## DNS

`AdGuard Home` is the main blocking engine.

- clients get the router as their DNS server
- the policy manager writes the active blocklist and exception data
- blocked domains fail at DNS resolution

## Firewall

Version 1 should at least:

- allow LAN clients to query the router for DNS
- block or redirect direct WAN `TCP/UDP 53`
- block direct WAN `TCP/UDP 853`
- allow only explicit required exceptions for services such as the work VPN

This is not meant to detect every VPN or proxy. It only removes the easiest bypasses.

## Exceptions

- exceptions override block entries
- exceptions should stay narrow
- the main expected use is required work connectivity

## Boot And Failure Behavior

- keep a last-known-good policy on the router
- re-apply it on boot
- if a new policy fails validation or apply, keep the working one

## Acceptance Criteria

- a normal LAN client is filtered by the active blocklist
- direct external DNS on `53` does not bypass filtering
- direct `DoT` on `853` does not bypass filtering
- required exceptions still work
- a bad update does not remove the active policy
