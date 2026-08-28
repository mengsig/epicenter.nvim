--- The `make docs-check` logic, as a pure(ish) function: `M.run(repo, write)`
--- returns `(ok, problems)` instead of printing and exiting, so a spec can
--- drive it directly (F9 - `make docs-check` naming a target a person would
--- reach for, that must actually run every check the name promises).
--- `tests/docs_check.lua` is the thin CLI wrapper around this.
local docs = require("epicenter.docs")

local M = {}

--- Lines outside a generated region are never touched; a region is delimited
--- by its own markers, and the markers themselves stay put.
--- @class epicenter.docs.Region
--- @field name string
--- @field first integer first generated line (1-based)
--- @field last integer last generated line; `first - 1` when the region is empty

--- README.md: `<!-- registry:<name> -->` ... `<!-- /registry:<name> -->`.
--- @return epicenter.docs.Region[]
local function markdown_regions(lines)
  local found, open = {}, nil
  for i, line in ipairs(lines) do
    local name = line:match("^%s*<!%-%- registry:([%w_-]+) %-%->%s*$")
    local close = line:match("^%s*<!%-%- /registry:([%w_-]+) %-%->%s*$")
    if name then
      assert(not open, "nested registry marker at line " .. i)
      open = { name = name, first = i + 1 }
    elseif close then
      assert(open and open.name == close, ("stray /registry:%s at line %d"):format(close, i))
      open.last = i - 1
      table.insert(found, open)
      open = nil
    end
  end
  assert(not open, "unclosed registry marker for " .. tostring(open and open.name))
  return found
end

--- doc/epicenter.txt: a `*tag*` line, then a literal block (`>` ... `<`).
--- @return epicenter.docs.Region[]
local function vimdoc_regions(lines)
  local found = {}
  for i, line in ipairs(lines) do
    local name = line:match("%*(epicenter%-[%w-]+%-table)%*")
    if name then
      local open = nil
      for j = i + 1, math.min(i + 3, #lines) do
        if lines[j]:match(">%a*$") then
          open = j
          break
        end
      end
      assert(open, ("*%s* is not followed by a literal block"):format(name))
      local close = nil
      for j = open + 1, #lines do
        if lines[j] == "<" then
          close = j
          break
        end
      end
      assert(close, ("the literal block after *%s* is never closed"):format(name))
      table.insert(found, { name = name, first = open + 1, last = close - 1 })
    end
  end
  return found
end

--- @param format "markdown"|"vimdoc"
local function render(format, name)
  local fn = docs.REGIONS[format][name]
  assert(fn, ("no renderer for the %s region %q"):format(format, name))
  return fn()
end

local function diff(name, want, got)
  local out = { ("%s: out of date (- expected, + in the file)"):format(name) }
  for i = 1, math.max(#want, #got) do
    if want[i] ~= got[i] then
      if want[i] then
        table.insert(out, "  - " .. want[i])
      end
      if got[i] then
        table.insert(out, "  + " .. got[i])
      end
    end
  end
  return table.concat(out, "\n")
end

--- Neither format may push a line past what its readers expect: vimdoc wraps
--- at 78 columns, and a README table that wraps in a narrow view is unreadable.
local LIMITS = { markdown = 100, vimdoc = 78 }

--- @param format "markdown"|"vimdoc"
--- @param finder fun(lines: string[]): epicenter.docs.Region[]
local function check_regions(repo, path, format, finder, write, problems)
  local absolute = vim.fs.joinpath(repo, path)
  local lines = vim.fn.readfile(absolute)
  local regions = finder(lines)
  if #regions == 0 then
    table.insert(problems, path .. ": no generated regions found")
    return
  end

  -- Back to front, so an earlier rewrite cannot shift a later region's bounds.
  table.sort(regions, function(a, b)
    return a.first > b.first
  end)

  local changed = false
  for _, region in ipairs(regions) do
    local want = render(format, region.name)
    -- vim.list_slice's bounds are inclusive; an empty region is first > last.
    local got = vim.list_slice(lines, region.first, region.last)

    for _, line in ipairs(want) do
      if #line > LIMITS[format] then
        table.insert(
          problems,
          ("%s/%s: generated line is %d columns, the limit is %d:\n  %s"):format(
            path,
            region.name,
            #line,
            LIMITS[format],
            line
          )
        )
      end
    end

    if not vim.deep_equal(want, got) then
      if write then
        local rebuilt = vim.list_slice(lines, 1, region.first - 1)
        vim.list_extend(rebuilt, want)
        vim.list_extend(rebuilt, vim.list_slice(lines, region.last + 1, #lines))
        lines = rebuilt
        changed = true
      else
        table.insert(problems, diff(path .. "/" .. region.name, want, got))
      end
    end
  end

  if changed then
    vim.fn.writefile(lines, absolute)
    io.write(("rewrote the generated regions in %s\n"):format(path))
  end
end

--- Every committed `assets/*.svg` is linked from README.md, and every linked
--- asset exists (F9: this ran only under `make test`, not `make docs-check`,
--- so the named gate passed on a broken README).
--- @param repo string absolute repo root
--- @return string[] problems, empty when README and assets/ agree
function M.check_assets(repo)
  local problems = {}
  local readme = table.concat(vim.fn.readfile(vim.fs.joinpath(repo, "README.md")), "\n")
  local linked = {}
  for asset in readme:gmatch("%(assets/([%w%-%.]+)%)") do
    linked[asset] = true
    if vim.uv.fs_stat(vim.fs.joinpath(repo, "assets", asset)) == nil then
      table.insert(problems, "README links assets/" .. asset .. ", which is not in the repo")
    end
  end
  for _, path in ipairs(vim.fn.glob(repo .. "/assets/*", false, true)) do
    local name = vim.fs.basename(path)
    if not linked[name] then
      table.insert(problems, "assets/" .. name .. " is committed but nothing links it")
    end
  end
  if next(linked) == nil then
    table.insert(problems, "the README must show at least one screenshot")
  end
  return problems
end

--- @param repo string absolute repo root
--- @param write boolean rewrite the generated regions instead of reporting
--- @return boolean ok, string[] problems
function M.run(repo, write)
  local problems = {}
  check_regions(repo, "README.md", "markdown", markdown_regions, write, problems)
  check_regions(repo, "doc/epicenter.txt", "vimdoc", vimdoc_regions, write, problems)
  vim.list_extend(problems, M.check_assets(repo))
  return #problems == 0, problems
end

return M
