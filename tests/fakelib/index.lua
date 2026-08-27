--- A deliberately small real index over the fixture tree: it scans Lua and
--- Python sources for definitions and counts call sites. Small enough to read,
--- real enough that a fixture edit cannot silently drift from the assertions.
local M = {}

local uv = vim.uv or vim.loop

local LANGUAGES = { [".lua"] = "lua", [".py"] = "python" }

local function language_of(path)
  return LANGUAGES[path:match("(%.[%w_]+)$") or ""]
end

local function read_file(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local text = fh:read("a")
  fh:close()
  return text
end

local function walk(dir, root, out)
  for name, kind in vim.fs.dir(dir) do
    local path = vim.fs.joinpath(dir, name)
    if kind == "directory" then
      if name ~= ".git" and name ~= ".navgraph" then
        walk(path, root, out)
      end
    elseif language_of(name) then
      table.insert(out, path:sub(#root + 2))
    end
  end
end

local function scan_lua(lines)
  local found = {}
  for i, line in ipairs(lines) do
    local name = line:match("^%s*function%s+([%w_.:]+)")
      or line:match("^%s*local%s+function%s+([%w_]+)")
    if name then
      local bare = name:match("[%w_]+$")
      table.insert(found, {
        name = bare,
        qualified = name:gsub(":", "."),
        kind = name:find("[.:]") and "method" or "fn",
        line = i,
        sig = vim.trim(line),
        exported = name:find("[.:]") ~= nil,
      })
    end
  end
  return found
end

local function scan_python(lines)
  local found = {}
  local class, class_indent = nil, 0
  for i, line in ipairs(lines) do
    local indent, class_name = line:match("^(%s*)class%s+([%w_]+)")
    if class_name then
      class, class_indent = class_name, #indent
      table.insert(found, {
        name = class_name,
        qualified = class_name,
        kind = "class",
        line = i,
        sig = vim.trim(line),
        exported = not class_name:match("^_"),
      })
    else
      local def_indent, def_name = line:match("^(%s*)def%s+([%w_]+)")
      if def_name then
        local nested = class ~= nil and #def_indent > class_indent
        table.insert(found, {
          name = def_name,
          qualified = nested and (class .. "." .. def_name) or def_name,
          kind = nested and "method" or "fn",
          line = i,
          sig = vim.trim(line),
          exported = not def_name:match("^_"),
        })
        if not nested then
          class = nil
        end
      end
    end
  end
  return found
end

local SCANNERS = { lua = scan_lua, python = scan_python }

--- Builds the index for `root`. `overlays` maps a root-relative path to
--- unsaved buffer text and takes precedence over the file on disk.
--- @param root string
--- @param overlays? table<string, string>
function M.build(root, overlays)
  overlays = overlays or {}
  local started = uv.hrtime()
  local files = {}
  walk(root, root, files)
  for path in pairs(overlays) do
    if not vim.tbl_contains(files, path) then
      table.insert(files, path)
    end
  end
  table.sort(files)

  local sources, symbols = {}, {}
  local next_id = 0

  for _, file in ipairs(files) do
    local text = overlays[file] or read_file(vim.fs.joinpath(root, file))
    if text then
      local lines = vim.split(text, "\n", { plain = true })
      sources[file] = lines
      local language = language_of(file)
      local found = SCANNERS[language](lines)
      for i, def in ipairs(found) do
        next_id = next_id + 1
        table.insert(symbols, {
          id = next_id,
          name = def.name,
          qualified = def.qualified,
          kind = def.kind,
          file = file,
          uri = vim.uri_from_fname(vim.fs.joinpath(root, file)),
          line = def.line,
          endLine = found[i + 1] and (found[i + 1].line - 1) or #lines,
          sig = def.sig,
          language = language,
          callers = 0,
          callees = 0,
          exported = def.exported,
          test = file:find("test") ~= nil,
        })
      end
    end
  end

  -- Fan-in: call sites of each name outside its own definition line.
  for _, symbol in ipairs(symbols) do
    local pattern = "%f[%w_]" .. symbol.name .. "%s*%("
    for file, lines in pairs(sources) do
      for i, line in ipairs(lines) do
        if not (file == symbol.file and i == symbol.line) and line:find(pattern) then
          symbol.callers = symbol.callers + 1
        end
      end
    end
  end

  return {
    root = root,
    files = files,
    sources = sources,
    symbols = symbols,
    ms = math.floor((uv.hrtime() - started) / 1e6),
  }
end

--- Symbol whose body spans `line` (1-based) in `file`, innermost first.
function M.enclosing(index, file, line)
  local best = nil
  for _, symbol in ipairs(index.symbols) do
    if symbol.file == file and symbol.line <= line and line <= symbol.endLine then
      if not best or symbol.line > best.line then
        best = symbol
      end
    end
  end
  return best
end

--- Subsequence match of `query` in `text`. Returns 0-based match indices.
--- @return integer[]|nil
function M.fuzzy(text, query)
  local haystack, needle = text:lower(), query:lower()
  local matches, from = {}, 1
  for i = 1, #needle do
    local at = haystack:find(needle:sub(i, i), from, true)
    if not at then
      return nil
    end
    table.insert(matches, at - 1)
    from = at + 1
  end
  return matches
end

local function score(qualified, query, matches)
  local lower, needle = qualified:lower(), query:lower()
  if lower == needle then
    return 1000
  end
  if vim.startswith(lower, needle) then
    return 800
  end
  local first = matches[1]
  local prev = first > 0 and qualified:sub(first, first) or "."
  if first == 0 or prev == "." or prev == "_" or prev == ":" then
    return 600
  end
  return 400
end

--- Ranks: exact > prefix > word boundary > subsequence; ties by fan-in then
--- by the shorter path. Mirrors the `navgraph/search` contract.
--- @param opts { query: string, kinds?: string[], limit?: integer }
function M.search(index, opts)
  local query = opts.query or ""
  local items = {}
  for _, symbol in ipairs(index.symbols) do
    local allowed = not opts.kinds or #opts.kinds == 0 or vim.tbl_contains(opts.kinds, symbol.kind)
    if allowed then
      local matches = query == "" and {} or M.fuzzy(symbol.qualified, query)
      if matches then
        table.insert(items, {
          symbol = symbol,
          score = query == "" and symbol.callers or score(symbol.qualified, query, matches),
          matches = matches,
        })
      end
    end
  end

  table.sort(items, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.symbol.callers ~= b.symbol.callers then
      return a.symbol.callers > b.symbol.callers
    end
    if #a.symbol.file ~= #b.symbol.file then
      return #a.symbol.file < #b.symbol.file
    end
    return a.symbol.qualified < b.symbol.qualified
  end)

  local total = #items
  local limit = opts.limit or 50
  return { items = vim.list_slice(items, 1, math.min(total, limit)), total = total }
end

--- `navgraph/search` with `refs:true`: use sites of symbols matching `query`,
--- grouped by the definition each use site sits inside. Mirrors the fan-in
--- scan in M.build, but keeps the call-site line numbers instead of just
--- counting them.
--- @param opts { query: string, kinds?: string[], limit?: integer }
function M.search_refs(index, opts)
  local query = opts.query or ""
  if query == "" then
    return { items = {}, total = 0 }
  end

  local by_referencer = {}
  for _, target in ipairs(index.symbols) do
    local allowed = not opts.kinds or #opts.kinds == 0 or vim.tbl_contains(opts.kinds, target.kind)
    if allowed and M.fuzzy(target.qualified, query) then
      local pattern = "%f[%w_]" .. target.name .. "%s*%("
      for file, lines in pairs(index.sources) do
        for i, line in ipairs(lines) do
          if not (file == target.file and i == target.line) and line:find(pattern) then
            local enclosing = M.enclosing(index, file, i)
            if enclosing then
              local entry = by_referencer[enclosing.id]
              if not entry then
                entry = { symbol = enclosing, lines = {} }
                by_referencer[enclosing.id] = entry
              end
              if not vim.tbl_contains(entry.lines, i) then
                table.insert(entry.lines, i)
              end
            end
          end
        end
      end
    end
  end

  local items = vim.tbl_values(by_referencer)
  for _, item in ipairs(items) do
    table.sort(item.lines)
  end
  table.sort(items, function(a, b)
    return a.symbol.qualified < b.symbol.qualified
  end)

  local total = #items
  local limit = opts.limit or 50
  return { items = vim.list_slice(items, 1, math.min(total, limit)), total = total }
end

--- @param opts { pattern: string, regex?: boolean, caseSensitive?: boolean, limit?: integer }
function M.grep(index, opts)
  local pattern = opts.pattern or ""
  local items, total = {}, 0
  local limit = opts.limit or 200

  for _, file in ipairs(index.files) do
    for i, line in ipairs(index.sources[file] or {}) do
      local haystack = opts.caseSensitive and line or line:lower()
      local needle = opts.caseSensitive and pattern or pattern:lower()
      local at = opts.regex and haystack:find(needle) or haystack:find(needle, 1, true)
      if at then
        total = total + 1
        if #items < limit then
          table.insert(items, {
            file = file,
            uri = vim.uri_from_fname(vim.fs.joinpath(index.root, file)),
            line = i,
            character = at - 1,
            text = line,
            enclosing = M.enclosing(index, file, i),
          })
        end
      end
    end
  end

  return { items = items, total = total, truncated = total > #items }
end

return M
