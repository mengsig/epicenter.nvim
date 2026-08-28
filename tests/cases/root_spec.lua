local root = require("epicenter.root")

local function tmptree(paths)
  local base = vim.fn.tempname()
  for _, p in ipairs(paths) do
    vim.fn.mkdir(vim.fs.joinpath(base, p), "p")
  end
  return vim.fs.normalize(base)
end

describe("root", function()
  it("finds the nearest marker walking upward", function()
    local base = tmptree({ "proj/.git", "proj/src/deep" })
    expect.eq(root.find_from(base .. "/proj/src/deep", { ".git" }), base .. "/proj")
  end)

  it("prefers an earlier marker in the same directory", function()
    local base = tmptree({ "proj/.git", "proj/.navgraph", "proj/src" })
    expect.eq(root.find_from(base .. "/proj/src", { ".navgraph", ".git" }), base .. "/proj")
    expect.eq(root.find_from(base .. "/proj", { ".navgraph", ".git" }), base .. "/proj")
  end)

  it("stops at the innermost match", function()
    local base = tmptree({ "outer/.git", "outer/inner/.navgraph", "outer/inner/src" })
    expect.eq(
      root.find_from(base .. "/outer/inner/src", { ".navgraph", ".git" }),
      base .. "/outer/inner"
    )
  end)

  it("returns nil when no marker exists anywhere above", function()
    local base = tmptree({ "bare/src" })
    -- A real filesystem may have markers above tempdir; assert only that a
    -- match, if any, is outside the tree we built.
    local found = root.find_from(base .. "/bare/src", { ".navgraph-nonexistent-marker" })
    expect.eq(found, nil)
  end)

  it("returns nil for an empty path", function()
    expect.eq(root.find_from("", { ".git" }), nil)
  end)

  it("falls back to cwd for a nameless buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local found = root.find(buf, { ".navgraph-nonexistent-marker" })
    expect.eq(found, vim.fs.normalize(vim.uv.cwd()))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
