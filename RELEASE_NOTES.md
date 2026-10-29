# Minutes 2.5.3

- Google connection status checks no longer read credentials or request authentication.
- Successful credential reads are reused within the running app, so parallel calendar requests do not each read the same Keychain item.
- Briefly suppresses repeated requests after a denied read. Failed access is never treated as a missing credential.
- Token refresh, key changes and disconnect update the in-memory cache only after Keychain storage succeeds.

For existing authorization prompts, enter the login keychain password and choose Always Allow for each Minutes item. This release retains Keychain protection. Because current releases use ad-hoc signatures, updating the app can still require renewed trust; this change reduces repeated access requests within a running session.
