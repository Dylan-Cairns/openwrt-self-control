# Local Management App Design

## Summary

The QuietWrt local management app is one small LAN-only page on the router.

It does three things:

- show current status
- show the `always` and `workday` blocklists
- append one new blocked entry to either list

## Page Shape

The page should have:

- current mode and protection status
- a text input
- a destination selector for `Always blocked` or `Workday blocked`
- a submit button
- a result message for the last submission
- read-only views for both blocklists
- a read-only view of the currently active AdGuard rules

## Submission Flow

1. Enter a domain, hostname, or full URL.
2. Choose `Always blocked` or `Workday blocked`.
3. Submit the form.
4. Normalize and validate the value.
5. Update the selected canonical list.
6. Run the policy manager.
7. Reload the page with the result.

## Rules

- LAN-only
- append-only from the UI
- no delete
- no disable
- no passthrough-rule editing
- no router admin features

## Validation

The app should:

- trim whitespace
- accept raw domains or URLs
- extract the hostname from a URL
- lowercase the result
- remove trailing dots
- reject malformed input
- reject same-list duplicates as a no-op
- reject adding a host to `workday` if it already exists in `always`
- move a host from `workday` to `always` if the user makes it stricter

## Runtime

The page should stay simple:

- served directly from the router
- one page
- one local submit handler
- thin CGI wrapper over shared policy code
