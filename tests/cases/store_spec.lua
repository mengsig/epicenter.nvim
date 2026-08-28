--- The per-project state file: where it lands, what happens to a file this
--- version cannot read, and that a write never leaves a half-written one.
local store = require("epicenter.store")

describe("the state file's location", function()
  local dir

  before_each(function()
    dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    store.set_root(dir)
  end)

  after_each(function()
    store.set_root(nil)
    vim.fn.delete(dir, "rf")
  end)

  it("keys a project reached through a symlink to one file, not two", function()
    local real = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(real, "p")
    local link = vim.fs.joinpath(dir, "alias")
    if not vim.uv.fs_symlink(real, link) then
      return skip("this platform would not make a symlink")
    end
    expect.eq(store.path("impact", link), store.path("impact", real))
  end)

  it("gives two projects with the same basename their own files", function()
    expect.ne(store.path("impact", "/a/proj"), store.path("impact", "/b/proj"))
  end)
end)

describe("reading state back", function()
  local dir, root

  before_each(function()
    dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    store.set_root(dir)
    root = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    store.set_root(nil)
    vim.fn.delete(dir, "rf")
  end)

  it("round-trips what was written", function()
    expect.eq({ store.write("impact", root, { entries = { a = "one" } }) }, { true, nil })
    expect.eq(store.read("impact", root), { entries = { a = "one" } })
  end)

  it("starts fresh on a file this version does not know how to read", function()
    local path = store.path("impact", root)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    -- The shape this format had before it carried a version.
    vim.fn.writefile({ vim.json.encode({ entries = { a = "one" } }) }, path)
    expect.eq(store.read("impact", root), {}, "an unversioned file is not read as the new shape")

    vim.fn.writefile({ vim.json.encode({ version = store.VERSION + 1, data = {} }) }, path)
    expect.eq(store.read("impact", root), {}, "nor is a newer one")
  end)

  it("starts fresh on a truncated or nonsense file rather than raising", function()
    local path = store.path("impact", root)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ '{"version":1,"data":{"a":' }, path)
    expect.eq(store.read("impact", root), {})
    vim.fn.writefile({ "7" }, path)
    expect.eq(store.read("impact", root), {})
  end)

  it("never leaves the real file half-written", function()
    store.write("impact", root, { entries = { a = "one" } })
    local path = store.path("impact", root)

    -- The temp file is what a crash mid-write would truncate; the real file
    -- is only ever replaced whole.
    expect.eq(vim.fn.filereadable(path .. ".tmp"), 0, "no temp file is left behind")
    store.write("impact", root, { entries = { b = "two" } })
    expect.eq(store.read("impact", root), { entries = { b = "two" } })
    expect.eq(vim.fn.filereadable(path .. ".tmp"), 0)
  end)
end)

describe("approvals written from two Neovim instances", function()
  local approvals = require("epicenter.features.impact.approvals")

  local function symbol(name, hash)
    return {
      qualified = name,
      name = name,
      file = "app/a.lua",
      contentHash = hash or "aaaa",
    }
  end

  local dir, root

  before_each(function()
    dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    store.set_root(dir)
    root = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    store.set_root(nil)
    vim.fn.delete(dir, "rf")
  end)

  it("keeps what the other instance approved, and honours an undo here", function()
    local first = approvals.load(root, "change1")
    approvals.set(first, symbol("M.a", "h1"), true)
    expect.truthy(approvals.save(root, first))

    -- A second instance loads the same file and approves something else.
    local second = approvals.load(root, "change1")
    approvals.set(second, symbol("M.b", "h2"), true)
    expect.truthy(approvals.save(root, second))

    local reloaded = approvals.load(root, "change1")
    expect.truthy(approvals.approved(reloaded, symbol("M.a", "h1")), "the first is still there")
    expect.truthy(approvals.approved(reloaded, symbol("M.b", "h2")))

    -- Undoing one must not be resurrected by the merge.
    local third = approvals.load(root, "change1")
    approvals.set(third, symbol("M.a", "h1"), false)
    expect.truthy(approvals.save(root, third))
    expect.falsy(approvals.approved(approvals.load(root, "change1"), symbol("M.a", "h1")))
    expect.truthy(approvals.approved(approvals.load(root, "change1"), symbol("M.b", "h2")))
  end)
end)
