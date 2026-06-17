.PHONY: backend-test backend-test-integration backend-format backend-compile web-dev web-build web-lint infra-up infra-down

backend-test:
	cd apps/backend && mix test

backend-test-integration:
	cd apps/backend && mix test --include postgres_integration

backend-format:
	cd apps/backend && mix format

backend-compile:
	cd apps/backend && mix compile

web-dev:
	cd apps/web && npm run dev

web-build:
	cd apps/web && npm run build

web-lint:
	cd apps/web && npm run lint

infra-up:
	docker compose -f infra/docker/docker-compose.yml up -d

infra-down:
	docker compose -f infra/docker/docker-compose.yml down
