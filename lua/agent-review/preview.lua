local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("agent-review-preview")

-- 仮想行は文字のある所までしか背景が塗られないので、行末まで埋めて行全体を赤くする。
local PAD = string.rep(" ", 400)

local function lang_for(path, lines)
	local ft = vim.filetype.match({ filename = path, contents = lines })
	return ft, ft and vim.treesitter.language.get_lang(ft) or nil
end

---指定行だけtreesitterのハイライトを桁ごとに解決する。削除行（仮想行）にも構文色を付けるため。
---@param rows table<integer, true> 0-indexed
---@return table<integer, table<integer, string>> row -> col -> hl group
local function capture_map(lines, lang, rows)
	local map = {}
	if not lang or next(rows) == nil then
		return map
	end
	local text = table.concat(lines, "\n")
	local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
	if not ok or not parser then
		return map
	end
	pcall(parser.parse, parser, true)
	parser:for_each_tree(function(tree, ltree)
		local query = vim.treesitter.query.get(ltree:lang(), "highlights")
		if not query then
			return
		end
		for id, node in query:iter_captures(tree:root(), text, 0, -1) do
			local name = query.captures[id]
			if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
				local hl = "@" .. name .. "." .. ltree:lang()
				local sr, sc, er, ec = node:range()
				for r = sr, er do
					if rows[r] then
						local line = lines[r + 1] or ""
						local from = r == sr and sc or 0
						local to = r == er and ec or #line
						map[r] = map[r] or {}
						for c = from, to - 1 do
							map[r][c] = hl
						end
					end
				end
			end
		end
	end)
	return map
end

local function chunks_for(line, cols, bg)
	local chunks = {}
	local cur_hl, start = nil, 0
	for c = 0, #line do
		local hl = c < #line and cols and cols[c] or nil
		if c == #line or hl ~= cur_hl then
			if c > start then
				table.insert(chunks, { line:sub(start + 1, c), cur_hl and { bg, cur_hl } or bg })
			end
			cur_hl, start = hl, c
		end
	end
	table.insert(chunks, { PAD, bg })
	return chunks
end

---作業ツリーの内容を言語の構文色付きで描画し、追加行を緑、削除行を赤の仮想行で重ねる。
---@param buf integer
---@param item AgentReviewPickerItem
---@return integer lnum カーソルを置くべき行（1-indexed）
function M.render(buf, item)
	local c = item.change
	local work = #c.work > 0 and c.work or { "" }
	api.nvim_buf_set_lines(buf, 0, -1, false, work)
	api.nvim_buf_clear_namespace(buf, ns, 0, -1)

	local ft, lang = lang_for(c.file.path, #c.work > 0 and c.work or c.base)
	if not (lang and pcall(vim.treesitter.start, buf, lang)) and ft then
		vim.bo[buf].syntax = ft
	end

	local needed = {}
	for _, h in ipairs(c.hunks) do
		for i = h.base_start, h.base_start + h.base_count - 1 do
			needed[i - 1] = true
		end
	end
	local base_lang = select(2, lang_for(c.file.old_path or c.file.path, c.base))
	local cols = capture_map(c.base, base_lang, needed)

	for _, h in ipairs(c.hunks) do
		for l = h.work_start, h.work_start + h.work_count - 1 do
			api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { line_hl_group = "AgentReviewAdd", priority = 10 })
		end
		if h.base_count > 0 then
			local virt = {}
			for i = h.base_start, h.base_start + h.base_count - 1 do
				table.insert(virt, chunks_for(c.base[i] or "", cols[i - 1], "AgentReviewDelete"))
			end
			local row, above
			if h.work_count > 0 or h.work_start == 0 then
				row, above = math.max(h.work_start, 1) - 1, true
			else
				row, above = h.work_start - 1, false
			end
			api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = virt, virt_lines_above = above })
		end
	end

	local target = item.hunk_index and c.hunks[item.hunk_index] or c.hunks[1]
	return target and math.max(target.work_start, 1) or 1
end

return M
