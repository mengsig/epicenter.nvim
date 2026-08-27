NVIM ?= nvim
LUA_FILES := $(shell find lua plugin tests -name '*.lua' -not -path 'tests/fixtures/*')

.PHONY: test lint fmt doc all

all: lint test

test:
	$(NVIM) --headless --clean -u tests/minimal_init.lua -l tests/run.lua

lint:
	@if command -v stylua >/dev/null 2>&1; then \
		stylua --check $(LUA_FILES); \
	else \
		echo "note: stylua not installed - skipping format check"; \
	fi
	@if command -v luacheck >/dev/null 2>&1; then \
		luacheck $(LUA_FILES); \
	else \
		echo "note: luacheck not installed - skipping lint"; \
	fi

fmt:
	stylua $(LUA_FILES)

doc:
	$(NVIM) --headless --clean -c 'helptags doc' -c 'quit'
