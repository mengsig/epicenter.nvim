local install = require("epicenter.install")

--- Concatenated text of every live toast, newest-window-order. Shared by any
--- describe block that needs to assert on what the user would actually see.
local function toast_text()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "epicenter-toast" then
      table.insert(out, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    end
  end
  return table.concat(out, "\n")
end

describe("binary resolution", function()
  before_each(function()
    require("epicenter.config").reset()
  end)

  it("prefers the configured path", function()
    local path = install.resolve({
      path = "/opt/navgraph",
      probe = function(p)
        return p == "/opt/navgraph" or p == "navgraph"
      end,
    })
    expect.eq(path, "/opt/navgraph")
  end)

  it("reports a configured path that is not executable instead of falling back", function()
    local path, err = install.resolve({
      path = "/opt/missing",
      probe = function(p)
        return p == "navgraph"
      end,
    })
    expect.eq(path, nil, "a wrong navgraph.path must be an error, not a silent fallback")
    expect.matches(err, "/opt/missing")
    expect.matches(err, "not executable")
  end)

  it("falls back to $PATH, then to the managed install", function()
    expect.eq(
      install.resolve({
        probe = function(p)
          return p == "navgraph"
        end,
      }),
      "navgraph"
    )
    expect.eq(
      install.resolve({
        probe = function(p)
          return p == install.managed_path()
        end,
      }),
      install.managed_path()
    )
  end)

  it("names what it tried when nothing is found", function()
    local path, err = install.resolve({
      probe = function()
        return false
      end,
    })
    expect.eq(path, nil)
    expect.matches(err, "not on %$PATH")
    expect.matches(err, ":Epicenter install")
  end)

  it("takes the configured path from setup when none is passed", function()
    require("epicenter.config").setup({ navgraph = { path = "/from/config" } })
    local path = install.resolve({
      probe = function(p)
        return p == "/from/config"
      end,
    })
    expect.eq(path, "/from/config")
  end)

  it("puts a managed binary under stdpath data", function()
    expect.matches(install.managed_path(), "epicenter/bin/navgraph$")
    expect.truthy(vim.startswith(install.managed_path(), vim.fs.normalize(vim.fn.stdpath("data"))))
  end)
end)

describe("install plan", function()
  it("downloads a release when gh is authenticated", function()
    expect.eq(install.plan({ gh = true, gh_auth = true, git = false, zig = false }), "release")
  end)

  it("builds from source when gh cannot be used", function()
    expect.eq(install.plan({ gh = false, gh_auth = false, git = true, zig = true }), "source")
    expect.eq(install.plan({ gh = true, gh_auth = false, git = true, zig = true }), "source")
  end)

  it("names exactly what is missing when neither route works", function()
    local kind, err = install.plan({ gh = false, gh_auth = false, git = true, zig = false })
    expect.eq(kind, nil)
    expect.matches(err, "gh %(GitHub CLI%) is not installed")
    expect.matches(err, "zig is not installed")
    expect.falsy(err:match("git is not installed"), "it must not report a tool that is present")
  end)

  it("says so when gh is present but not logged in", function()
    local _, err = install.plan({ gh = true, gh_auth = false, git = false, zig = false })
    expect.matches(err, "gh auth login")
  end)
end)

describe("release asset pattern", function()
  it("maps uname to the published asset names", function()
    expect.eq(install.asset_pattern({ sysname = "Linux", machine = "x86_64" }), "*x86_64*linux*")
    expect.eq(install.asset_pattern({ sysname = "Darwin", machine = "arm64" }), "*aarch64*macos*")
    expect.eq(install.asset_pattern({ sysname = "Darwin", machine = "x86_64" }), "*x86_64*macos*")
  end)

  it("passes an unknown platform through rather than guessing", function()
    expect.eq(
      install.asset_pattern({ sysname = "FreeBSD", machine = "riscv64" }),
      "*riscv64*freebsd*"
    )
  end)

  --- Translates a `gh release download --pattern` glob into a Lua pattern:
  --- `*` becomes `.-` and every other glob byte is escaped literally.
  local function glob_matches(glob, name)
    local escaped = glob:gsub("[%(%)%.%%%+%-%[%]%^%$%?]", "%%%1"):gsub("%*", ".-")
    return name:match("^" .. escaped .. "$") ~= nil
  end

  -- Regression (F1): the v1.0.0 release names assets `navgraph-<arch>-<os>`,
  -- arch first. The old `*<os>*<arch>*` order never matched any of them, so
  -- `:Epicenter install` silently fell back to a ~100s source build even with
  -- gh authenticated.
  local REAL_V1_0_0_ASSETS = {
    "navgraph-x86_64-linux.tar.gz",
    "navgraph-aarch64-linux.tar.gz",
    "navgraph-x86_64-macos.tar.gz",
    "navgraph-aarch64-macos.tar.gz",
  }
  local UNAME_FOR = {
    ["navgraph-x86_64-linux.tar.gz"] = { sysname = "Linux", machine = "x86_64" },
    ["navgraph-aarch64-linux.tar.gz"] = { sysname = "Linux", machine = "aarch64" },
    ["navgraph-x86_64-macos.tar.gz"] = { sysname = "Darwin", machine = "x86_64" },
    ["navgraph-aarch64-macos.tar.gz"] = { sysname = "Darwin", machine = "arm64" },
  }

  it("matches every real v1.0.0 release asset name for its own platform", function()
    for _, asset in ipairs(REAL_V1_0_0_ASSETS) do
      local pattern = install.asset_pattern(UNAME_FOR[asset])
      expect.truthy(
        glob_matches(pattern, asset),
        ("pattern %q must match %s"):format(pattern, asset)
      )
    end
  end)

  it("would have rejected every real asset under the old os-before-arch order", function()
    for _, asset in ipairs(REAL_V1_0_0_ASSETS) do
      local uname = UNAME_FOR[asset]
      local os_name = uname.sysname == "Darwin" and "macos" or "linux"
      local arch = uname.machine == "arm64" and "aarch64" or uname.machine
      local old_pattern = ("*%s*%s*"):format(os_name, arch)
      expect.falsy(
        glob_matches(old_pattern, asset),
        ("old pattern %q must NOT match %s - this is the bug being fixed"):format(
          old_pattern,
          asset
        )
      )
    end
  end)

  it("matches only its own platform's asset, never another's or SHA256SUMS (F7)", function()
    for _, asset in ipairs(REAL_V1_0_0_ASSETS) do
      local pattern = install.asset_pattern(UNAME_FOR[asset])
      for _, other in ipairs(REAL_V1_0_0_ASSETS) do
        if other ~= asset then
          expect.falsy(
            glob_matches(pattern, other),
            ("pattern %q for %s must NOT also match %s"):format(pattern, asset, other)
          )
        end
      end
      expect.falsy(
        glob_matches(pattern, "SHA256SUMS"),
        ("pattern %q must NOT match SHA256SUMS - that would mask a missing binary as success (F2)"):format(
          pattern
        )
      )
    end
  end)
end)

describe("release checksum verification", function()
  local NAME = "navgraph-x86_64-linux.tar.gz"
  local CONTENT = "fake archive bytes for the checksum test"
  local HASH = vim.fn.sha256(CONTENT)

  it("passes when the content matches its listed SHA256", function()
    local sums = ("%s  %s\n"):format(HASH, NAME)
    local ok, err = install.verify_checksum(sums, NAME, CONTENT)
    expect.truthy(ok)
    expect.eq(err, nil)
  end)

  it("rejects a download whose bytes do not match the listed SHA256", function()
    local sums = ("%s  %s\n"):format(HASH, NAME)
    local ok, err = install.verify_checksum(sums, NAME, "tampered or corrupted bytes")
    expect.eq(ok, nil, "a checksum mismatch must not be treated as ok")
    expect.matches(err, "failed SHA256 verification")
    -- NAME's `-` is a Lua pattern quantifier, not a literal, once inside a pattern.
    expect.matches(err, (NAME:gsub("[%-%.]", "%%%1")))
  end)

  it("passes through a repo that publishes no SHA256SUMS at all", function()
    local ok, err = install.verify_checksum(nil, NAME, CONTENT)
    expect.truthy(ok, "no checksums published is not itself a failure")
    expect.eq(err, nil)
  end)

  it("fails an asset SHA256SUMS was published but does not list (F3)", function()
    -- Once a SHA256SUMS exists, an asset missing from it is indistinguishable
    -- from a tampered rename - this must never degrade to a silent pass.
    local sums = ("%s  some-other-asset.tar.gz\n"):format(HASH)
    local ok, err = install.verify_checksum(sums, NAME, CONTENT)
    expect.eq(ok, nil, "an unlisted asset in a real SHA256SUMS must fail, not pass")
    expect.matches(err, "lists no entry for")
    expect.matches(err, (NAME:gsub("[%-%.]", "%%%1")))
  end)

  it("reads the standard sha256sum two-space and binary-mode formats", function()
    local two_space = ("%s  %s"):format(HASH, NAME)
    local binary_mode = ("%s *%s"):format(HASH, NAME)
    expect.truthy((install.verify_checksum(two_space, NAME, CONTENT)))
    expect.truthy((install.verify_checksum(binary_mode, NAME, CONTENT)))
  end)
end)

describe("checksum_error (disk half, F3/F7)", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  local function write(name, content)
    local path = vim.fs.joinpath(dir, name)
    local fh = assert(io.open(path, "wb"))
    fh:write(content)
    fh:close()
    return path
  end

  it("passes a verified archive against its sibling SHA256SUMS", function()
    local content = "archive bytes"
    local archive = write("navgraph-x86_64-linux.tar.gz", content)
    write("SHA256SUMS", ("%s  navgraph-x86_64-linux.tar.gz\n"):format(vim.fn.sha256(content)))
    expect.eq(install.checksum_error(dir, archive), nil)
  end)

  it("fails a tampered archive against its sibling SHA256SUMS", function()
    local archive = write("navgraph-x86_64-linux.tar.gz", "tampered bytes")
    write("SHA256SUMS", ("%s  navgraph-x86_64-linux.tar.gz\n"):format(vim.fn.sha256("real bytes")))
    expect.matches(install.checksum_error(dir, archive), "failed SHA256 verification")
  end)

  it("passes through when no SHA256SUMS was published at all", function()
    local archive = write("navgraph-x86_64-linux.tar.gz", "archive bytes")
    expect.eq(install.checksum_error(dir, archive), nil)
  end)

  it("reports the archive when it cannot be opened", function()
    local missing = vim.fs.joinpath(dir, "does-not-exist.tar.gz")
    local err = install.checksum_error(dir, missing)
    expect.matches(err, "could not open")
    expect.matches(err, "does%-not%-exist%.tar%.gz")
  end)
end)

describe("install orchestration", function()
  local ran, original

  before_each(function()
    require("epicenter.config").reset()
    ran = {}
    original = vim.system
  end)

  after_each(function()
    vim.system = original
  end)

  --- Records commands instead of running them; every one fails.
  local function stub_system(ran_into)
    vim.system = function(cmd, _, cb)
      table.insert(ran_into, table.concat(cmd, " "))
      if cb then
        vim.schedule(function()
          cb({ code = 1, stdout = "", stderr = "stubbed failure" })
        end)
      end
      return {
        wait = function()
          return { code = 1, stdout = "", stderr = "stubbed failure" }
        end,
      }
    end
  end

  it("runs nothing when neither install route is available", function()
    stub_system(ran)
    local captured = "pending"
    install.install({
      tools = { gh = false, gh_auth = false, git = false, zig = false },
      on_done = function(err)
        captured = err
      end,
    })
    wait(function()
      return captured ~= "pending"
    end, 5000, "install to report")
    expect.matches(captured, "cannot install navgraph")
    expect.eq(ran, {}, "no command may run when the plan is impossible")
  end)

  it("clones and builds on the source route, and surfaces the failing command", function()
    stub_system(ran)
    local captured = "pending"
    install.install({
      tools = { gh = false, gh_auth = false, git = true, zig = true },
      on_done = function(err)
        captured = err
      end,
    })
    wait(function()
      return captured ~= "pending"
    end, 5000, "install to report")
    expect.matches(ran[1], "^git clone %-%-depth 1 https://github.com/mengsig/NavGraph.git")
    expect.matches(captured, "git clone")
    expect.matches(captured, "stubbed failure", "the underlying error is preserved, not swallowed")
  end)

  it("falls back to a source build when the release download fails", function()
    stub_system(ran)
    local captured = "pending"
    install.install({
      tools = { gh = true, gh_auth = true, git = true, zig = true },
      on_done = function(err)
        captured = err
      end,
    })
    wait(function()
      return captured ~= "pending"
    end, 5000, "install to report")
    expect.matches(ran[1], "^gh release download")
    expect.matches(ran[2] or "", "^git clone")
  end)

  -- F1: a broken asset pattern used to fall through to a source build with no
  -- explanation anywhere the user would see it - the toast just said "done".
  it("names why it fell back from a release download, in the toast", function()
    stub_system(ran)
    local toast = require("epicenter.ui.toast")
    toast.clear()
    local captured = "pending"
    install.install({
      tools = { gh = true, gh_auth = true, git = true, zig = true },
      on_done = function(err)
        captured = err
      end,
    })
    wait(function()
      return captured ~= "pending"
    end, 5000, "install to report")
    expect.matches(toast_text(), "release download unavailable")
    -- The toast word-wraps long lines, so a longer underlying error can push
    -- a line break between words - tolerate whitespace, not just a space.
    expect.matches(toast_text(), "built%s+from%s+source%s+instead")
    toast.clear()
  end)

  it("wait = true blocks the caller until the async install actually finishes", function()
    stub_system(ran)
    -- A build/run hook calls install() and treats its RETURN as done; wait
    -- must make that true instead of racing the still-running download/build.
    local ok, err = install.install({
      tools = { gh = false, gh_auth = false, git = true, zig = true },
      wait = 2000,
    })
    expect.eq(ok, false, "the stubbed clone must be reported as a failure, not swallowed")
    expect.truthy(err ~= nil, "wait must return the error synchronously, not nil")
    expect.matches(err, "git clone")
    expect.matches(err, "stubbed failure")
  end)

  -- F2: `--pattern <asset> --pattern SHA256SUMS` in one call used to succeed
  -- (SHA256SUMS matches) on a platform with no published binary, so
  -- `find_binary` then reported the misleading "no navgraph binary".
  it("names the platform, not a missing binary, when no asset matches it (F2)", function()
    stub_system(ran)
    local captured = "pending"
    install.install({
      tools = { gh = true, gh_auth = true, git = false, zig = false },
      uname = { sysname = "Windows_NT", machine = "x86_64" },
      on_done = function(err)
        captured = err
      end,
    })
    wait(function()
      return captured ~= "pending"
    end, 5000, "install to report")
    expect.matches(captured, "no release asset for x86_64%-windows")
    expect.falsy(captured:match("no `navgraph` binary"), "must not blame a phantom missing binary")
    -- Only the asset download ran - SHA256SUMS is a second, later step (F2).
    expect.eq(#ran, 1)
    expect.matches(ran[1], "%-%-pattern %*x86_64%*windows%*")
    expect.falsy(ran[1]:match("SHA256SUMS"), "the asset call must not also request SHA256SUMS")
  end)

  it("stops on a checksum mismatch instead of falling back to a source build (F4)", function()
    local NAME = "navgraph-x86_64-linux.tar.gz"
    vim.system = function(cmd, _, cb)
      table.insert(ran, table.concat(cmd, " "))
      if cmd[1] == "gh" then
        local dir, pattern
        for i, v in ipairs(cmd) do
          if v == "--dir" then
            dir = cmd[i + 1]
          elseif v == "--pattern" then
            pattern = cmd[i + 1]
          end
        end
        local target = pattern == "SHA256SUMS" and vim.fs.joinpath(dir, "SHA256SUMS")
          or vim.fs.joinpath(dir, NAME)
        local content = pattern == "SHA256SUMS"
            and ("%s  %s\n"):format(vim.fn.sha256("the real bytes"), NAME)
          or "tampered bytes"
        local fh = assert(io.open(target, "wb"))
        fh:write(content)
        fh:close()
        vim.schedule(function()
          cb({ code = 0, stdout = "", stderr = "" })
        end)
        return
      end
      -- A verified-and-rejected download must stop, never reach git/zig.
      vim.schedule(function()
        cb({ code = 1, stdout = "", stderr = "must not run after a checksum mismatch" })
      end)
    end

    local captured = "pending"
    install.install({
      tools = { gh = true, gh_auth = true, git = true, zig = true },
      uname = { sysname = "Linux", machine = "x86_64" },
      on_done = function(err)
        captured = err
      end,
    })
    wait(function()
      return captured ~= "pending"
    end, 5000, "install to report")
    expect.matches(captured, "failed SHA256 verification")
    for _, cmd in ipairs(ran) do
      expect.falsy(
        cmd:match("^git clone"),
        "a checksum mismatch must never fall back to a source build"
      )
      expect.falsy(
        cmd:match("^zig build"),
        "a checksum mismatch must never fall back to a source build"
      )
    end
  end)

  it("names the reason in the toast when gh is simply absent (F5)", function()
    stub_system(ran)
    local toast = require("epicenter.ui.toast")
    toast.clear()
    local captured = "pending"
    install.install({
      tools = { gh = false, gh_auth = false, git = true, zig = true },
      on_done = function(err)
        captured = err
      end,
    })
    wait(function()
      return captured ~= "pending"
    end, 5000, "install to report")
    expect.matches(toast_text(), "gh %(GitHub CLI%) not installed")
    toast.clear()
  end)
end)

describe("the first-run notice", function()
  local toast = require("epicenter.ui.toast")

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
    install.forget_first_run_notice()
    toast.clear()
  end)

  after_each(function()
    toast.clear()
    install.forget_first_run_notice()
  end)

  it("stays quiet when a binary is there", function()
    local original = install.resolve
    install.resolve = function()
      return "/opt/navgraph", nil
    end
    install.first_run_notice()
    install.resolve = original
    expect.eq(toast.count(), 0, "nothing to say when navgraph resolves")
  end)

  it("points at :Epicenter install when there is no binary", function()
    local original = install.resolve
    install.resolve = function()
      return nil, "epicenter: navgraph not found (not on $PATH)"
    end
    install.first_run_notice()
    install.resolve = original
    expect.eq(toast.count(), 1)
    expect.matches(toast_text(), ":Epicenter install")
  end)

  it("says it once, not once per buffer", function()
    local original = install.resolve
    install.resolve = function()
      return nil, "epicenter: navgraph not found (not on $PATH)"
    end
    for _ = 1, 5 do
      install.first_run_notice()
    end
    install.resolve = original
    expect.eq(toast.count(), 1, "a repeat on every indexed buffer would be noise")
  end)
end)
