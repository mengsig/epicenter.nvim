--- Which impacted definitions the author has already looked at, per project,
--- across restarts.
---
--- An entry is keyed by the definition (`qualified@file`) AND the hash of its
--- source, and records the change it was approved under. BOTH have to still
--- match for the row to read as reviewed: editing the impacted definition
--- changes its hash, and editing the working change itself yields a new
--- changeId - and nobody has looked at THAT change's impact yet.
---
--- A loaded state therefore carries the change it is being read against;
--- reading approvals without knowing which change they were given for is
--- what let a fresh edit inherit a full set of ticks.
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

--- @param change_id string the change these approvals are read against
--- @return { entries: table<string, string>, changes: string[], change_id: string }
function M.load(root, change_id)
  assert(type(change_id) == "string" and change_id ~= "", "approvals need a change to read against")
  local stored = require("epicenter.store").read(KIND, root)
  return {
    entries = type(stored.entries) == "table" and stored.entries or {},
    changes = type(stored.changes) == "table" and stored.changes or {},
    change_id = change_id,
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

--- Another Neovim on the same project keeps its own copy of this state. A
--- plain write would drop whatever it approved, so its entries are folded
--- back in - except the ones this session explicitly took back. Pure.
--- @param stored table the state as it is on disk right now
--- @param state table this session's state
--- @return table
function M.merge(stored, state)
  local entries = vim.tbl_extend("force", stored.entries or {}, state.entries)
  for key in pairs(state.revoked or {}) do
    entries[key] = nil
  end
  local changes = vim.list_extend({}, state.changes or {})
  for _, id in ipairs(stored.changes or {}) do
    if not vim.tbl_contains(changes, id) then
      table.insert(changes, id)
    end
  end
  return { entries = entries, changes = changes, change_id = state.change_id }
end

--- @return boolean ok, string|nil err
function M.save(root, state)
  local merged = M.merge(M.load(root, state.change_id), state)
  return require("epicenter.store").write(KIND, root, M.prune(merged, state.change_id))
end

--- Reviewed means: this exact source was approved, AND it was approved for
--- the change now being reported. An entry recorded under an earlier change
--- says nothing about this one.
--- @param state table from `M.load`
--- @param symbol table
--- @return boolean
function M.approved(state, symbol)
  local key = M.key(symbol)
  local recorded = key ~= nil and state.entries[key] or nil
  return recorded ~= nil and recorded == state.change_id
end

--- Marks `symbol` approved (or not) under the state's own change. A symbol
--- the server gave no hash for cannot be keyed, so it is reported rather than
--- silently recorded under a key that would match everything.
--- @return boolean changed
function M.set(state, symbol, approved)
  local key = M.key(symbol)
  if not key then
    return false
  end
  local before = state.entries[key]
  state.entries[key] = approved and state.change_id or nil
  -- Taking an approval back has to survive the merge in `save`: without this
  -- another instance's copy of the same entry would put the tick straight
  -- back.
  state.revoked = state.revoked or {}
  state.revoked[key] = (not approved) and true or nil
  return before ~= state.entries[key]
end

return M
