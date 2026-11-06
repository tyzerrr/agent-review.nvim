local config = require("agent-review.config")
local git = require("agent-review.git")
local highlight = require("agent-review.highlight")

local api = vim.api

local M = {}

---@type AgentReviewSession|nil
M._session = nil

local function notify(msg, level)
	vim.notify("[agent-review] " .. msg, level or vim.log.levels.INFO)
end

function M.setup(opts)
	config.setup(opts)
	highlight.setup()
	require("agent-review.keymaps").apply_global(config.options.keymaps)
end

local function emit(event, s)
	api.nvim_exec_autocmds("User", {
		pattern = event,
		modeline = false,
		data = {
			root = s.root,
			base = s.base,
			base_sha = s.base_sha,
			mode = s.mode,
			tab = s.tab,
			left_win = s.left_win,
			right_win = s.right_win,
		},
	})
end

local function active()
	local s = M._session
	if s and s:valid() then
		return s
	end
	if s then
		M._session = nil
		s:close()
	end
	return nil
end

local function detect_root()
	local name = api.nvim_buf_get_name(0)
	if name ~= "" and vim.bo.buftype == "" then
		local root = git.root(vim.fs.dirname(vim.fn.fnamemodify(name, ":p")))
		if root then
			return root
		end
	end
	return git.root(vim.fn.getcwd())
end

---@class AgentReviewContext
---@field root string
---@field base string
---@field base_sha string
---@field mode "working"|"branch"|"rev"
---@field label string

---比較に必要な情報を解決する。セッションが無くてもピッカー等から使えるようにしている。
---@return AgentReviewContext|nil, string|nil err
function M.resolve(base, root)
	base = base or config.options.base
	root = root or detect_root()
	if not root then
		return nil, "not inside a git repository"
	end
	local sha = git.resolve_rev(root, base)
	if not sha then
		return nil, "unknown revision: " .. base
	end
	return { root = root, base = base, base_sha = sha, mode = base == "HEAD" and "working" or "rev", label = base }
end

---ブランチモードの比較元（分岐元ブランチとの merge-base）を解決する。
---@param ref? string 分岐元のブランチ。nil なら branch.base か自動検出
---@return AgentReviewContext|nil, string|nil err
function M.resolve_branch(ref, root)
	root = root or detect_root()
	if not root then
		return nil, "not inside a git repository"
	end
	local opts = config.options.branch or {}
	ref = ref or opts.base or git.default_branch(root, opts.remote)
	if not ref then
		return nil, "could not find the branch to compare with; set branch.base (e.g. \"origin/main\")"
	end
	if not git.resolve_rev(root, ref) then
		return nil, "unknown branch: " .. ref
	end
	local sha = git.merge_base(root, "HEAD", ref)
	if not sha then
		return nil, "no common ancestor with " .. ref
	end
	return { root = root, base = ref, base_sha = sha, mode = "branch", label = ref .. " (fork point)" }
end

local function new_session(ctx)
	local Session = require("agent-review.session")
	local s = Session.new(ctx.root, ctx.base, ctx.base_sha, { mode = ctx.mode, label = ctx.label })
	s:refresh_files()
	return s
end

local function discard(s)
	pcall(api.nvim_del_augroup_by_id, s.augroup)
end

---@param base? string 比較元のrev。省略時はconfig.base
---@param opts? { path?: string, mode?: "branch", branch?: string } path: 最初に表示するroot相対パス
function M.open(base, opts)
	opts = opts or {}
	local s = active()
	if s then
		local same = opts.mode == "branch" and (s.mode == "branch" and (opts.branch == nil or opts.branch == s.base))
			or (opts.mode == nil and (base == nil or base == s.base))
		if same then
			api.nvim_set_current_tabpage(s.tab)
			if opts.path then
				s:show(opts.path)
			end
			return
		end
		M.close()
	end

	local ctx, err
	if opts.mode == "branch" then
		ctx, err = M.resolve_branch(opts.branch)
	else
		ctx, err = M.resolve(base)
	end
	if not ctx then
		return notify(err, vim.log.levels.ERROR)
	end

	highlight.setup()
	s = new_session(ctx)
	if #s.review_files == 0 and ctx.mode == "working" then
		-- エージェントが全部commitした後でも、ブランチで何をしたかは見られるようにする。
		local bctx = M.resolve_branch(nil, ctx.root)
		if bctx and bctx.base_sha ~= ctx.base_sha then
			-- セッションは同じ名前のaugroupを使うので、先に捨ててから作る。
			discard(s)
			local bs = new_session(bctx)
			if #bs.review_files > 0 then
				notify("no uncommitted changes; showing the branch since " .. bctx.base)
				s, ctx = bs, bctx
			else
				discard(bs)
				return notify("no changes against " .. ctx.label .. " or " .. bctx.base)
			end
		end
	end
	if #s.review_files == 0 then
		discard(s)
		local hidden = s.hidden_tests > 0 and (" (%d test files hidden)"):format(s.hidden_tests) or ""
		return notify("no changes against " .. ctx.label .. hidden)
	end

	local initial = opts.path or s:rel_path(api.nvim_get_current_buf())
	if not (initial and (opts.path or s:file(initial))) then
		initial = s.review_files[1].path
	end
	M._session = s
	s:open(initial)
	emit("AgentReviewOpen", s)
end

---レビューを（必要なら開いて）指定ファイル・行へ移動する。ピッカーからの遷移先。
---@param rel string root相対パス
---@param lnum? integer
function M.open_at(rel, lnum)
	M.open(nil, { path = rel })
	local s = active()
	if not s then
		return
	end
	api.nvim_set_current_win(s.right_win)
	if lnum then
		local last = api.nvim_buf_line_count(api.nvim_win_get_buf(s.right_win))
		pcall(api.nvim_win_set_cursor, s.right_win, { math.min(math.max(lnum, 1), last), 0 })
		vim.cmd("normal! zz")
	end
end

function M.close()
	local s = M._session
	M._session = nil
	if s and not s.closed and s.pr then
		-- Viewed の付け外しは1つずつ送らず、閉じる時にまとめて送る。
		require("agent-review.pr.review").flush_viewed(s)
	end
	if s and not s.closed then
		s:close()
		emit("AgentReviewClose", s)
	end
end

function M.toggle(base)
	if active() then
		M.close()
	else
		M.open(base)
	end
end

---ブランチ全体（分岐元からの変更。commit済みも含む）をレビューする。
---@param ref? string 分岐元のブランチ。nil なら branch.base か自動検出
function M.open_branch(ref)
	M.open(nil, { mode = "branch", branch = ref })
end

local function with_session(fn)
	return function(...)
		local s = active()
		if not s then
			return notify("no active review session", vim.log.levels.WARN)
		end
		return fn(s, ...)
	end
end

M.next_file = with_session(function(s)
	s:step(1)
end)

M.prev_file = with_session(function(s)
	s:step(-1)
end)

---quickfixを1件ずつ移動し、端では反対側へ回り込む。:cnextは端でE553になるため:ccで位置を指定する。
---@param delta integer
function M.qf_step(delta)
	local info = vim.fn.getqflist({ idx = 0, size = 0 })
	if info.size == 0 then
		return notify("quickfix list is empty", vim.log.levels.WARN)
	end
	local s = active()
	if s and api.nvim_get_current_tabpage() == s.tab then
		-- quickfix窓からの:ccは直前の窓に開くが、それがnofile（削除ファイル）だと新しい窓を分割してしまう。
		api.nvim_set_current_win(s.right_win)
	end
	vim.cmd.cc((info.idx - 1 + delta * vim.v.count1) % info.size + 1)
end

function M.qf_next()
	M.qf_step(1)
end

function M.qf_prev()
	M.qf_step(-1)
end

---レビューのquickfixでカーソル行の項目を右窓に開く。
---@return false|nil 対象外（別のリスト・locationリスト）ならfalseを返し、本来のキーに任せる
function M.qf_open()
	local s = active()
	local info = vim.fn.getwininfo(api.nvim_get_current_win())[1]
	if not (s and info.quickfix == 1 and info.loclist == 0 and vim.fn.getqflist({ id = 0 }).id == s.qf_id) then
		return false
	end
	local idx = vim.fn.line(".")
	-- 直前の窓がnofile（削除ファイル）だと:ccが窓を分割してしまうため、右窓で開く。
	api.nvim_set_current_win(s.right_win)
	vim.cmd.cc(idx)
end

---レビュー済みの印を切り替える。quickfix窓ならカーソル行のファイル、diffの窓なら表示中のファイル。
---@return false|nil 別のquickfixリストの上ならfalseを返し、本来のキーに任せる
function M.toggle_viewed()
	local s = active()
	if not s then
		return notify("no active review session", vim.log.levels.WARN)
	end
	local info = vim.fn.getwininfo(api.nvim_get_current_win())[1]
	local rel
	if s.tree_win and api.nvim_get_current_win() == s.tree_win then
		local tree_view = require("agent-review.tree_view")
		local paths = tree_view.paths_at_cursor(s)
		if #paths == 0 then
			return
		end
		-- フォルダなら中のファイルをまとめて付ける。全部付いていれば外す。
		local all = vim.iter(paths):all(function(p)
			return s:is_viewed(p)
		end)
		for _, p in ipairs(paths) do
			if s:is_viewed(p) == all then
				s:set_viewed(p, not all)
				if s.pr then
					require("agent-review.pr.review").queue_viewed(s, p, not all)
				end
			end
		end
		s:viewed_changed()
		return
	elseif info.quickfix == 1 then
		if info.loclist == 1 or vim.fn.getqflist({ id = 0 }).id ~= s.qf_id then
			return false
		end
		local item = vim.fn.getqflist()[vim.fn.line(".")]
		rel = item and s:rel_path(item.bufnr)
	else
		rel = s.current_rel
	end
	if not (rel and s:file(rel)) then
		return notify("not a changed file", vim.log.levels.WARN)
	end
	s:toggle_viewed(rel)
	if s.pr then
		require("agent-review.pr.review").queue_viewed(s, rel, s:is_viewed(rel))
	end
end

local function with_pr(fn)
	return with_session(function(s, ...)
		if not s.pr then
			return notify("not reviewing a pull request (:AgentReviewPR)", vim.log.levels.WARN)
		end
		if not s.pr.threads then
			return notify("comments are still loading")
		end
		return fn(s, ...)
	end)
end

---カーソル行のレビューコメントのスレッドを浮動窓で開く。
M.pr_thread = with_pr(function(s)
	local win = api.nvim_get_current_win()
	if win ~= s.left_win and win ~= s.right_win then
		win = s.right_win
	end
	local found = require("agent-review.pr.threads").at_cursor(s, win)
	if #found == 0 then
		return notify("no comments on this line")
	end
	require("agent-review.pr.threads").open_float(found, s)
end)

---カーソル行（ビジュアル選択なら範囲）にレビューコメントの下書きを書く。
M.pr_comment = with_pr(function(s)
	local win = api.nvim_get_current_win()
	if win ~= s.left_win and win ~= s.right_win then
		return notify("move to the diff windows to comment", vim.log.levels.WARN)
	end
	local l1, l2 = vim.fn.line("."), vim.fn.line(".")
	if vim.fn.mode():match("^[vV\22]") then
		l1 = vim.fn.line("v")
		api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
	end
	require("agent-review.pr.review").comment(s, win, l1, l2)
end)

---下書き（コメント・返信・解決）をまとめて送る。
---@param event? "approve"|"request_changes"|"comment"
M.pr_submit = with_pr(function(s, event)
	require("agent-review.pr.review").submit(s, event)
end)

---PRの説明・レビュー・コメントを時系列で開く。
M.pr_conversation = with_pr(function(s)
	require("agent-review.pr.threads").open_conversation(s)
end)

---GitHubのPR一覧を開く。番号（"123" / "#123"）ならそのPRを直接レビューする。
---@param arg? string pr.presets の名前かPR番号。nil なら pr.lists
function M.pr_list(arg)
	local number = arg and tonumber(arg:match("^#?(%d+)$"))
	if number then
		return require("agent-review.pr.open").open(number)
	end
	require("agent-review.pr.picker").pick(arg)
end

function M.files()
	require("agent-review.picker").pick()
end

function M.hunks()
	require("agent-review.picker").pick_hunks()
end

---@param mode? "files"|"hunks"
---@param mode? "files"|"hunks"|"comments"
M.quickfix = with_session(function(s, mode)
	if mode == "comments" and not s.pr then
		return notify("comments are available when reviewing a pull request (:AgentReviewPR)", vim.log.levels.WARN)
	end
	s:refresh_files()
	s:update_quickfix(mode)
	s:open_quickfix_window()
end)

---@param rel string root相対パス
M.show_file = with_session(function(s, rel)
	s:show(rel)
end)

local function refresh_session(s)
	if not s:valid() then
		return
	end
	-- LSPジャンプ等で一覧外のファイルを見ている時は動かさない。一覧から消えた時だけ移る。
	local was_listed = s:in_review(s.current_rel)
	local old_idx = s.current_rel and s.review_index[s.current_rel]
	local was_empty = s:showing_empty()
	s:follow_base()
	s:refresh_files()
	if s.qf_id then
		s:update_quickfix()
	end
	-- 一覧が同じでも行数は変わるので、ツリーは毎回描き直す。
	require("agent-review.tree_view").render(s)
	vim.cmd("checktime")
	local dropped = was_listed and not s:in_review(s.current_rel)
	if #s.review_files == 0 then
		-- 見ていたファイルがcommitされて何も残らない時は、古い内容を見せ続けないよう左右とも空にする。
		if dropped then
			s:show_empty()
		else
			s:sync()
		end
	elseif dropped or was_empty then
		s:show_qf_selection(old_idx)
	else
		s:sync()
	end
	s:wipe_stale_buffers()
	if vim.wo[s.right_win].diff then
		vim.cmd("diffupdate")
	end
	-- 全部commitした時に一度だけ知らせる（自動refreshのたびに出さない）。
	local empty = #s.review_files == 0
	if empty and not s.notified_empty then
		notify("no changes against " .. s.label)
	end
	s.notified_empty = empty
end

---未commitの変更だけ ⇔ ブランチ全体 を切り替える。
M.toggle_mode = with_session(function(s)
	if s.pr then
		return notify("pull requests are always compared with their base", vim.log.levels.WARN)
	end
	local ctx, err
	if s.mode == "branch" then
		ctx, err = M.resolve("HEAD", s.root)
	else
		ctx, err = M.resolve_branch(nil, s.root)
	end
	if not ctx then
		return notify(err, vim.log.levels.ERROR)
	end
	s:set_mode(ctx)
	refresh_session(s)
	if #s.review_files > 0 and not s:in_review(s.current_rel) then
		-- 新しいモードで変更の無いファイルを見続けても仕方ないので、先頭のファイルへ移る。
		s:show(s.review_files[1].path)
	end
end)

---ツリーのカーソル行を開く（フォルダなら畳む／開く）。
M.tree_open = with_session(function(s)
	require("agent-review.tree_view").activate(s)
end)

---ツリーへ移る（閉じていれば開く）。ツリーにいる時はdiffへ戻る。
M.tree_focus = with_session(function(s)
	local tree_view = require("agent-review.tree_view")
	if tree_view.is_open(s) and api.nvim_get_current_win() == s.tree_win then
		api.nvim_set_current_win(s.right_win)
		return
	end
	if not tree_view.is_open(s) then
		tree_view.open(s)
		require("agent-review.resize").equalize(s)
	end
	api.nvim_set_current_win(s.tree_win)
end)

M.refresh = with_session(function(s)
	refresh_session(s)
	-- PRは作業ツリーを監視しないので、refreshの時にだけ新しいpushを確かめる（ETagで304なら無料）。
	if s.pr then
		require("agent-review.pr.open").update(s, function(changed)
			if changed then
				refresh_session(s)
			end
		end)
	end
end)

---取ってきたPRのworktreeでレビューを開く。
---@param repo AgentReviewRepo
---@param meta AgentReviewPr
---@param checkout AgentReviewPrCheckout
function M.open_pr_session(repo, meta, checkout)
	if active() then
		M.close()
	end
	highlight.setup()
	local Session = require("agent-review.session")
	-- バッファ名は実パスになるので、root も実パスにしないと作業ツリー内のファイルと判定できない。
	local s = Session.new(vim.fn.resolve(checkout.root), checkout.base, checkout.base, {
		label = ("PR #%d"):format(meta.number),
		follow_base = false,
		watch = false,
	})
	s.pr = { repo = repo, meta = meta, head = checkout.head }
	local cached = require("agent-review.pr.comments").cached(repo, meta.number)
	if cached then
		s.pr.threads, s.pr.conversation, s.pr.pr_id = cached.threads, cached.conversation, cached.pr_id
	end
	s:refresh_files()
	if #s.review_files == 0 then
		pcall(api.nvim_del_augroup_by_id, s.augroup)
		return notify(("PR #%d has no changes to review"):format(meta.number))
	end
	M._session = s
	s:open(s.review_files[1].path)
	emit("AgentReviewOpen", s)
	require("agent-review.pr.open").load_comments(s)
end

return M
