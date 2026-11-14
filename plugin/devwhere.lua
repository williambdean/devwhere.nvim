if vim.g.loaded_devwhere then
  return
end
vim.g.loaded_devwhere = true

local devwhere = require("devwhere")

local function complete()
  return vim.tbl_keys(devwhere.config.repos or {})
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
    print(devwhere.format(devwhere.status(opts.args)))
    return
  end
  local names = vim.tbl_keys(devwhere.config.repos or {})
  if #names == 0 then
    print("devwhere: no repos registered in setup { repos = { ... } }")
    return
  end
  table.sort(names)
  for _, name in ipairs(names) do
    print(devwhere.format(devwhere.status(name)))
  end
end, {
  nargs = "?",
  complete = complete,
  desc = "Show where and why devwhere resolved a repo",
})
