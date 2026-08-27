NVIM ?= nvim
LUA_FILES := $(shell find lua plugin tests -name '*.lua' -not -path 'tests/fixtures/*')

.PHONY: test smoke lint fmt doc all

all: lint test

test:
	$(NVIM) --headless --clean -u tests/minimal_init.lua -l tests/run.lua

smoke:
	$(NVIM) --headless --clean --cmd 'set runtimepath^=.' -l tests/smoke.lua

lint:
	@if command -v stylua >/dev/null 2>&1; then \
		stylua --check $(LUA_FILES); \
	else \
		echo "note: stylua not installed - skipping format check"; \
	fi
	@if command -v luacheck >/dev/null 2>&1; then \
		luacheck $(LUA_FILES); \
	elif [ "$(LINT_SKIP_LUACHECK)" = "1" ]; then \
		echo "note: luacheck not installed - skipping lint (LINT_SKIP_LUACHECK=1)"; \
	else \
		echo "error: luacheck not installed - set LINT_SKIP_LUACHECK=1 to skip explicitly" >&2; \
		exit 1; \
	fi

fmt:
	stylua $(LUA_FILES)

doc:
	$(NVIM) --headless --clean -c 'helptags doc' -c 'quit'
