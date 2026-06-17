# Repository Guidelines

## Project Structure & Module Organization

This repository is in Phase 0: documentation and architecture planning. Keep architecture, product, testing, API, data, security, and roadmap material under `docs/`, following the numbered topic folders already in place. Important AI/developer context lives in `docs/00-ai-context/`, especially `AI_CONTEXT.md`, `CODEMAP.md`, and `SESSION_LOG.md`.

Application code is planned under `apps/frontend/` for the Nx/TypeScript frontend stack and `apps/backend/` for Phoenix/Elixir services. Local infrastructure lives in `infra/docker/`, with Docker Compose configuration in `infra/docker/docker-compose.yml`.

## Build, Test, and Development Commands

There is no full application build yet. Current useful commands are:

```bash
cd infra/docker
docker compose up -d
docker compose down
docker compose ps
```

Use `docker compose up -d` to start local dependencies such as PostgreSQL, Redis, ScyllaDB, Kafka, MinIO, and Mailpit. Use `docker compose ps` to check service health and exposed ports. Add frontend/backend build and test commands here once package manifests are introduced.

## Coding Style & Naming Conventions

Use Markdown headings and concise prose for documentation. Keep filenames descriptive and uppercase for major repository documents, for example `PRODUCT_REQUIREMENTS.md` and `DATABASE_DESIGN.md`. Preserve the numbered `docs/` folder taxonomy when adding new planning material.

When application code is added, follow the intended stack conventions: TypeScript for frontend packages, Elixir/Phoenix conventions for backend services, and environment-specific configuration outside committed secrets.

## Testing Guidelines

The testing strategy is currently documented in `docs/10-testing/TESTING_STRATEGY.md`; no executable test suite exists yet. When adding code, colocate or clearly group tests near the owning app or service, and document the exact test command in this file and the relevant app README. Prefer clear test names that describe behavior, such as `sends_read_receipt_when_message_is_opened`.

## Commit & Pull Request Guidelines

Recent commits use Conventional Commit-style prefixes, for example `chore: initialize project documentation`. Continue with short, imperative messages such as `docs: update service catalog` or `chore: add local infra notes`.

Pull requests should include a brief summary, affected areas such as `docs/06-data` or `infra/docker`, linked issues or decisions when relevant, and screenshots only for user-facing UI changes. For architecture changes, update the decision log or related docs in the same PR.

## Security & Configuration Tips

Do not commit secrets, local credentials, generated database dumps, or private keys. Keep configuration examples generic and document required local services in `docs/09-devops/LOCAL_DEV_SETUP.md`.
