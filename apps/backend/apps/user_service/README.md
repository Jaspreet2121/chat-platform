# User Service

Owns user profile, settings, and privacy preferences.

Current scope:

- OTP application shell.
- Boundary modules for profiles, settings, and privacy.
- PostgreSQL repo placeholder for `user_profiles`, `user_settings`, and `user_privacy_settings`.
- Repo connections are not started yet; this foundation should boot without requiring database access.
- Profile API skeletons return placeholders only. No database writes or search logic yet.

Future events:

- `user.profile_created.v1`
- `user.profile_updated.v1`
- `user.avatar_updated.v1`
