Minutes 2.8.3 adds hosted Google sign-in and a public app website.

- Connect Google Calendar through your browser without importing an OAuth setup file.
- Token exchange and refresh use the private sign-in service. Only the public client ID and HTTPS service route are bundled; the Google application secret stays in private server configuration.
- Existing same-client connections can use the service without discarding saved refresh tokens. Distinct custom clients remain supported.
- Built-in checks reject secret-bearing app configuration. Server checks enforce PKCE/loopback proof, bounded requests, read-only Calendar scopes and sanitized errors, without storing user tokens.
- Homepage, Privacy Policy, Terms of Service and Support are published at https://ashclient.github.io/minutes/ .

Automated native Mac checks cover service reachability and rejection of a fabricated authorization code, not a real user's successful consent or token refresh. Google account, consent-screen and verification policies still apply.
