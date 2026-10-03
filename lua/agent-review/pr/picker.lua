local config = require("agent-review.config")
local gh = require("agent-review.pr.gh")
local list = require("agent-review.pr.list")
local repo_mod = require("agent-review.pr.repo")

local M = {}

local function notify(msg, level)
	vim.notify("[agent-review] " .. msg, level or vim.log.levels.INFO)
end

local REVIEW = {
	APPROVED = "✓ approved",
	CHANGES_REQUESTED = "✗ changes requested",
	REVIEW_REQUIRED = "● review required",
}

local CHECKS = {
	SUCCESS = "✓ CI",
	FAILURE = "✗ CI failed",
	ERROR = "✗ CI failed",
	PENDING = "… CI running",
	EXPECTED = "… CI running",
}

---GitHubのUTCの時刻（2026-10-03T10:00:00Z）をエポック秒にする。
local function parse_iso(iso)
	local y, mo, d, h, mi, s = (iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
	-- os.time はローカル時刻として解釈するので、UTCとの差を足して戻す。
	local now = os.time()
	return t + os.difftime(now, os.time(os.date("!*t", now)))
end

function M.ago(iso, now)
	local t = parse_iso(iso)
	if not t then
		return ""
	end
	local diff = math.max((now or os.time()) - t, 0)
	if diff < 60 then
		return "just now"
	elseif diff < 3600 then
		return ("%dm ago"):format(diff / 60)
	elseif diff < 86400 then
		return ("%dh ago"):format(diff / 3600)
	elseif diff < 30 * 86400 then
		return ("%dd ago"):format(diff / 86400)
	end
	return os.date("%Y-%m-%d", t)
end

---@param item AgentReviewPrItem
function M.format(item, now)
	local parts = { "#" .. item.number, item.title, "@" .. item.author }
	if item.state == "MERGED" or item.state == "CLOSED" then
		table.insert(parts, item.state:lower())
	end
	if item.draft then
		table.insert(parts, "draft")
	end
	table.insert(parts, REVIEW[item.review or ""])
	table.insert(parts, CHECKS[item.checks or ""])
	table.insert(parts, ("+%d -%d"):format(item.additions, item.deletions))
	table.insert(parts, ("%d file%s"):format(item.changed_files, item.changed_files == 1 and "" or "s"))
	table.insert(parts, M.ago(item.updated_at, now))
	return table.concat(
		vim.tbl_filter(function(p)
			return p ~= nil and p ~= ""
		end, parts),
		"  "
	)
end

---プレビューに出す説明（markdown）。
---@param item AgentReviewPrItem
function M.describe(item)
	local lines = {
		("# #%d %s"):format(item.number, item.title),
		"",
		("@%s wants to merge `%s` into `%s`"):format(item.author, item.head or "?", item.base or "?"),
		M.format(item),
		"",
	}
	vim.list_extend(lines, vim.split(item.body ~= "" and item.body or "_No description provided._", "\r?\n"))
	return lines
end

---選んだPRを開く。diffのレビューはフェーズ2で作るので、それまではブラウザで開く。
---@param repo AgentReviewRepo
---@param item AgentReviewPrItem
function M.select(repo, item)
	local target = repo.host == "github.com" and repo.nwo or repo.key
	gh.run({ "pr", "view", tostring(item.number), "--web", "--repo", target }, {}, function(err)
		if err then
			notify(err.message, vim.log.levels.ERROR)
		end
	end)
end

local function report(err)
	notify(err.message, err.kind == "auth" and vim.log.levels.WARN or vim.log.levels.ERROR)
end

local function use_telescope()
	return config.options.picker ~= "ui_select" and pcall(require, "telescope")
end

local function ui_select(repo, preset)
	local shown = false
	list.fetch(repo, preset, {}, function(err, items)
		if shown then
			return
		end
		if err then
			return report(err)
		end
		shown = true
		if #items == 0 then
			return notify("no pull requests")
		end
		vim.ui.select(items, {
			prompt = "Pull requests: " .. repo.nwo,
			format_item = function(i)
				return M.format(i)
			end,
		}, function(choice)
			if choice then
				M.select(repo, choice)
			end
		end)
	end)
end

local function telescope_pick(repo, preset)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local previewers = require("telescope.previewers")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local function finder(items)
		return finders.new_table({
			results = items,
			entry_maker = function(i)
				return {
					value = i,
					display = M.format(i),
					ordinal = ("#%d %s @%s %s"):format(i.number, i.title, i.author, i.head or ""),
				}
			end,
		})
	end

	local picker = pickers.new({}, {
		prompt_title = "Pull requests: " .. repo.nwo .. (preset and (" (" .. preset .. ")") or ""),
		finder = finder({}),
		sorter = conf.generic_sorter({}),
		previewer = previewers.new_buffer_previewer({
			title = "Description",
			define_preview = function(self, entry)
				vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, M.describe(entry.value))
				vim.bo[self.state.bufnr].filetype = "markdown"
			end,
		}),
		attach_mappings = function(prompt_bufnr)
			actions.select_default:replace(function()
				local entry = action_state.get_selected_entry()
				actions.close(prompt_bufnr)
				if entry then
					M.select(repo, entry.value)
				end
			end)
			return true
		end,
	})
	picker:find()
	-- 一覧はすぐ開き、キャッシュ→取り直した結果の順に中身を差し替える。
	list.fetch(repo, preset, {}, function(err, items)
		if err then
			return report(err)
		end
		if picker.prompt_bufnr and vim.api.nvim_buf_is_valid(picker.prompt_bufnr) then
			picker:refresh(finder(items), { reset_prompt = false })
		end
	end)
end

---@param preset? string
function M.pick(preset)
	local repo, err = repo_mod.detect()
	if not repo then
		return notify(err, vim.log.levels.ERROR)
	end
	if use_telescope() then
		return telescope_pick(repo, preset)
	end
	ui_select(repo, preset)
end

return M
