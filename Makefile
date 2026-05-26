.PHONY: help deps dev dev-selfhost dev-stop test backend-build backend-up backend-down frontend-install frontend-build frontend-dev dev-ui-staging ci-up ci-down ci-e2e e2e bench-dataset bench-quality bench-perf bench-reranking bench-cost bench-all bench-report bench-list parity-mix parity-bash parity-ci-up parity-ci-down gen-master-key

help:              ## List available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --- Dev (local Phoenix against staging services) ---

deps:              ## Fetch Elixir + frontend deps
	mix deps.get
	cd frontend && bun install

dev:               ## Start local Phoenix dev server (SaaS shape: Voyage + Clerk, port 4000)
	env $$(grep -v '^\#' .env.local | grep -v '^$$' | xargs) mix phx.server

dev-selfhost:      ## Start local Phoenix dev server (selfhost shape: Ollama + local auth, port 4001)
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

backend-build:     ## Build engram_elixir docker image
	docker compose -f docker-compose.elixir.yml build engram_elixir

backend-up:        ## Start full Elixir stack (Phoenix + Postgres + Qdrant)
	docker compose -f docker-compose.elixir.yml up -d --wait

backend-down:      ## Stop Elixir stack
	docker compose -f docker-compose.elixir.yml down

# --- Frontend ---

frontend-install:  ## Install frontend deps via bun
	cd frontend && bun install

frontend-build:    ## Build frontend (vite → priv/static/app)
	cd frontend && bun run build

frontend-dev:      ## Run Vite dev server standalone
	cd frontend && bun run dev

dev-ui-staging:    ## Vite (:5173, LAN) against staging backend — UI-only, no local Phoenix/Oban
	@# Must run under node (not bun): the IPv4 fix in vite.config.ts uses node DNS
	@# APIs bun ignores, and node needs VITE_API_TARGET passed inline (it doesn't
	@# auto-load .env.local into process.env). Clerk vars come from frontend/.env.local.
	@# See docs/context/dev-iteration-loop.md → "Iterating against the staging backend".
	cd frontend && VITE_API_TARGET=https://staging.engram.page node node_modules/.bin/vite --host 0.0.0.0

# --- CI Stack ---

ci-up:             ## Start CI stack (port 8100)
	docker compose -f docker-compose.ci.yml -p engram-ci up -d --build --wait

ci-down:           ## Tear down CI stack
	docker compose -f docker-compose.ci.yml -p engram-ci down -v --remove-orphans

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

# --- Parity Validation ---

parity-mix:        ## Run mix parity.validate (internal module validation)
	env $$(grep -v '^\#' .env.elixir | grep -v '^$$' | xargs) mix parity.validate

parity-bash:       ## Run validate_parity.sh (deployed system validation)
	VOYAGE_API_KEY=$${VOYAGE_API_KEY} bash validate_parity.sh

parity-ci-up:      ## Start CI stack in parity mode (requires VOYAGE_API_KEY)
	VOYAGE_API_KEY=$${VOYAGE_API_KEY} docker compose -f docker-compose.ci.yml -f docker-compose.parity.yml -p engram-ci up -d --build --wait

parity-ci-down:    ## Tear down parity CI stack
	docker compose -f docker-compose.ci.yml -f docker-compose.parity.yml -p engram-ci down -v --remove-orphans

# --- Dev UX ---

gen-master-key:    ## Generate base64 master key
	@openssl rand -base64 32
