# Blocklist Maintenance Design

## Summary

The router keeps three local files:

- `always blocked`
- `workday blocked`
- `passthrough rules`

`Always blocked` and `workday blocked` store canonical hostnames.
`Passthrough rules` preserves non-block AdGuard rules that should survive migration and recompiles.

## Update Paths

There are two ways to change the blocklists:

1. edit the maintained files directly
2. add a new entry through the local management app

Both paths update the same canonical local files.

## Rules

- `always blocked` is active whenever internet access is available
- `workday blocked` is active from `04:00` to `16:30`
- from `16:30` to `18:30`, only `always blocked` remains active
- from `18:30` to `04:00`, internet access is disabled entirely
- the local app can add block entries but cannot edit passthrough rules

## Validation

New entries should be:

- trimmed
- lowercased
- stripped of trailing dots
- rejected if malformed
- ignored if already present in the same list
- rejected for `workday` if already present in `always`
- moved from `workday` to `always` if the user intentionally makes the block stricter

The system should reject bad input instead of guessing.

## Flow

1. Update one of the local files.
2. Run `quietwrtctl sync`.
3. Keep the current config if validation, write, or restart fails.

## Notes

- batch edits can be done directly in the repo or on the router
- Codex can be used for larger list changes
- plain text storage is enough for the current version
