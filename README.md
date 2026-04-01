# MT3000 Focus Router

This repo documents and plans a self-imposed distraction-blocking setup built around a `GL.iNet GL-MT3000` router.

## Overview

The router will sit between the modem and local devices and enforce a blocklist of distracting domains and related bypass paths.

Physical security is assumed to be handled outside this repo:

- The router and modem are stored in a locked enclosure.
- The lock combination is stored in `lockmeout.online` with a delay.
- The router admin password is also stored in `lockmeout.online` with a delay.

Those controls are part of the operating model, but not part of the software design documented here.

## Goals

- Block distracting websites and services.
- Make bypassing the blocklist meaningfully harder.
- Allow exceptions for required services such as a work VPN.
- Pull in published public sources for categories that are tedious to maintain manually, such as:
  - Lemmy instances
  - Invidious and similar alternative frontends
  - VPN-related domains or endpoints
  - Other federated or clone social platforms
- Provide a simple local web app that:
  - shows the current effective blocklist
  - allows append-only manual additions to the local blocklist
- Keep the system understandable enough to operate and extend over time.

## Non-Goals For The First Version

- Full detection of every VPN, proxy, tunnel, or bypass technique
- A general-purpose router admin UI
- Remote internet-facing management

## High-Level Design

The system has five main parts.

### 1. Policy Inputs

These are the raw inputs used to build the effective blocklist:

- local blocklist
- downloaded public-source lists
- explicit exceptions, such as work-related VPN endpoints

The local blocklist is the manually maintained source of truth for domains you explicitly want blocked.

### 2. Remote List Updater

A scheduled updater fetches third-party sources that track categories of domains worth blocking. Its responsibilities are:

- fetch source data on a regular schedule
- normalize domains and instance lists into a consistent format
- deduplicate entries
- keep source metadata for traceability
- store a last-known-good copy so a bad upstream feed does not corrupt the active policy

This component reduces manual maintenance, but downloaded lists are treated as inputs to review and merge, not as fully trusted truth.

### 3. Policy Compiler

The compiler turns raw inputs into one router-ready effective blocklist.

Its responsibilities are:

- merge the local blocklist and downloaded data
- apply precedence rules
- produce a clean effective list for enforcement
- preserve local entries across refreshes

This is the point where the repo's source data becomes a concrete policy artifact the router can enforce.

### 4. Enforcement Layer

The router needs to do more than basic DNS blocking.

The enforcement layer is expected to include:

- DNS-based domain blocking
- firewall rules that reduce easy bypass paths
- handling for IPv6, either by enforcing equivalent policy or disabling it initially
- explicit allowances for required services such as a work VPN

This project should assume that DNS-only filtering is not enough on its own.

### 5. Local Management App

A small LAN-only web app will provide the minimal interface needed during daily use.

Initial responsibilities:

- show the current effective blocklist
- show basic status such as last update time and active source counts
- allow append-only additions to the local manual blocklist

Deliberate restrictions:

- no delete
- no disable switch
- no policy editor
- no access from the public internet
- separate from full router administration

The app exists to make the system stricter in practice, not easier to weaken.

## Operational Flow

At a high level, the system works like this:

1. The updater fetches public lists on a schedule.
2. The fetched data is normalized and stored.
3. The compiler merges downloaded data with the local blocklist and exceptions.
4. The router applies the resulting effective blocklist.
5. The local web app exposes the current state and allows new block entries to the local blocklist.
6. A manual addition triggers recompilation and re-application of the effective policy.

## Important Constraints

- The system must survive bad upstream data without wiping out the active blocklist.
- The local blocklist must be durable and easy to preserve.
- Work-related exceptions must be explicit and narrowly scoped.
- LAN-only management is preferred over any wider exposure.
- The design should keep auditability in mind: what was blocked, where it came from, and when it changed.

## Planned Documentation

This `README` is the project overview only. More detailed docs will be added later for:

- overall technical architecture
- list updater design
- local management app
- router enforcement design
- data model and storage
- deployment and operating procedures

## Status

Planning stage.
