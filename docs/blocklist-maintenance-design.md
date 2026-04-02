# Blocklist Maintenance Design

## Summary

Version 1 uses two manually maintained inputs:

- `local blocklist`
- `exception list`

## Update Paths

There are two ways to change the blocklist:

1. edit the maintained files directly
2. add a new entry through the local management app

Both paths update the same local data.

## Rules

- blocklist entries are manually maintained
- exceptions are narrow carve-outs for required services
- exceptions override block entries
- the local app can add block entries but cannot edit exceptions

## Validation

New entries should be:

- trimmed
- lowercased
- stripped of trailing dots
- rejected if malformed
- ignored if already present

The system should reject bad input instead of guessing.

## Flow

1. Update the local blocklist or exception list.
2. Run the policy manager.
3. Keep the current policy if validation or apply fails.

## Notes

- batch edits can be done directly in the repo
- Codex can be used for larger list changes
- simple file-based storage is enough for v1
