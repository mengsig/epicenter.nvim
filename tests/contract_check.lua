-- Contract drift guard: nvim --headless --clean -u tests/minimal_init.lua -l tests/contract_check.lua
--
-- `tests/contract/lsp.md` is a vendored copy of NavGraph's own `docs/lsp.md`;
-- `tests/contract/UPSTREAM.lock` pins the upstream revision it was copied at
-- and that file's sha256. This fails when the vendored copy no longer
-- matches its pin - a hand-edit, a partial re-vendor, or a stale pin left
-- behind after `schema.lua` changed but the lock did not (F3).
--
-- This cannot compare against a live NavGraph checkout (none exists in CI or
-- a fresh clone); it only catches drift from what was recorded at vendor
-- time. To refresh: see "To update" in tests/contract/README.md.
local repo = _G.EPICENTER_ROOT or vim.fn.getcwd()

local function read(path)
  local fh = assert(io.open(path, "rb"), ("could not open %s"):format(path))
  local content = fh:read("*a")
  fh:close()
  return content
end

local function parse_lock(text)
  local fields = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_]+)=(%S+)$")
    if key then
      fields[key] = value
    end
  end
  return fields
end

local lock_path = vim.fs.joinpath(repo, "tests/contract/UPSTREAM.lock")
local vendored_path = vim.fs.joinpath(repo, "tests/contract/lsp.md")

local lock = parse_lock(read(lock_path))
if not lock.sha256 or not lock.upstream_rev then
  io.stderr:write(("%s: missing upstream_rev or sha256\n"):format(lock_path))
  os.exit(1)
end

local actual = vim.fn.sha256(read(vendored_path))
if actual ~= lock.sha256 then
  io.stderr:write(
    ("%s has drifted from its pin in %s\n"):format(vendored_path, lock_path)
      .. ("  pinned sha256:  %s\n"):format(lock.sha256)
      .. ("  actual sha256:  %s\n"):format(actual)
      .. "re-vendor from upstream and update the pin - see tests/contract/README.md\n"
  )
  os.exit(1)
end

io.write(("contract in sync with upstream_rev %s\n"):format(lock.upstream_rev))
