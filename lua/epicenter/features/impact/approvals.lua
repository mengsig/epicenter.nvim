--- Which impacted definitions the author has already looked at, per project,
--- across restarts.
---
--- An entry is keyed by the definition (`qualified@file`) AND the hash of its
--- source, and records the change it was approved under. Editing that
--- definition changes its hash, so the key no longer matches and the row
--- comes back unreviewed - which is the whole point. Editing something else
--- leaves it alone.
local M = {}

local KIND = "impact"
--- Approvals are kept for this many recent changes; older ones are dropped so
--- the file cannot grow without bound.
local KEEP_CHANGES = 8

--- @param symbol table a protocol Symbol
--- @return string|nil nil when the server sent no hash to key on
function M.key(symbol)
  local ref = require("epicenter.client").symbol_ref(symbol)
  if not ref or type(symbol.contentHash) ~= "string" or symbol.contentHash == "" then
    return nil
  end
  return ("%s#%s"):format(ref, symbol.contentHash)
end

--- @return { entries: table<string, string>, changes: string[] }
function M.load(root)
  local stored = require("epicenter.store").read(KIND, root)
  return {
    entries = type(stored.entries) == "table" and stored.entries or {},
    changes = type(stored.changes) == "table" and stored.changes or {},
  }
end

--- Drops every entry whose change is no longer among the newest kept ones.
--- Pure.
--- @param state { entries: table<string, string>, changes: string[] }
--- @param change_id string the change being reviewed now
--- @return table pruned state
function M.prune(state, change_id)
  local changes = { change_id }
  for _, id in ipairs(state.changes) do
    if id ~= change_id and #changes < KEEP_CHANGES then
      table.insert(changes, id)
    end
  end
  local live = {}
  for _, id in ipairs(changes) do
    live[id] = true
  end
  local entries = {}
  for key, id in pairs(state.entries) do
    if live[id] then
      entries[key] = id
    end
  end
  return { entries = entries, changes = changes }
end

--- @return boolean ok, string|nil err
function M.save(root, state, change_id)
  return require("epicenter.store").write(KIND, root, M.prune(state, change_id))
end

--- @param state table
--- @param symbol table
--- @return boolean
function M.approved(state, symbol)
  local key = M.key(symbol)
  return key ~= nil and state.entries[key] ~= nil
end

--- Marks `symbol` approved (or not) under `change_id`. A symbol the server
--- gave no hash for cannot be keyed, so it is reported rather than silently
--- recorded under a key that would match everything.
--- @return boolean changed
function M.set(state, symbol, change_id, approved)
  local key = M.key(symbol)
  if not key then
    return false
  end
  local before = state.entries[key]
  state.entries[key] = approved and change_id or nil
  return before ~= state.entries[key]
end

return M
