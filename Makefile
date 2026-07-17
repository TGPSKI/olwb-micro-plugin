# olwb-micro-plugin — dependency-free test targets.
# Requires only a `lua` interpreter (5.1+). No busted, no luarocks.

LUA ?= lua

.PHONY: all check test harness clean-run

all: check

## check: run the pure-module unit tests and the headless integration harness
check: test harness

## test: unit-test the pure modules (model/render/cmd/migrate/json)
test:
	@$(LUA) tests/run_tests.lua

## harness: load the whole plugin under a mocked micro API and drive a capture
harness:
	@$(LUA) tests/harness.lua

## install: symlink this repo into micro's plugin directory
install:
	@mkdir -p $$HOME/.config/micro/plug
	@ln -sfn $(CURDIR) $$HOME/.config/micro/plug/olwb
	@echo "linked $(CURDIR) -> $$HOME/.config/micro/plug/olwb"
