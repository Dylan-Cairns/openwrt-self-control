# Technical Architecture

## Summary

Version 1 is a small on-router system with three parts:

- `Policy Manager`
- `Router Enforcement`
- `Local Management App`

Everything runs on the `GL.iNet GL-MT3000`.

## Components

### Policy Manager

- reads the local blocklist and exception list
- validates and normalizes input
- builds the active policy
- applies updates safely
- keeps the last-known-good policy

### Router Enforcement

- uses `AdGuard Home` for domain blocking
- uses firewall rules to reduce bypass
- keeps `IPv6` disabled in v1

### Local Management App

- LAN-only
- shows current status and blocklist
- accepts one new blocked domain or URL at a time
- triggers the policy manager after a successful submission

## Persistent State

The router stores:

- local blocklist
- exception list
- compiled policy artifacts
- active revision metadata
- last apply result

## Main Flows

### Manual Edit

1. Update the local blocklist or exception list.
2. Run the policy manager.
3. Apply the new policy if validation succeeds.

### App Addition

1. Submit a domain or URL in the local app.
2. Normalize and append it to the local blocklist.
3. Run the policy manager.
4. Reload the page with the result.

### Boot

1. Router starts.
2. Last-known-good policy is re-applied.
3. Normal enforcement resumes.

## Boundaries

- the router is the trust boundary
- client devices are not trusted
- the local app is not an admin console
- the local app cannot delete entries, edit exceptions, or disable enforcement
