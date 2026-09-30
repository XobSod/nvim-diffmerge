if vim.g.loaded_diffmerge then
  return
end
vim.g.loaded_diffmerge = true

vim.api.nvim_create_user_command("DiffMerge", function(cmd)
  require("diffmerge.commands").run(cmd)
end, {
  nargs = "*",
  range = true,
  complete = function(arglead, cmdline, pos)
    return require("diffmerge.commands").complete(arglead, cmdline, pos)
  end,
  desc = "DiffMerge: git status / diff / merge / history",
})
