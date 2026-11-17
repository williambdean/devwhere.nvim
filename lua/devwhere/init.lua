--- devwhere.nvim
--- Decide whether a local checkout of a repository should be loaded
--- instead of the copy your plugin manager installed, and where it is.
---
--- Manager agnostic: dir(name) returns a path or nil. nil means "nothing
--- special here", and the plugin manager does its normal thing. How each
--- manager consumes a path is documented in the README, not implemented
--- here.
---
--- Resolution order for dir(name):
---   1. repos[name].dir                static pin
---   2. $NVIM_DEV_<REPO_NAME>          env override
---   3. on_resolve callback            full context, may return a path
---   4. cwd detection                  when cwd belongs to a checkout or
---                                     worktree of that repo, use that dir
---   5. repos[name].fallback           canonical checkout, when configured
---   6. nil                            nothing special, use the manager's
---                                     installed copy

local M = {}

---@class Devwhere.RepoOpt
---@field dir? string static pin, skips all detection
---@field detect? boolean set false to veto cwd detection for this repo
---@field repo_name? string repo dir name when it differs from plugin name
---@field fallback? string canonical checkout to use when nothing else
---   matches, e.g. for private repos that have no published copy

---@class Devwhere.ResolveCtx
---@field name string plugin name passed to dir()
---@field repo_name string repo dir name being resolved
---@field cwd string working directory at resolution time
---@field root? string git top level of cwd, when inside a repo
---@field repo? string main repo of root, worktree links followed

---@alias Devwhere.Source "pinned"|"env"|"callback"|"cwd"|"fallback"|"none"

---@class Devwhere.Status
---@field name string
---@field repo_name string
---@field dir? string nil when no local checkout should be used
---@field source Devwhere.Source
---@field repo? string main repo when source is "cwd"
---@field env_key? string env variable when source is "env"

---@class Devwhere.Config
---@field notify boolean notify when cwd detection picks a copy
---@field repos table<string, Devwhere.RepoOpt>
---@field on_resolve? fun(ctx: Devwhere.ResolveCtx): string?

local defaults = {
  notify = true,
  repos = {},
  on_resolve = nil,
}

M.config = vim.deepcopy(defaults)

---@param opts? Devwhere.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

---@param path string
---@return string?
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("a")
  f:close()
  return data
end

--- Given the top level of a git checkout, return the main repository
--- directory it belongs to. Worktrees keep their git data under the main
--- repo, so their .git is a file pointing there.
---@param root string
---@return string
local function main_repo(root)
  local dotgit = vim.fs.joinpath(root, ".git")
  local stat = vim.uv.fs_stat(dotgit)
  if not stat or stat.type ~= "file" then
    return root
  end

  local gitdir = (read_file(dotgit) or ""):match("gitdir:%s*(%S+)")
  if not gitdir then
    return root
  end
  -- the gitdir line may be absolute or relative
  gitdir = vim.fs.normalize(
    gitdir:sub(1, 1) == "/" and gitdir or vim.fs.joinpath(root, gitdir)
  )

  local commondir = (read_file(vim.fs.joinpath(gitdir, "commondir")) or ""):match(
    "%S+"
  )
  if not commondir then
    return root
  end
  commondir = vim.fs.normalize(vim.fs.joinpath(gitdir, commondir))

  return vim.fs.normalize(vim.fs.joinpath(commondir, ".."))
end

--- Case insensitive comparison, for macOS case-insensitive filesystems
---@param a string
---@param b string
---@return boolean
local function same_name(a, b)
  return a:lower() == b:lower()
end

---@param name string
---@return Devwhere.RepoOpt
local function repo_opt(name)
  return (M.config.repos or {})[name] or {}
end

---@param name string
---@return string
local function repo_name(name)
  return repo_opt(name).repo_name or name
end

---@param name string
---@return string
local function env_key(name)
  return "NVIM_DEV_" .. name:upper():gsub("[%.%-]", "_")
end

--- Resolve a repo name to the status of its local checkout, if any.
---@param name string
---@return Devwhere.Status
local function resolve(name)
  local opt = repo_opt(name)
  local rname = repo_name(name)

  ---@param dir? string
  ---@param source Devwhere.Source
  ---@param extra table?
  ---@return Devwhere.Status
  local function result(dir, source, extra)
    return vim.tbl_extend("force", {
      name = name,
      repo_name = rname,
      dir = dir,
      source = source,
    }, extra or {})
  end

  if opt.dir then
    return result(opt.dir, "pinned")
  end

  local key = env_key(rname)
  local override = vim.env[key]
  if override and override ~= "" and vim.uv.fs_stat(override) then
    return result(vim.fs.normalize(override), "env", { env_key = key })
  end

  -- nvim can start from a deleted working directory: getcwd() is empty
  -- and uv.cwd() is nil, so cwd detection is impossible. Skip it and let
  -- the later tiers answer instead.
  local cwd = vim.fn.getcwd() or ""
  local root = cwd ~= "" and vim.fs.root(vim.fs.normalize(cwd), ".git") or nil
  local repo = root and main_repo(root) or nil

  if M.config.on_resolve then
    local path = M.config.on_resolve({
      name = name,
      repo_name = rname,
      cwd = cwd ~= "" and vim.fs.normalize(cwd) or nil,
      root = root,
      repo = repo,
    })
    if type(path) == "string" and path ~= "" and vim.uv.fs_stat(path) then
      return result(path, "callback")
    end
  end

  if
    root
    and repo
    and opt.detect ~= false
    and same_name(vim.fs.basename(repo), rname)
  then
    return result(root, "cwd", { repo = repo })
  end

  local fallback = opt.fallback
  if fallback and vim.uv.fs_stat(vim.fs.normalize(fallback)) then
    return result(vim.fs.normalize(fallback), "fallback")
  end

  return result(nil, "none")
end

---@param name string
---@return Devwhere.Status
function M.status(name)
  return resolve(name)
end

local notified = {}

--- Resolve a repo name to the local checkout to use, or nil when the
--- plugin manager's installed copy should be used.
---@param name string
---@return string?
function M.dir(name)
  local s = resolve(name)
  if M.config.notify and s.source == "cwd" and not notified[name] then
    notified[name] = true
    vim.notify(
      ("devwhere: %s -> %s"):format(name, s.dir),
      vim.log.levels.INFO,
      { title = "devwhere" }
    )
  end
  return s.dir
end

return M
