local install = require("epicenter.install")

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
    expect.eq(install.asset_pattern({ sysname = "Linux", machine = "x86_64" }), "*linux*x86_64*")
    expect.eq(install.asset_pattern({ sysname = "Darwin", machine = "arm64" }), "*macos*aarch64*")
    expect.eq(install.asset_pattern({ sysname = "Darwin", machine = "x86_64" }), "*macos*x86_64*")
  end)

  it("passes an unknown platform through rather than guessing", function()
    expect.eq(
      install.asset_pattern({ sysname = "FreeBSD", machine = "riscv64" }),
      "*freebsd*riscv64*"
    )
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
end)
