if vim.g.loaded_devwhere then
  return
end
vim.g.loaded_devwhere = true

local devwhere = require("devwhere")

local function complete()
  return vim.tbl_keys(devwhere.config.repos or {})
end

local source_hl = {
  cwd = "String",
  fallback = "Comment",
  none = "Comment",
  pinned = "Keyword",
  env = "Keyword",
  callback = "Keyword",
}

--- Render a status as highlighted echo chunks
---@param s Devwhere.Status
---@param last boolean omit the trailing newline
---@return table chunks for nvim_echo
local function chunks(s, last)
  local where = s.dir or "(none, manager's copy)"
  return {
    { s.name .. " -> ", "Title" },
    { where .. " [" .. s.source .. "]", source_hl[s.source] },
    { last and "" or "\n" },
  }
end

---@param statuses Devwhere.Status[]
local function echo_status(statuses)
  local out = {}
  for i, s in ipairs(statuses) do
    vim.list_extend(out, chunks(s, i == #statuses))
  end
  vim.api.nvim_echo(out, false, {})
end

vim.api.nvim_create_user_command("DevDir", function(opts)
  print(devwhere.dir(opts.args) or "(none)")
end, {
  nargs = 1,
  complete = complete,
  desc = "Print the dev directory devwhere resolves for a repo",
})

vim.api.nvim_create_user_command("DevStatus", function(opts)
  if opts.args ~= "" then
    echo_status({ devwhere.status(opts.args) })
    return
  end
  local names = vim.tbl_keys(devwhere.config.repos or {})
  if #names == 0 then
    print("devwhere: no repos registered in setup { repos = { ... } }")
    return
  end
  table.sort(names)
  local statuses = {}
  for _, name in ipairs(names) do
    table.insert(statuses, devwhere.status(name))
  end
  echo_status(statuses)
end, {
  nargs = "?",
  complete = complete,
  desc = "Show where and why devwhere resolved a repo",
})
