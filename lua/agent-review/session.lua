local changes = require("agent-review.changes")
local config = require("agent-review.config")
local git = require("agent-review.git")
local highlight = require("agent-review.highlight")
local keymaps = require("agent-review.keymaps")

local api = vim.api

local SCHEME = "agent-review://"

---@class AgentReviewSession
---@field root string
---@field base string ユーザーが指定したrev
---@field base_sha string 開いた時点で固定したコミット。レビュー中にHEADが動いても比較元を変えない。
---@field files AgentReviewFile[]
---@field tab integer
---@field left_win integer
---@field right_win integer
local Session = {}
Session.__index = Session

function Session.new(root, base, base_sha)
	local self = setmetatable({}, Session)
	self.root = root
	self.base = base
	self.base_sha = base_sha
	self.short_sha = base_sha:sub(1, 8)
	self.files = {}
	self.file_index = {}
	self.base_bufs = {} -- rel -> buf
	self.deleted_bufs = {} -- rel -> buf
	self.saved_maps = {} -- buf -> { lhs -> maparg }
	self.augroup = api.nvim_create_augroup("AgentReviewSession", { clear = true })
	return self
end

function Session:valid()
	return not self.closed
		and self.tab
		and api.nvim_tabpage_is_valid(self.tab)
		and api.nvim_win_is_valid(self.left_win)
		and api.nvim_win_is_valid(self.right_win)
end

local function signature(files)
	return table.concat(
		vim.tbl_map(function(f)
			return f.status .. f.path
		end, files),
		"\0"
	)
end

function Session:refresh_files()
	local before = signature(self.files)
	self.files = git.changed_files(self.root, self.base_sha)
	self.file_index = {}
	for i, f in ipairs(self.files) do
		self.file_index[f.path] = i
	end
	if self.qf_id and signature(self.files) ~= before then
		self:update_quickfix()
	end
end

function Session:qf_list_alive()
	return self.qf_id and vim.fn.getqflist({ id = self.qf_id }).id == self.qf_id
end

---@param mode? "files"|"hunks"
---@param opts? { resolve_deleted?: boolean }
function Session:update_quickfix(mode, opts)
	mode = mode or self.qf_mode or config.options.quickfix.mode
	self.qf_mode = mode
	local resolve = (opts or {}).resolve_deleted ~= false
			and function(f)
				if f.status == "D" then
					return self:deleted_buffer(f.path)
				end
			end
		or nil
	local list = changes.collect(self.root, self.base_sha, self.files)
	local what = {
		title = "Agent Review: " .. self.base .. (mode == "hunks" and " (hunks)" or ""),
		items = changes.qf_items(self.root, list, mode, resolve),
		context = { agent_review = true },
	}
	if self:qf_list_alive() then
		-- "r"で置き換えると選択位置が先頭に戻るため、同じファイル（hunksなら同じ行も）の項目を選び直す。
		local old = vim.fn.getqflist({ id = self.qf_id, idx = 0, items = 1 })
		local cur = old.items[old.idx]
		what.id = self.qf_id
		vim.fn.setqflist({}, "r", what)
		if cur then
			local new_idx
			for i, item in ipairs(vim.fn.getqflist({ id = self.qf_id, items = 1 }).items) do
				if item.bufnr == cur.bufnr then
					new_idx = new_idx or i
					if item.lnum == cur.lnum then
						new_idx = i
						break
					end
				end
			end
			if new_idx then
				vim.fn.setqflist({}, "a", { id = self.qf_id, idx = new_idx })
			end
		end
	else
		vim.fn.setqflist({}, " ", what)
		self.qf_id = vim.fn.getqflist({ id = 0 }).id
	end
end

function Session:open_quickfix_window()
	if not self:valid() then
		return
	end
	local cur = api.nvim_get_current_win()
	api.nvim_set_current_win(self.right_win)
	vim.cmd("botright copen " .. config.options.quickfix.height)
	if api.nvim_win_is_valid(cur) then
		api.nvim_set_current_win(cur)
	end
end

---@return AgentReviewFile|nil
function Session:file(rel)
	local i = self.file_index[rel]
	return i and self.files[i] or nil
end

---右窓のバッファが表すroot相対パス。リポジトリ外や特殊バッファならnil。
function Session:rel_path(buf)
	local tagged = vim.b[buf].agent_review_path
	if tagged then
		return tagged
	end
	if vim.bo[buf].buftype ~= "" then
		return nil
	end
	local name = api.nvim_buf_get_name(buf)
	if name == "" then
		return nil
	end
	local abs = vim.fn.resolve(vim.fn.fnamemodify(name, ":p"))
	local prefix = self.root .. "/"
	if abs:sub(1, #prefix) == prefix then
		return abs:sub(#prefix + 1)
	end
	return nil
end

local function scratch_buf(name)
	local existing = vim.fn.bufnr(name)
	if existing ~= -1 then
		pcall(api.nvim_buf_delete, existing, { force = true })
	end
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(buf, name)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	return buf
end

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
end

local function set_filetype(buf, rel, lines)
	local ft = vim.filetype.match({ filename = rel, contents = lines })
	if not ft then
		return
	end
	vim.bo[buf].filetype = ft
	-- FileTypeでtreesitterを起動しない設定でも、base側にハイライトを付ける。
	if not vim.treesitter.highlighter.active[buf] then
		local lang = vim.treesitter.language.get_lang(ft)
		if lang then
			pcall(vim.treesitter.start, buf, lang)
		end
	end
end

---@return integer|nil buf base時点で追跡されていなければnil
function Session:base_buffer(rel)
	local cached = self.base_bufs[rel]
	if cached and api.nvim_buf_is_valid(cached) then
		return cached
	end
	local f = self:file(rel)
	if not f then
		-- レビュー開始後にエージェントが作ったファイルかもしれない。
		self:refresh_files()
		f = self:file(rel)
	end
	local base_rel = f and f.old_path or rel
	local lines = git.show(self.root, self.base_sha, base_rel)
	if not lines then
		if not f or (f.status ~= "A" and f.status ~= "?") then
			return nil -- gitignore対象など。差分の対象外。
		end
		lines = {}
	end
	local buf = scratch_buf(SCHEME .. self.short_sha .. "/" .. rel)
	set_lines(buf, lines)
	vim.b[buf].agent_review_side = "base"
	vim.b[buf].agent_review_path = rel
	vim.b[buf].agent_review_base_path = base_rel
	set_filetype(buf, base_rel, lines)
	self:map_base_buffer(buf)
	self.base_bufs[rel] = buf
	return buf
end

function Session:placeholder(message)
	if not (self.placeholder_buf and api.nvim_buf_is_valid(self.placeholder_buf)) then
		self.placeholder_buf = scratch_buf(SCHEME .. "placeholder")
		vim.b[self.placeholder_buf].agent_review_side = "base"
		self:map_base_buffer(self.placeholder_buf)
	end
	set_lines(self.placeholder_buf, { "", "  " .. message })
	return self.placeholder_buf
end

function Session:deleted_buffer(rel)
	local cached = self.deleted_bufs[rel]
	if cached and api.nvim_buf_is_valid(cached) then
		return cached
	end
	local buf = scratch_buf(SCHEME .. "deleted/" .. rel)
	set_lines(buf, {})
	vim.b[buf].agent_review_path = rel
	vim.b[buf].agent_review_side = "work"
	set_filetype(buf, rel, {})
	self.deleted_bufs[rel] = buf
	return buf
end

local function set_diff(win, on)
	local fold = config.options.fold_unchanged
	api.nvim_win_call(win, function()
		if on then
			if not vim.wo.diff then
				vim.cmd("diffthis")
			end
			if not fold then
				vim.wo.foldenable = false
			end
		elseif vim.wo.diff then
			vim.cmd("diffoff")
		end
	end)
end

local function winbar_escape(s)
	return (s:gsub("%%", "%%%%"))
end

function Session:update_winbar(rel, base_note)
	if not config.options.winbar then
		return
	end
	local left, right
	if rel then
		local f = self:file(rel)
		local base_rel = f and f.old_path or rel
		local pos = self.file_index[rel] and ("[%d/%d] "):format(self.file_index[rel], #self.files) or ""
		local status = f and (f.status .. " ") or ""
		left = ("%%#AgentReviewWinbarBase# BASE %%* %s  %s%s"):format(
			winbar_escape(self.base),
			winbar_escape(base_rel),
			base_note and ("  (" .. base_note .. ")") or ""
		)
		right = ("%%#AgentReviewWinbarWork# WORKING %%* %s%s%s"):format(pos, status, winbar_escape(rel))
	else
		left = "%#AgentReviewWinbarBase# BASE %* (not compared)"
		right = "%#AgentReviewWinbarWork# WORKING %* "
			.. winbar_escape(vim.fn.bufname(api.nvim_win_get_buf(self.right_win)))
	end
	vim.wo[self.left_win].winbar = left
	vim.wo[self.right_win].winbar = right
end

---右窓の内容に合わせて左窓（base）を作り直す。追従の中核。
function Session:sync()
	if self.syncing or not self:valid() then
		return
	end
	self.syncing = true
	local ok, err = pcall(function()
		local buf = api.nvim_win_get_buf(self.right_win)
		local rel = self:rel_path(buf)
		local f = rel and self:file(rel)
		if f and f.status == "D" and vim.bo[buf].buftype == "" and not vim.uv.fs_stat(self.root .. "/" .. rel) then
			-- 削除済みファイルを:eで開くと空の実バッファになり、誤って保存すると復活してしまう。
			buf = self:deleted_buffer(rel)
			api.nvim_win_set_buf(self.right_win, buf)
		end
		local left = rel and self:base_buffer(rel)
		local pair = left and (left .. ":" .. buf) or nil
		if pair ~= self.diff_pair then
			-- 'diff'の窓で一度表示したバッファは隠れた後もdiff対象に残り、9個目でE96になる。
			-- 組み合わせが変わるたびに:diffoff!で隠れバッファごと一掃してから張り直す。
			api.nvim_win_call(self.right_win, function()
				vim.cmd("diffoff!")
			end)
			self.diff_pair = pair
		end
		if left then
			if api.nvim_win_get_buf(self.left_win) ~= left then
				api.nvim_win_set_buf(self.left_win, left)
			end
			f = self:file(rel)
			local note = f and (f.status == "A" or f.status == "?") and "new file" or nil
			set_diff(self.left_win, true)
			set_diff(self.right_win, true)
			self:update_winbar(rel, note)
		else
			local msg = rel and "not tracked by git: " .. rel or "outside of the repository: not compared"
			api.nvim_win_set_buf(self.left_win, self:placeholder(msg))
			set_diff(self.left_win, false)
			set_diff(self.right_win, false)
			self:update_winbar(nil)
		end
		self.left_base_buf = api.nvim_win_get_buf(self.left_win)
		highlight.apply(self.left_win, "base")
		highlight.apply(self.right_win, "work")
		self:map_work_buffer(buf)
		self.current_rel = rel
	end)
	self.syncing = false
	if not ok then
		vim.notify("[agent-review] " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	-- LSPジャンプはバッファ表示の後でカーソルを動かすので、その後で左右のスクロールを揃える。
	vim.schedule(function()
		if self:valid() and vim.wo[self.right_win].diff then
			api.nvim_win_call(self.right_win, function()
				vim.cmd("syncbind")
			end)
		end
	end)
end

---@param rel string root相対パス
function Session:show(rel)
	local abs = self.root .. "/" .. rel
	if vim.uv.fs_stat(abs) then
		api.nvim_win_call(self.right_win, function()
			vim.cmd.edit(vim.fn.fnameescape(abs))
		end)
	else
		api.nvim_win_set_buf(self.right_win, self:deleted_buffer(rel))
	end
	self:sync()
end

function Session:step(delta)
	self:refresh_files()
	local n = #self.files
	if n == 0 then
		vim.notify("[agent-review] no changed files", vim.log.levels.INFO)
		return
	end
	local idx = self.current_rel and self.file_index[self.current_rel]
	local next_idx
	if idx then
		next_idx = (idx - 1 + delta) % n + 1
	else
		next_idx = delta > 0 and 1 or n
	end
	self:show(self.files[next_idx].path)
end

function Session:pick()
	require("agent-review.picker").pick()
end

function Session:pick_hunks()
	require("agent-review.picker").pick_hunks()
end

---左窓（base）に実ファイルが開かれたら右窓へ移す。
---telescopeやquickfixは「直前の窓」に開くため、左窓から操作すると左に入ってしまう。
function Session:redirect_from_left()
	if not self:valid() then
		return
	end
	local buf = api.nvim_win_get_buf(self.left_win)
	if vim.b[buf].agent_review_side == "base" then
		return
	end
	local cursor = api.nvim_win_get_cursor(self.left_win)
	local focused = api.nvim_get_current_win() == self.left_win
	local back = self.left_base_buf
	if not (back and api.nvim_buf_is_valid(back)) then
		back = self:placeholder("")
	end
	api.nvim_win_set_buf(self.left_win, back)
	api.nvim_win_set_buf(self.right_win, buf)
	pcall(api.nvim_win_set_cursor, self.right_win, cursor)
	if focused then
		api.nvim_set_current_win(self.right_win)
	end
	self:sync()
end

-- 既存のバッファローカルマッピングを退避してから上書きし、終了時に戻す。
function Session:buf_map(buf, mode, lhs, rhs, desc)
	if not lhs or lhs == "" then
		return
	end
	self.saved_maps[buf] = self.saved_maps[buf] or {}
	local key = mode .. lhs
	if self.saved_maps[buf][key] == nil then
		local prev = vim.fn.maparg(lhs, mode, false, true)
		self.saved_maps[buf][key] = (prev.buffer == 1) and prev or false
	end
	vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, nowait = true })
end

---@param side "base"|"work"
function Session:apply_buffer_maps(buf, side)
	for _, spec in ipairs(keymaps.buffer_specs(config.options.keymaps, side)) do
		for _, lhs in ipairs(spec.lhs) do
			for _, mode in ipairs(type(spec.mode) == "table" and spec.mode or { spec.mode }) do
				self:buf_map(buf, mode, lhs, function()
					if self:valid() and api.nvim_get_current_tabpage() == self.tab then
						spec.fn(self)
					else
						-- セッション外のタブで同じバッファを開いている場合は本来のキーとして振る舞う。
						api.nvim_feedkeys(vim.keycode(lhs), "n", false)
					end
				end, "Agent Review: " .. spec.desc)
			end
		end
	end
end

function Session:map_work_buffer(buf)
	if self.saved_maps[buf] then
		return
	end
	-- 何も割り当てなくても「設定済み」として記録し、毎回のsyncで再設定しない。
	self.saved_maps[buf] = {}
	self:apply_buffer_maps(buf, "work")
end

function Session:map_base_buffer(buf)
	self.saved_maps[buf] = self.saved_maps[buf] or {}
	self:apply_buffer_maps(buf, "base")
end

function Session:open(initial_rel)
	self.saved_diffopt = vim.o.diffopt
	-- inline:char等は0.12以降でのみ有効。未対応の項目は外して適用する。
	local items = {}
	for _, item in ipairs(config.options.diffopt) do
		if
			pcall(function()
				vim.o.diffopt = table.concat(vim.list_extend(vim.deepcopy(items), { item }), ",")
			end)
		then
			table.insert(items, item)
		end
	end
	vim.o.diffopt = table.concat(items, ",")

	self.origin_tab = api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	self.tab = api.nvim_get_current_tabpage()
	self.right_win = api.nvim_get_current_win()
	local empty_buf = api.nvim_get_current_buf()
	vim.cmd("leftabove vsplit")
	self.left_win = api.nvim_get_current_win()
	api.nvim_win_set_buf(self.left_win, self:placeholder("loading..."))
	api.nvim_set_current_win(self.right_win)

	self:attach_autocmds()
	self:show(initial_rel)
	local qf = config.options.quickfix
	if qf.auto then
		self:update_quickfix()
		if qf.open then
			self:open_quickfix_window()
		end
	end
	require("agent-review.claude").bring_terminal(self)

	if
		api.nvim_buf_is_valid(empty_buf)
		and api.nvim_buf_get_name(empty_buf) == ""
		and #vim.fn.win_findbuf(empty_buf) == 0
	then
		pcall(api.nvim_buf_delete, empty_buf, {})
	end
end

function Session:attach_autocmds()
	local group = self.augroup
	-- nested: 左窓にfiletypeを設定した時にFileType（treesitter・syntax）を発火させるため。
	api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
		group = group,
		nested = true,
		callback = function()
			local cur_buf = api.nvim_get_current_buf()
			if
				vim.bo[cur_buf].buftype == "quickfix"
				and self:valid()
				and api.nvim_get_current_tabpage() == self.tab
			then
				-- 一覧を見ながら]q/[qを押すことが多いので、quickfix窓でもレビューのキーを使えるようにする。
				self:map_work_buffer(cur_buf)
				return
			end
			if self:valid() and api.nvim_get_current_win() == self.left_win then
				if vim.b[api.nvim_win_get_buf(self.left_win)].agent_review_side ~= "base" and not self.syncing then
					-- 開いた側がカーソル位置を設定し終わってから移す。
					vim.schedule(function()
						self:redirect_from_left()
					end)
				end
				return
			end
			if self:valid() and api.nvim_get_current_win() == self.right_win then
				local buf = api.nvim_win_get_buf(self.right_win)
				if buf ~= self.synced_buf or self.current_rel == nil then
					self.synced_buf = buf
					self:sync()
				end
			end
		end,
	})
	for _, win in ipairs({ self.left_win, self.right_win }) do
		api.nvim_create_autocmd("WinClosed", {
			group = group,
			pattern = tostring(win),
			callback = function()
				vim.schedule(function()
					require("agent-review").close()
				end)
			end,
		})
	end
	api.nvim_create_autocmd("TabClosed", {
		group = group,
		callback = function()
			if not api.nvim_tabpage_is_valid(self.tab) then
				vim.schedule(function()
					require("agent-review").close()
				end)
			end
		end,
	})
	api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlight.setup })
	require("agent-review.resize").attach(self)
	self:watch()
end

---作業ツリーの変更を監視して自動でrefreshする。
function Session:watch()
	local opts = config.options.auto_refresh
	if not (opts and opts.enabled ~= false) then
		return
	end
	local timer = vim.uv.new_timer()
	self.refresh_timer = timer
	local function schedule_refresh()
		if timer:is_closing() then
			return
		end
		timer:stop()
		timer:start(
			opts.debounce or 200,
			0,
			vim.schedule_wrap(function()
				if self:valid() and require("agent-review")._session == self then
					require("agent-review").refresh()
				end
			end)
		)
	end
	local watcher = vim.uv.new_fs_event()
	-- recursiveはmacOS/Windowsのみ。Linuxでは直下しか監視できないので下のautocmdで補う。
	if watcher and watcher:start(self.root, { recursive = true }, function(err, filename)
		-- git自身の書き込み（refresh中のgit statusやClaudeへの送信用ファイル）で無限ループしないよう.gitは無視する。
		if err or (filename and (filename == ".git" or filename:sub(1, 5) == ".git/")) then
			return
		end
		schedule_refresh()
	end) then
		self.fs_watcher = watcher
	elseif watcher then
		watcher:close()
	end
	-- BufEnterはsync()自身が発火させるのでrefreshが止まらなくなる。ここには含めない。
	api.nvim_create_autocmd({ "FocusGained", "TermLeave" }, { group = self.augroup, callback = schedule_refresh })
end

function Session:unwatch()
	for _, handle in ipairs({ self.fs_watcher, self.refresh_timer }) do
		if handle and not handle:is_closing() then
			handle:close()
		end
	end
end

---レビュータブにあるレビューと無関係な窓（ヘルプ・別ファイル・エージェントのターミナル等）。
---タブを閉じると一緒に消えてしまうので、閉じた後に戻り先のタブで表示し直す。
---@param skip_buf? integer claudecode.nvimのターミナル。claudecode自身のAPIで戻すので除外する。
function Session:foreign_windows(skip_buf)
	local out = {}
	for _, win in ipairs(api.nvim_tabpage_list_wins(self.tab)) do
		local buf = api.nvim_win_get_buf(win)
		local info = vim.fn.getwininfo(win)[1]
		if
			win ~= self.left_win
			and win ~= self.right_win
			and buf ~= skip_buf
			and api.nvim_win_get_config(win).relative == ""
			and info.quickfix == 0
		then
			table.insert(out, {
				buf = buf,
				width = api.nvim_win_get_width(win),
				height = api.nvim_win_get_height(win),
				vertical = api.nvim_win_get_width(win) < vim.o.columns,
			})
		end
	end
	return out
end

local function restore_windows(list)
	for _, w in ipairs(list) do
		if api.nvim_buf_is_valid(w.buf) then
			-- win = -1 で現在のタブの端（botright相当）に分割し、フォーカスは動かさない。
			pcall(api.nvim_open_win, w.buf, false, {
				split = w.vertical and "right" or "below",
				win = -1,
				width = w.vertical and w.width or nil,
				height = (not w.vertical) and w.height or nil,
			})
		end
	end
end

function Session:close()
	if self.closed then
		return
	end
	self.closed = true
	self:unwatch()
	pcall(api.nvim_del_augroup_by_id, self.augroup)
	local claude = require("agent-review.claude")
	local claude_visible = claude.terminal_visible_in(self.tab)

	for buf, maps in pairs(self.saved_maps) do
		if api.nvim_buf_is_valid(buf) then
			for key, prev in pairs(maps) do
				local mode, lhs = key:sub(1, 1), key:sub(2)
				pcall(vim.keymap.del, mode, lhs, { buffer = buf })
				if prev then
					vim.fn.mapset(mode, false, prev)
				end
			end
		end
	end

	local foreign = {}
	if self.tab and api.nvim_tabpage_is_valid(self.tab) then
		if #api.nvim_list_tabpages() > 1 then
			foreign = self:foreign_windows(claude.terminal_buf())
			pcall(vim.cmd.tabclose, api.nvim_tabpage_get_number(self.tab))
			if self.origin_tab and api.nvim_tabpage_is_valid(self.origin_tab) then
				api.nvim_set_current_tabpage(self.origin_tab)
			end
		else
			if api.nvim_win_is_valid(self.right_win) then
				set_diff(self.right_win, false)
				vim.wo[self.right_win].winhighlight = ""
				vim.wo[self.right_win].winbar = ""
			end
			if api.nvim_win_is_valid(self.left_win) then
				pcall(api.nvim_win_close, self.left_win, true)
			end
		end
	end

	if self:qf_list_alive() and next(self.deleted_bufs) then
		-- 削除ファイル用のバッファを消すとエントリが壊れるので、パス指定に戻しておく。
		pcall(self.update_quickfix, self, self.qf_mode, { resolve_deleted = false })
	end

	local scratch = vim.list_extend(vim.tbl_values(self.base_bufs), vim.tbl_values(self.deleted_bufs))
	table.insert(scratch, self.placeholder_buf)
	for _, buf in ipairs(scratch) do
		if buf and api.nvim_buf_is_valid(buf) then
			pcall(api.nvim_buf_delete, buf, { force = true })
		end
	end

	if self.saved_diffopt then
		vim.o.diffopt = self.saved_diffopt
	end

	claude.restore_terminal(self, claude_visible)
	restore_windows(foreign)
end

return Session
