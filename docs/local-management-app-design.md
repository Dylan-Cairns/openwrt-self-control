# Local Management App Design

## Summary

The local management app is one small LAN-only page on the router.

It does two things:

- show the current blocklist and basic status
- append one new blocked entry

## Page Shape

The page should have:

- a read-only blocklist view
- a text input
- a submit button
- a result message for the last submission

## Submission Flow

1. Enter a domain, hostname, or full URL.
2. Submit the form.
3. Normalize and validate the value.
4. Append it to the local blocklist if accepted.
5. Run the policy manager.
6. Reload the page with the result.

## Rules

- LAN-only
- append-only
- no delete
- no disable
- no exception editing
- no router admin features

## Validation

The app should:

- trim whitespace
- accept raw domains or URLs
- extract the hostname from a URL
- lowercase the result
- remove trailing dots
- reject malformed input
- treat duplicates as a no-op

## Runtime

Version 1 should be as simple as possible:

- served directly from the router
- one page
- one local submit handler
- the page and submit handler live in the same app
