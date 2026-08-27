--- Finding the navgraph binary, and getting one when it is missing.
---
--- Everything runs through `vim.system` (async, never `os.execute`), and the
--- decision of *how* to install is a pure function of which tools exist, so it
--- is testable without touching the network.
local M = {}

local uv = vim.uv or vim.loop

--- Where `:Epicenter install` puts the binary it manages.
function M.managed_path()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "epicenter", "bin", "navgraph")
end

local function is_executable(path)
  return path ~= nil and path ~= "" and vim.fn.executable(path) == 1
end

--- Binary to launch, in priority order: the configured path, `$PATH`, then the
--- managed install.
---
--- @param opts? { path?: string, probe?: fun(path: string): boolean }
--- @return string|nil path, string|nil err
function M.resolve(opts)
  opts = opts or {}
  local probe = opts.probe or is_executable
  local configured = opts.path
  if configured == nil then
    configured = require("epicenter.config").get().navgraph.path
  end

  if configured then
    if probe(configured) then
      return configured, nil
    end
    return nil,
      ("epicenter: navgraph.path is set to %q but it is not executable"):format(configured)
  end

  if probe("navgraph") then
    return "navgraph", nil
  end

  local managed = M.managed_path()
  if probe(managed) then
    return managed, nil
  end

  return nil,
    ("epicenter: navgraph not found (not on $PATH, not at %s). Run :Epicenter install, or set navgraph.path."):format(
      managed
    )
end

--- How to install, given what is available. Pure.
---
--- @param tools { gh: boolean, gh_auth: boolean, git: boolean, zig: boolean }
--- @return "release"|"source"|nil kind, string|nil err
function M.plan(tools)
  if tools.gh and tools.gh_auth then
    return "release", nil
  end
  if tools.git and tools.zig then
    return "source", nil
  end

  local missing = {}
  if not tools.gh then
    table.insert(missing, "gh (GitHub CLI) is not installed")
  elseif not tools.gh_auth then
    table.insert(missing, "gh is installed but not authenticated (run `gh auth login`)")
  end
  if not tools.git then
    table.insert(missing, "git is not installed")
  end
  if not tools.zig then
    table.insert(missing, "zig is not installed (needed to build navgraph from source)")
  end
  return nil, "epicenter: cannot install navgraph - " .. table.concat(missing, "; ")
end

--- Release asset pattern for this machine.
function M.asset_pattern(uname)
  uname = uname or uv.os_uname()
  local os_name = ({ Linux = "linux", Darwin = "macos", Windows_NT = "windows" })[uname.sysname]
    or uname.sysname:lower()
  local arch = ({ x86_64 = "x86_64", arm64 = "aarch64", aarch64 = "aarch64" })[uname.machine]
    or uname.machine
  return ("*%s*%s*"):format(os_name, arch)
end

--- @param cb fun(tools: table)
function M.detect_tools(cb)
  local tools = {
    gh = vim.fn.executable("gh") == 1,
    git = vim.fn.executable("git") == 1,
    zig = vim.fn.executable("zig") == 1,
    gh_auth = false,
  }
  if not tools.gh then
    return cb(tools)
  end
  vim.system({ "gh", "auth", "status" }, { text = true }, function(result)
    tools.gh_auth = result.code == 0
    vim.schedule(function()
      cb(tools)
    end)
  end)
end

--- Runs `cmd`, reporting a failure with the command's own stderr.
local function run(cmd, opts, cb)
  vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {}), function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local detail = vim.trim((result.stderr or "") .. (result.stdout or ""))
        cb(
          ("`%s` failed (exit %d)%s"):format(
            table.concat(cmd, " "),
            result.code,
            detail ~= "" and (": " .. detail) or ""
          )
        )
        return
      end
      cb(nil, result)
    end)
  end)
end

local function install_binary(source_path, cb)
  local target = M.managed_path()
  vim.fn.mkdir(vim.fs.dirname(target), "p")
  local ok, err = uv.fs_copyfile(source_path, target)
  if not ok then
    return cb(("could not copy %s to %s: %s"):format(source_path, target, err))
  end
  uv.fs_chmod(target, 493)
  cb(nil, target)
end

--- First file named `navgraph` under `dir`.
local function find_binary(dir)
  local found = vim.fs.find("navgraph", { path = dir, type = "file", limit = 1 })
  return found[1]
end

local function install_from_release(cfg, tmp, progress, cb)
  progress.update(0.3, "downloading the latest release")
  local cmd = {
    "gh",
    "release",
    "download",
    "--repo",
    cfg.navgraph.repo,
    "--dir",
    tmp,
    "--pattern",
    M.asset_pattern(),
    "--clobber",
  }
  run(cmd, {}, function(err)
    if err then
      return cb(err)
    end
    progress.update(0.6, "unpacking")
    local archive = vim.fs.find(function(name)
      return name:match("%.tar%.gz$") or name:match("%.tgz$") or name:match("%.zip$")
    end, { path = tmp, type = "file", limit = 1 })[1]

    local function finish()
      local binary = find_binary(tmp)
      if not binary then
        return cb("the release contained no `navgraph` binary")
      end
      install_binary(binary, cb)
    end

    if not archive then
      return finish()
    end
    local extract = archive:match("%.zip$") and { "unzip", "-o", archive, "-d", tmp }
      or { "tar", "-xzf", archive, "-C", tmp }
    run(extract, { cwd = tmp }, function(extract_err)
      if extract_err then
        return cb(extract_err)
      end
      finish()
    end)
  end)
end

local function install_from_source(cfg, tmp, progress, cb)
  progress.update(0.2, "cloning " .. cfg.navgraph.repo)
  local clone = { "git", "clone", "--depth", "1" }
  if cfg.navgraph.install_ref then
    vim.list_extend(clone, { "--branch", cfg.navgraph.install_ref })
  end
  vim.list_extend(clone, { ("https://github.com/%s.git"):format(cfg.navgraph.repo), tmp })

  run(clone, {}, function(err)
    if err then
      return cb(err)
    end
    progress.update(0.5, "building with zig (this takes a minute)")
    run({ "zig", "build", "-Doptimize=ReleaseFast" }, { cwd = tmp }, function(build_err)
      if build_err then
        return cb(build_err)
      end
      local binary = vim.fs.joinpath(tmp, "zig-out", "bin", "navgraph")
      if not uv.fs_stat(binary) then
        return cb("the build produced no binary at " .. binary)
      end
      install_binary(binary, cb)
    end)
  end)
end

--- Downloads a release when `gh` is authenticated, otherwise builds from
--- source. Exposed as `require("epicenter").install()`.
---
--- A plugin manager's `build =` hook treats the function *returning* as the
--- step being done, but this is normally fully async - pass `wait` for a
--- build hook so it blocks until installation actually finishes.
--- @param opts? { tools?: table, on_done?: fun(err: string|nil, path: string|nil),
---   wait?: boolean|integer }
---   `tools` skips detection when the caller already probed the machine.
---   `wait`: block until done and return `ok, err_or_path`; `true` waits up
---   to 120s, or pass a custom timeout in ms.
--- @return boolean|nil ok, string|nil err_or_path only set when `wait` is given
function M.install(opts)
  opts = opts or {}
  local cfg = require("epicenter.config").get()
  local toast = require("epicenter.ui.toast")
  local progress = toast.progress("installing navgraph")

  local finished, final_err, final_path = false, nil, nil
  local function done(err, path)
    finished = true
    final_err, final_path = err, path
    if err then
      require("epicenter.log").error("install failed: %s", err)
      progress.finish(err, "error")
    else
      progress.finish("navgraph installed to " .. path)
    end
    if opts.on_done then
      opts.on_done(err, path)
    end
  end

  local function with_tools(tools)
    local kind, plan_err = M.plan(tools)
    if not kind then
      return done(plan_err)
    end

    local tmp =
      vim.fs.joinpath(vim.fn.stdpath("cache"), "epicenter-install-" .. tostring(uv.hrtime()))
    vim.fn.mkdir(tmp, "p")

    local function cleanup_then(err, path)
      vim.fn.delete(tmp, "rf")
      done(err, path)
    end

    if kind == "release" then
      install_from_release(cfg, tmp, progress, function(err, path)
        if not err then
          return cleanup_then(nil, path)
        end
        -- No usable release: fall back to a source build rather than stopping.
        if not (tools.git and tools.zig) then
          return cleanup_then(err)
        end
        progress.update(0.2, "no usable release; building from source")
        vim.fn.delete(tmp, "rf")
        vim.fn.mkdir(tmp, "p")
        install_from_source(cfg, tmp, progress, cleanup_then)
      end)
    else
      install_from_source(cfg, tmp, progress, cleanup_then)
    end
  end

  if opts.tools then
    with_tools(opts.tools)
  else
    M.detect_tools(with_tools)
  end

  if opts.wait then
    local timeout = opts.wait == true and 120000 or opts.wait
    local ok = vim.wait(timeout, function()
      return finished
    end, 50)
    if not ok then
      return false, ("epicenter: install timed out after %dms"):format(timeout)
    end
    return final_err == nil, final_err or final_path
  end
end

return M
