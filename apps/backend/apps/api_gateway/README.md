# API Gateway

Public HTTP entry point for mobile, web, admin, and business portal clients.

Current scope:

- Minimal Phoenix endpoint and router.
- `GET /health` health check.
- No authentication, authorization, or request proxying yet.

Future scope:

- API versioning under `/api/v1`.
- Authentication middleware.
- Request validation and rate limiting.
- Routing to backend services.
