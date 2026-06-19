.PHONY: help deps dev dev-selfhost dev-stop dev-db-up dev-db-down dev-db-reset test frontend-install frontend-build frontend-dev ci-up ci-down ci-e2e e2e bench-dataset bench-quality bench-perf bench-reranking bench-cost bench-all bench-report bench-list gen-master-key

help:              ## List available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --- Dev (local Phoenix against staging services) ---

deps:              ## Fetch Elixir + frontend deps
	mix deps.get
	cd frontend && bun install

dev:               ## Start local Phoenix dev server (SaaS shape: Voyage + Clerk, port 4000)
	env $$(grep -v '^\#' .env.local | grep -v '^$$' | xargs) mix phx.server

dev-db-up:         ## Start the isolated local Postgres + Qdrant for dev (idempotent)
	docker compose -f docker-compose.dev.yml up -d --wait

dev-db-down:       ## Stop the local dev Postgres + Qdrant (keeps volumes)
	docker compose -f docker-compose.dev.yml down

dev-db-reset:      ## DESTROY the local dev DB + Qdrant volumes — fresh slate
	docker compose -f docker-compose.dev.yml down -v

dev-selfhost: dev-db-up  ## Start local Phoenix + Vite + isolated dev DB (selfhost shape)
	@# Brings up dev Postgres+Qdrant (containers), creates+migrates the schema,
	@# then runs Vite :5173 and Phoenix :4000. Trap reaps Vite when Phoenix
	@# exits so Ctrl-C cleans up both processes.
	@set -e ; \
	  echo "[dev-selfhost] ensuring schema is migrated…" ; \
	  env $$(grep -v '^\#' .env.local-selfhost | grep -v '^$$' | xargs) mix ecto.create --quiet ; \
	  env $$(grep -v '^\#' .env.local-selfhost | grep -v '^$$' | xargs) mix engram.prepare_database ; \
	  env $$(grep -v '^\#' .env.local-selfhost | grep -v '^$$' | xargs) mix ecto.migrate ; \
	  ( cd frontend && \
	      VITE_AUTH_PROVIDER=local VITE_BILLING_ENABLED=false VITE_CLERK_PUBLISHABLE_KEY= \
	      exec bun run dev --host 127.0.0.1 ) & \
	  VITE_PID=$$! ; \
	  trap "kill $$VITE_PID 2>/dev/null || true" EXIT INT TERM ; \
	  env $$(grep -v '^\#' .env.local-selfhost | grep -v '^$$' | xargs) mix phx.server

dev-stop:          ## Stop local Phoenix dev server (and any orphan Vite processes)
	@pkill -f "mix phx.server" 2>/dev/null && echo "Phoenix stopped" || echo "Phoenix not running"
	@# Phoenix's watcher spawns node-vite as a Port child. SIGKILL on BEAM
	@# leaves the OS-level node listening on :5173+, so reap any orphans here.
	@for port in $$(seq 5173 5199); do \
	  pid=$$(lsof -t -iTCP:$$port -sTCP:LISTEN 2>/dev/null); \
	  if [ -n "$$pid" ]; then kill -9 $$pid 2>/dev/null && echo "Killed stray Vite on :$$port (pid $$pid)"; fi; \
	done

# --- Backend ---

test:              ## Run mix test
	mix test

# --- Frontend ---

frontend-install:  ## Install frontend deps via bun
	cd frontend && bun install

frontend-build:    ## Build frontend (vite → priv/static/app)
	cd frontend && bun run build

frontend-dev:      ## Run Vite dev server standalone
	cd frontend && bun run dev

# --- CI Stack ---

ci-up:             ## Start CI stack (port 8100)
	docker compose -f ci/compose.yml -p engram-ci up -d --build --wait

ci-down:           ## Tear down CI stack
	docker compose -f ci/compose.yml -p engram-ci down -v --remove-orphans

ci-e2e: ci-up      ## Bring up CI stack and run e2e tests
	cd e2e && ENGRAM_API_URL=http://localhost:8100 python3 -m pytest tests/ -v

# --- E2E ---

e2e:               ## Run e2e tests against http://localhost:8100
	cd e2e && ENGRAM_API_URL=http://localhost:8100 python3 -m pytest tests/ -v

# --- Embedding Benchmarks ---

bench-dataset:     ## Build benchmark dataset
	python3 -m benchmarks build-dataset --save-raw

bench-quality:     ## Run quality benchmarks
	python3 -m benchmarks run quality

bench-perf:        ## Run performance benchmarks
	python3 -m benchmarks run performance

bench-reranking:   ## Run reranker benchmarks
	python3 -m benchmarks run reranking

bench-cost:        ## Run cost benchmarks
	python3 -m benchmarks run cost

bench-all:         ## Run every benchmark
	python3 -m benchmarks run all

bench-report:      ## Generate consolidated benchmark report
	python3 -m benchmarks report

bench-list:        ## List configured embedding models
	python3 -m benchmarks list models


# --- Dev UX ---

gen-master-key:    ## Generate base64 master key
	@openssl rand -base64 32
