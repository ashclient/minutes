# Minutes Google sign-in server

The Mac opens Google's browser sign-in and verifies a random state on its local 127.0.0.1 callback, with PKCE S256. This Worker performs only the Google token exchange and refresh, adding the Desktop registration secret from a private Worker binding. The app receives its own access/refresh tokens, stores them in Keychain, and calls Google Calendar directly. The Worker never receives recordings, transcripts, notes, or calendar event bodies. It has no database, cookies, analytics, or application logging. Tokens pass through its memory but are not persisted by this code.

## One-time publisher deployment

1. In this directory run `npm ci` and `npx wrangler login` using the Cloudflare account that will own the service. No Cloudflare credentials are present in this repository.
2. Run `npx wrangler secret put GOOGLE_CLIENT_ID`, then `npx wrangler secret put GOOGLE_CLIENT_SECRET`. Supply the values from the existing **Desktop** OAuth registration privately at those prompts. Do not commit them, add them to `wrangler.toml`, or set them as public build variables. This keeps the existing Google client and loopback redirect; no Web client is needed.
3. Run `npm test`, `npm run check`, then `npm run deploy`. Choose a unique rate-limit namespace ID in `wrangler.toml` if 1001 is already used by another service in the account. The resulting service URL is the actual Workers hostname or your custom HTTPS domain.
4. Confirm `GET https://YOUR-DEPLOYED-HOST/health` returns HTTP 200 with `ready: true`. A dry run does not deploy or establish readiness.
5. Set the repository's **public Actions variables** `MINUTES_GOOGLE_CLIENT_ID` (same Desktop client ID) and `MINUTES_GOOGLE_AUTH_URL` (`https://YOUR-DEPLOYED-HOST/v1/token`). The Google client **secret is never an app build input**. Local builds may set the same two environment variables.
6. Build/test a versioned app, then sign in with a real account and verify a subsequent refresh. Only after that publish a new app release. Merely building this branch does not activate shared sign-in.

End users then click **Connections → Google Calendar → Sign in with Google**. No per-user JSON import is required. Existing imported clients with another ID stay on their own registration. For the same ID, the public hosted configuration takes priority without discarding saved tokens. Legacy custom clients still exchange directly with Google using the user's Keychain-stored configuration.

Google's consent-screen publishing/verification and Workspace administrator restrictions are independent of deployment. The service does not bypass Google consent or verification. If the Desktop credential rotates, update only the private Worker secret; users of the hosted configuration need no app update for that rotation.

## Boundaries and testing

- Fixed upstream `https://oauth2.googleapis.com/token`; redirects are refused, no arbitrary proxy targets.
- Only `authorization_code` with PKCE proof and a canonical loopback redirect, or `refresh_token`, for the configured client ID. Duplicates, unknown fields, caller-supplied secrets and other grants are rejected.
- Native form POST requests only; browser Origin requests and CORS preflights are rejected. These are abuse controls, not proof that the caller is an unmodified Minutes binary. The authorization code plus verifier, or the private refresh token, is the caller's authorization proof. Client IDs and app binaries are public.
- Requests and responses are bounded; upstream timeout is 20 seconds. No automatic retries of one-use authorization codes. Only tokens granted exactly the two read-only Calendar scopes are returned. Missing, partial or broader grants are rejected. Errors return fixed messages, never provider diagnostics. An explicit response allowlist excludes secrets and unrelated identity fields.
- Cloudflare edge per-IP limits are approximate and per-location, not a worldwide quota. Shared networks may hit limits; tune the configured limit for deployment size. Deploy behind appropriate account-level abuse controls if needed.
- Application observability is disabled by default. Keep request-body/header capture disabled in any additional logging, tracing or third-party monitoring you enable. Cloudflare still processes requests as the host.
- `npm test` uses synthetic values and mocked Google responses. `npm run check` validates Worker packaging; neither proves a real Google account can sign in. Native Swift tests cover request routing, secret exclusion and existing token identity. Live sign-in/refresh remains a deployment acceptance check.

Official references:
- https://developers.google.com/identity/protocols/oauth2/#installed
- https://developers.google.com/identity/protocols/oauth2/native-app
- https://developers.cloudflare.com/workers/configuration/secrets/
- https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/
