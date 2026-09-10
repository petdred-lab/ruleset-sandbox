SHELL := /bin/bash /1
APP     := go-deploy-demo
IMAGE   ?= ghcr.io/acme/$(APP)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w \
  -X github.com/acme/$(APP)/internal/version.Version=$(VERSION) \
  -X github.com/acme/$(APP)/internal/version.Commit=$(COMMIT) \
  -X github.com/acme/$(APP)/internal/version.BuildTime=$(BUILD_TIME)

DB_URL ?= postgres://app:app@localhost:5432/appdb?sslmode=disable

.DEFAULT_GOAL := help

help: ## แสดงคำสั่งทั้งหมด
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

## ---------- พัฒนา ----------
run: ## รันแอปในเครื่อง
	DATABASE_URL="$(DB_URL)" go run -ldflags "$(LDFLAGS)" ./cmd/api

build: ## build binary
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/api ./cmd/api

fmt: ## จัดรูปแบบโค้ด
	gofmt -w .

## ---------- ตรวจสอบ ----------
vet: ## go vet
	go vet ./...

lint: vet ## vet + gofmt check + shellcheck
	@test -z "$$(gofmt -l .)" || { echo "ยังมีไฟล์ที่ไม่ได้ format:"; gofmt -l .; exit 1; }
	@command -v shellcheck >/dev/null && shellcheck -S warning deploy/scripts/*.sh || echo "ข้าม shellcheck"

test: ## unit test + race detector
	go test ./... -race -count=1

test-cover: ## unit test พร้อมรายงาน coverage
	go test ./... -race -covermode=atomic -coverprofile=coverage.out
	go tool cover -func=coverage.out | tail -1

test-integration: ## integration test (ต้องมี postgres)
	TEST_DATABASE_URL="$(DB_URL)" go test -tags=integration ./internal/repository/... -v -count=1

test-deploy: ## test logic ของสคริปต์ deploy
	IMAGE=$(IMAGE) ./deploy/scripts/lib_test.sh

test-smoke: ## smoke test กับ URL ที่ระบุ  (make test-smoke URL=http://localhost:8080 TAG=v1.5.0)
	SMOKE_BASE_URL="$(URL)" EXPECT_VERSION="$(TAG)" go test ./tests/smoke/... -v -count=1

verify: lint test test-deploy ## ด่านเดียวกับที่ CI รัน

## ---------- Docker / DB ----------
docker-build: ## build image ในเครื่อง
	docker build --build-arg VERSION=$(VERSION) --build-arg COMMIT=$(COMMIT) \
	  --build-arg BUILD_TIME=$(BUILD_TIME) -t $(IMAGE):$(VERSION) .

up: ## ยกทั้ง stack ในเครื่อง (db + migrate + api)
	docker compose up -d --build

down: ## ปิด stack ในเครื่อง
	docker compose down -v

migrate-up: ## รัน migration ขึ้น
	migrate -path migrations -database "$(DB_URL)" up

migrate-down: ## ถอย migration 1 ขั้น
	migrate -path migrations -database "$(DB_URL)" down 1

migrate-new: ## สร้าง migration ใหม่  (make migrate-new NAME=add_xxx)
	migrate create -ext sql -dir migrations -seq $(NAME)

## ---------- โหมดจำลอง (ไม่ต้องมี VM) ----------
sim-up: ## จำลอง: ยก db + nginx + deploy v1.0.0 บนเครื่องตัวเอง
	./deploy/scripts/simulate.sh up

sim-probe: ## จำลอง: ยิง traffic ต่อเนื่องเพื่อวัด downtime (รันในหน้าต่างแยก)
	./deploy/scripts/simulate.sh probe

sim-deploy: ## จำลอง: build + deploy ทับ  (make sim-deploy V=v1.1.0)
	./deploy/scripts/simulate.sh deploy $(V)

sim-rollback: ## จำลอง: rollback
	./deploy/scripts/simulate.sh rollback $(V)

sim-status: ## จำลอง: ดูสถานะ blue/green
	./deploy/scripts/simulate.sh status

sim-down: ## จำลอง: เก็บกวาดทั้งหมด
	./deploy/scripts/simulate.sh down

## ---------- Release / Deploy ----------
tag: ## ตีแท็กและ push  (make tag V=v1.5.0)
	@test -n "$(V)" || { echo "ต้องระบุ V เช่น make tag V=v1.5.0"; exit 1; }
	@echo "$(V)" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$$' \
	  || { echo "รูปแบบต้องเป็น semver: vX.Y.Z"; exit 1; }
	git tag -a $(V) -m "release $(V)"
	git push origin $(V)

deploy: ## deploy บนเครื่อง production  (make deploy V=v1.5.0)
	./deploy/scripts/deploy.sh $(V)

rollback: ## rollback (เว้น V ไว้ = ถอยไปสีก่อนหน้า)
	./deploy/scripts/rollback.sh $(V)

status: ## ดูสถานะ blue/green
	./deploy/scripts/status.sh

.PHONY: help run build fmt vet lint test test-cover test-integration test-deploy \
        test-smoke verify docker-build up down migrate-up migrate-down migrate-new \
        tag deploy rollback status \
        sim-up sim-probe sim-deploy sim-rollback sim-status sim-down
