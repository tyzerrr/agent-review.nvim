-- 変更ファイルのツリー（VSCodeのエクスプローラー風）。描画は純粋関数にして、窓の管理は tree_view.lua に置く。
local M = {}

-- 1文字にそろえる。untracked はVSCodeに合わせて U。
local STATUS_CHAR = { ["?"] = "U" }

local STATUS_HL = {
	M = "AgentReviewTreeModified",
	T = "AgentReviewTreeModified",
	A = "AgentReviewTreeAdded",
	["?"] = "AgentReviewTreeAdded",
	C = "AgentReviewTreeAdded",
	R = "AgentReviewTreeRenamed",
	D = "AgentReviewTreeDeleted",
}

local function split(path)
	return vim.split(path, "/", { plain = true })
end

-- VSCodeのエクスプローラーと同じく大文字小文字を区別せずに並べる（同じなら元の文字列で決める）。
local function name_lt(a, b)
	local la, lb = a:lower(), b:lower()
	if la ~= lb then
		return la < lb
	end
	return a < b
end

---フォルダを先、ファイルを後に、それぞれ名前順で並べる。]f の順番もツリーの見た目に合わせる。
---@generic F: { path: string }
---@param files F[]
---@return F[]
function M.sort(files)
	local keyed = vim.tbl_map(function(f)
		return { f = f, parts = split(f.path) }
	end, files)
	table.sort(keyed, function(a, b)
		local n = math.min(#a.parts, #b.parts)
		for i = 1, n do
			if a.parts[i] ~= b.parts[i] then
				local a_dir, b_dir = i < #a.parts, i < #b.parts
				if a_dir ~= b_dir then
					return a_dir
				end
				return name_lt(a.parts[i], b.parts[i])
			end
		end
		return #a.parts > #b.parts
	end)
	return vim.tbl_map(function(k)
		return k.f
	end, keyed)
end

local function new_dir(path)
	return { path = path, dirs = {}, dir_names = {}, files = {} }
end

local function trie(list)
	local root = new_dir("")
	for _, c in ipairs(list) do
		local parts = split(c.file.path)
		local node = root
		for i = 1, #parts - 1 do
			local name = parts[i]
			if not node.dirs[name] then
				node.dirs[name] = new_dir(node.path == "" and name or (node.path .. "/" .. name))
				table.insert(node.dir_names, name)
			end
			node = node.dirs[name]
		end
		table.insert(node.files, { name = parts[#parts], change = c })
	end
	return root
end

---@class AgentReviewTreeNode
---@field kind "dir"|"file"
---@field path string
---@field depth integer
---@field open? boolean
---@field change? AgentReviewChange

---@class AgentReviewTreeRender
---@field lines string[]
---@field nodes table<integer, AgentReviewTreeNode> 行番号(1始まり) → ノード
---@field file_line table<string, integer> パス → 行番号
---@field highlights { line: integer, col: integer, end_col: integer, group: string }[] 行は0始まり
---@field virt table<integer, [string, string][]> 行番号(1始まり) → 行末に出す文字

---@param list AgentReviewChange[] M.sort 済みでなくてよい
---@param opts? { collapsed?: table<string, boolean>, viewed?: fun(path: string): boolean, icon?: fun(name: string): string|nil, string|nil }
---@return AgentReviewTreeRender
function M.build(list, opts)
	opts = opts or {}
	local collapsed = opts.collapsed or {}
	local out = { lines = {}, nodes = {}, file_line = {}, highlights = {}, virt = {} }

	local function add_file(entry, depth)
		local c = entry.change
		local f = c.file
		local indent = ("  "):rep(depth)
		local prefix = "  "
		local icon, icon_hl
		if opts.icon then
			icon, icon_hl = opts.icon(entry.name)
		end
		if icon then
			prefix = icon .. " "
		end
		local line = indent .. prefix .. entry.name
		table.insert(out.lines, line)
		local lnum = #out.lines
		out.nodes[lnum] = { kind = "file", path = f.path, depth = depth, change = c }
		out.file_line[f.path] = lnum
		if icon and icon_hl then
			table.insert(out.highlights, { line = lnum - 1, col = #indent, end_col = #indent + #icon, group = icon_hl })
		end
		local viewed = opts.viewed and opts.viewed(f.path)
		table.insert(out.highlights, {
			line = lnum - 1,
			col = #indent + #prefix,
			end_col = #line,
			group = viewed and "AgentReviewTreeViewed" or (STATUS_HL[f.status] or "AgentReviewTreeModified"),
		})
		local virt = {}
		if viewed then
			table.insert(virt, { "✓ ", "AgentReviewTreeViewedMark" })
		end
		if (c.added or 0) > 0 then
			table.insert(virt, { ("+%d "):format(c.added), "AgentReviewTreeAddedCount" })
		end
		if (c.removed or 0) > 0 then
			table.insert(virt, { ("-%d "):format(c.removed), "AgentReviewTreeRemovedCount" })
		end
		table.insert(virt, { STATUS_CHAR[f.status] or f.status, STATUS_HL[f.status] or "AgentReviewTreeModified" })
		out.virt[lnum] = virt
	end

	local function walk(dir, depth)
		table.sort(dir.dir_names, name_lt)
		for _, name in ipairs(dir.dir_names) do
			local child = dir.dirs[name]
			local label = name
			-- 中身がフォルダ1つだけのフォルダは1行にまとめる（VSCodeのcompact folders）。
			while #child.files == 0 and #child.dir_names == 1 do
				local only = child.dir_names[1]
				label = label .. "/" .. only
				child = child.dirs[only]
			end
			local open = not collapsed[child.path]
			local indent = ("  "):rep(depth)
			local line = indent .. (open and "▾ " or "▸ ") .. label .. "/"
			table.insert(out.lines, line)
			local lnum = #out.lines
			out.nodes[lnum] = { kind = "dir", path = child.path, depth = depth, open = open }
			table.insert(out.highlights, { line = lnum - 1, col = #indent, end_col = #line, group = "AgentReviewTreeDir" })
			if open then
				walk(child, depth + 1)
			end
		end
		table.sort(dir.files, function(a, b)
			return name_lt(a.name, b.name)
		end)
		for _, entry in ipairs(dir.files) do
			add_file(entry, depth)
		end
	end

	walk(trie(list), 0)
	return out
end

---ツリーの上に出す要約。狭い窓では後ろから削れるよう、項目ごとに返す。
---@param list AgentReviewChange[]
---@param viewed? fun(path: string): boolean
---@return string[]
function M.summary_parts(list, viewed)
	if #list == 0 then
		return { "no changes" }
	end
	local added, removed, n_viewed = 0, 0, 0
	for _, c in ipairs(list) do
		added = added + (c.added or 0)
		removed = removed + (c.removed or 0)
		if viewed and viewed(c.file.path) then
			n_viewed = n_viewed + 1
		end
	end
	-- 進み具合の方が大事なので、印があればファイル数の代わりに「何件中何件見たか」を出す。
	local count = n_viewed > 0 and ("%d/%d viewed"):format(n_viewed, #list)
		or ("%d file%s"):format(#list, #list == 1 and "" or "s")
	return { count, ("+%d -%d"):format(added, removed) }
end

---@param list AgentReviewChange[]
---@param viewed? fun(path: string): boolean
function M.summary(list, viewed)
	return table.concat(M.summary_parts(list, viewed), "  ")
end

return M
