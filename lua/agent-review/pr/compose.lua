-- コメントなどを書く小さな入力窓。:w（または <C-s>）で保存して閉じ、q で保存せずに閉じる。
local M = {}

local api = vim.api
local counter = 0

---@param opts { title: string, lines?: string[], on_save: fun(body: string) }
function M.open(opts)
	counter = counter + 1
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(buf, ("agent-review://compose/%d"):format(counter))
	-- acwrite にして :w を BufWriteCmd で受け取る（ファイルには書かない）。
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines or {})
	vim.bo[buf].modified = false
	vim.bo[buf].filetype = "markdown"

	local width = math.min(90, vim.o.columns - 8)
	local height = math.min(14, vim.o.lines - 8)
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = opts.title,
		footer = " :w save · q cancel ",
		footer_pos = "right",
	})
	vim.wo[win].wrap = true

	local function close()
		pcall(api.nvim_win_close, win, true)
	end
	api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
			while #lines > 0 and vim.trim(lines[#lines]) == "" do
				table.remove(lines)
			end
			vim.bo[buf].modified = false
			vim.cmd("stopinsert")
			close()
			opts.on_save(table.concat(lines, "\n"))
		end,
	})
	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
	vim.keymap.set({ "n", "i" }, "<C-s>", "<Cmd>write<CR>", { buffer = buf })
	if #(opts.lines or {}) == 0 then
		vim.cmd("startinsert")
	end
	return buf, win
end

return M
