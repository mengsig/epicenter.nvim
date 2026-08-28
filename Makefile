NVIM ?= nvim
LUA_FILES := $(shell find lua plugin tests -name '*.lua' -not -path 'tests/fixtures/*')

NAVGRAPH_BIN ?= navgraph

.PHONY: test test-real smoke lint fmt doc docs-check docs-fix all

all: lint test

test:
	$(NVIM) --headless --clean -u tests/minimal_init.lua -l tests/run.lua

# The same features against the REAL `navgraph lsp`. Point NAVGRAPH_BIN at a
# build when the one on $$PATH is not the one you mean to test.
test-real:
	NAVGRAPH_BIN=$(NAVGRAPH_BIN) $(NVIM) --headless --clean -u tests/minimal_init.lua -l tests/run_real.lua

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

# The keymap table, the command table and the config reference are generated
# from the registry; docs-check fails when README/vimdoc drifted, docs-fix
# rewrites them in place.
docs-check:
	$(NVIM) --headless --clean -u tests/minimal_init.lua -l tests/docs_check.lua

docs-fix:
	$(NVIM) --headless --clean -u tests/minimal_init.lua -l tests/docs_check.lua --write

doc:
	$(NVIM) --headless --clean -c 'helptags doc' -c 'quit'
