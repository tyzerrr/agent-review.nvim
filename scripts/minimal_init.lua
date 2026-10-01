vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(vim.fn.getcwd() .. "/deps/mini.nvim")
vim.o.swapfile = false
require("mini.test").setup()
