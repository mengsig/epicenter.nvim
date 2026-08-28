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
  -- F5 test seam: `tests/minimal_init.lua` pins this so the suite is
  -- structurally incapable of resolving a real $PATH/managed navgraph, no
  -- matter which spec forgets `lsp.auto_start = false`. Gated on the caller
  -- using the real prober (`opts.probe` unset) so a unit test that injects
  -- its OWN fake probe - `tests/cases/install_spec.lua`'s own coverage of
  -- this fallback contract - is unaffected either way.
  if configured == nil and opts.probe == nil and vim.g.epicenter_test_navgraph_path_pin then
    configured = vim.g.epicenter_test_navgraph_path_pin
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

--- The subcommand this plugin drives. A navgraph built before the editor
--- server shipped answers `--version` perfectly well and then exits 2 on
--- every `lsp` start (F7).
local SERVE_COMMAND = "lsp"

--- Cached per binary path: `--version` is a process spawn, and `attach` runs
--- on every buffer.
local capability_cache = {}

--- Reads the capabilities document navgraph answers `--version` with.
--- @return { version: string, commands: table<string, true>, documented: boolean }|nil
local function parse_capabilities(output)
  local text = vim.trim(output or "")
  if text == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" or type(decoded.commands) ~= "table" then
    -- Not the document: report the first line as the version, capped, rather
    -- than pasting 30KB of JSON (or of anything else) into `:checkhealth`.
    local first = vim.split(text, "\n", { plain = true })[1]
    return {
      version = #first > 120 and (first:sub(1, 117) .. "...") or first,
      commands = {},
      documented = false,
    }
  end
  local commands = {}
  for _, command in ipairs(decoded.commands) do
    if type(command) == "table" and type(command.name) == "string" then
      commands[command.name] = true
    end
  end
  local build = type(decoded.build) == "table" and decoded.build or {}
  return {
    version = build.buildVersion or build.version or "no version reported",
    commands = commands,
    documented = true,
  }
end

--- What `<path> --version` says the binary is and can do. navgraph answers
--- with a `navgraph.capabilities.v1` document rather than a version string,
--- and that document's `commands` is the only thing that can tell a build
--- carrying the editor server from one without, short of spawning one and
--- watching it die. `documented` is false when the output was not that
--- document - then `commands` is empty because it is UNKNOWN, not because
--- the binary has none.
--- @param opts? { run?: fun(cmd: string[]): { code: integer, stdout?: string } }
--- @return { version: string, commands: table<string, true>, documented: boolean }|nil,
---   string|nil err
function M.capabilities(path, opts)
  opts = opts or {}
  if opts.run == nil and capability_cache[path] then
    local cached = capability_cache[path]
    return cached.caps, cached.err
  end
  local run = opts.run or function(cmd)
    return vim.system(cmd, { text = true }):wait(3000)
  end

  local caps, err = nil, nil
  local result = run({ path, "--version" })
  if (result.code or 1) ~= 0 then
    err = ("`%s --version` exited %d"):format(path, result.code or -1)
  else
    caps = parse_capabilities(result.stdout)
    if not caps then
      err = ("`%s --version` printed nothing"):format(path)
    end
  end

  if opts.run == nil then
    capability_cache[path] = { caps = caps, err = err }
  end
  return caps, err
end

--- Whether this binary is KNOWN to have the `lsp` command every server start
--- needs. False for a binary whose capabilities could not be read - that is
--- an unknown, and callers treat the two differently.
--- @param caps table|nil the `M.capabilities` result
function M.serves_lsp(caps)
  return caps ~= nil and caps.documented and caps.commands[SERVE_COMMAND] == true
end

--- Why this binary cannot serve, as a line a user can act on - and only on
--- definite evidence: a binary whose `--version` this cannot read is left to
--- start and fail on its own terms rather than refused on a guess.
--- @return string|nil
function M.unservable_reason(path)
  local caps = M.capabilities(path)
  if not caps or not caps.documented or M.serves_lsp(caps) then
    return nil
  end
  return ("epicenter: %s is navgraph %s, which has no `%s` command"):format(
    path,
    caps.version,
    SERVE_COMMAND
  )
end

--- Startup failures already said out loud, so a project with fifty indexed
--- files says each one once. Without this a first run that cannot start a
--- server is a plugin that silently does nothing: every panel reports "not
--- running" only once you open one, and nothing points at the fix.
local announced = {}

--- One calm line for a startup failure, at most once per distinct reason.
--- @param reason string
function M.announce(reason)
  if type(reason) ~= "string" or announced[reason] then
    return
  end
  announced[reason] = true
  require("epicenter.ui.toast").notify(
    reason .. "\n`:Epicenter install` fetches a release, or builds one from source.",
    { level = "warn", timeout = 10000 }
  )
end

--- Called when a buffer that navgraph indexes could not start a server. Speaks
--- only when the reason is that there is no binary to run.
function M.first_run_notice()
  local path, err = M.resolve()
  if path then
    return
  end
  M.announce(err)
end

--- Test seam: forgets what has been announced.
function M.forget_first_run_notice()
  announced = {}
end

--- Forgets every cached `--version`. Called after an install and on an
--- explicit restart: the binary at a path can change under a running session,
--- and the whole point of `:Epicenter install` is that it just did.
function M.forget_capabilities()
  capability_cache = {}
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

--- Release asset pattern for this machine. Real assets are named
--- `navgraph-<arch>-<os>.tar.gz` (arch before os) - a glob's literal
--- fragments must appear in that order to match.
function M.asset_pattern(uname)
  uname = uname or uv.os_uname()
  local os_name = ({ Linux = "linux", Darwin = "macos", Windows_NT = "windows" })[uname.sysname]
    or uname.sysname:lower()
  local arch = ({ x86_64 = "x86_64", arm64 = "aarch64", aarch64 = "aarch64" })[uname.machine]
    or uname.machine
  return ("*%s*%s*"):format(arch, os_name)
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

--- Copies the resolved binary into place. A release download is already
--- SHA256-verified by `install_from_release`; a source build has no
--- artifact to check against, so `git clone` from the configured repo plus a
--- local `zig build` is its trust root (see navgraph.repo in README/vimdoc).
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

--- Whether `content`'s SHA256 matches what a `SHA256SUMS` file lists for
--- `name`. Pure - no disk, no network - so this is testable without touching
--- either. A repo that publishes no checksums, or lists no entry for this
--- asset, has nothing to verify against; that is not itself a failure. A
--- listed asset that does not match is a corrupted or tampered download.
--- @param sums_text string|nil `SHA256SUMS`'s content, or nil if none was published
--- @param name string the asset's filename, as `SHA256SUMS` lists it
--- @param content string the asset's raw bytes
--- @return true|nil ok, string|nil err
function M.verify_checksum(sums_text, name, content)
  if not sums_text then
    return true, nil
  end
  local expected
  for line in sums_text:gmatch("[^\r\n]+") do
    local hash, sum_name = line:match("^(%x+)%s+%*?(%S+)$")
    if sum_name == name then
      expected = hash
      break
    end
  end
  if not expected then
    return true, nil
  end
  local actual = vim.fn.sha256(content)
  if actual ~= expected then
    return nil,
      ("%s failed SHA256 verification (expected %s, got %s)"):format(name, expected, actual)
  end
  return true, nil
end

--- Reads `archive` and its sibling `SHA256SUMS` (when `gh` downloaded one)
--- off disk and hands their bytes to the pure `M.verify_checksum`.
--- @return string|nil err
local function checksum_error(dir, archive)
  local sums_path = vim.fs.joinpath(dir, "SHA256SUMS")
  local sums_text
  if uv.fs_stat(sums_path) then
    local sums_fh = io.open(sums_path, "rb")
    if sums_fh then
      sums_text = sums_fh:read("*a")
      sums_fh:close()
    end
  end

  local archive_fh = io.open(archive, "rb")
  if not archive_fh then
    return ("could not open %s to verify its checksum"):format(archive)
  end
  local content = archive_fh:read("*a")
  archive_fh:close()

  local _, err = M.verify_checksum(sums_text, vim.fs.basename(archive), content)
  return err
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
    "--pattern",
    "SHA256SUMS",
    "--clobber",
  }
  run(cmd, {}, function(err)
    if err then
      return cb(err)
    end
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

    progress.update(0.5, "verifying checksum")
    local checksum_err = checksum_error(tmp, archive)
    if checksum_err then
      return cb(checksum_err)
    end

    progress.update(0.6, "unpacking")
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
  local function done(err, path, note)
    finished = true
    final_err, final_path = err, path
    -- A new binary at the same path: what the old one could do is stale, and
    -- so is any "cannot serve" line already said about it.
    M.forget_capabilities()
    M.forget_first_run_notice()
    -- `note` names why a source build ran when a release download was
    -- possible in principle, so the toast says why regardless of whether the
    -- fallback build itself then succeeded or failed.
    if err then
      local message = note and (note .. "\n" .. err) or err
      require("epicenter.log").error("install failed: %s", message)
      progress.finish(message, "error")
    else
      local message = "navgraph installed to " .. path
      if note then
        message = message .. "\n" .. note
      end
      progress.finish(message)
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

    local function cleanup_then(err, path, note)
      vim.fn.delete(tmp, "rf")
      done(err, path, note)
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
        local note = ("release download unavailable (%s); built from source instead"):format(err)
        progress.update(0.2, note)
        vim.fn.delete(tmp, "rf")
        vim.fn.mkdir(tmp, "p")
        install_from_source(cfg, tmp, progress, function(source_err, source_path)
          cleanup_then(source_err, source_path, note)
        end)
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
