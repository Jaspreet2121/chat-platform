# Auth Service

Owns authentication and device-session data.

Current scope:

- OTP application shell.
- Boundary modules for OTP, tokens, sessions, devices, and rate limits.
- Offline-safe OTP code generation/hash verification, signed access-token envelope helpers, refresh-token hashing/rotation planning, and rate-limit key/policy planning.
- PostgreSQL repo placeholder for `users_auth`, `refresh_tokens`, `device_sessions`, `login_attempts`, and `verification_codes`.
- Repo connections are not started yet; this foundation should boot without requiring database access.
- No signup/login API flow persistence, OTP delivery, Redis-backed rate-limit execution, or session authorization yet.

Future events:

- `auth.user_registered.v1`
- `auth.user_logged_in.v1`
- `auth.user_logged_out.v1`
- `auth.device_registered.v1`
