IMAGE_AWG   ?= saucewg/awg:1.5.0
IMAGE_PANEL ?= saucewg/panel:1.5.0
IMAGE_WEB   ?= saucewg/web:1.5.0
PLATFORMS   ?=

AWG_GO_REF    ?= v0.2.19
AWG_TOOLS_REF ?= v1.0.20260618-2

BUILDX_FLAGS := $(if $(PLATFORMS),--platform $(PLATFORMS) --push,--load)

.PHONY: help build build-awg build-panel build-web push up down restart logs ps clean

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: build-awg build-panel build-web ## Build all three images

build-awg: ## Build the AmneziaWG node image
	docker buildx build $(BUILDX_FLAGS) \
		--build-arg AWG_GO_REF=$(AWG_GO_REF) \
		--build-arg AWG_TOOLS_REF=$(AWG_TOOLS_REF) \
		-t $(IMAGE_AWG) docker/awg

build-panel: ## Build the FastAPI panel image
	docker buildx build $(BUILDX_FLAGS) -f backend/Dockerfile -t $(IMAGE_PANEL) .

build-web: ## Build the Vue UI + Caddy image
	docker buildx build $(BUILDX_FLAGS) -f docker/caddy/Dockerfile -t $(IMAGE_WEB) .

push: ## Push all images to the configured registry
	docker push $(IMAGE_AWG)
	docker push $(IMAGE_PANEL)
	docker push $(IMAGE_WEB)

up: ## Start the entry node stack
	docker compose up -d

down: ## Stop the entry node stack
	docker compose down

restart: ## Recreate the entry node stack
	docker compose up -d --force-recreate

logs: ## Follow all logs
	docker compose logs -f --tail=100

ps: ## Show service status
	docker compose ps

clean: ## Stop and remove volumes (destroys keys and the database)
	docker compose down -v
