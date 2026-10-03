local changes = require("agent-review.changes")
local config = require("agent-review.config")
local git = require("agent-review.git")

local M = {}

local function context()
	local ar = require("agent-review")
	local s = ar._session
	if s and s:valid() then
		s:refresh_files()
		return { root = s.root, base = s.base, base_sha = s.base_sha }, s.review_files
	end
	local ctx, err = ar.resolve()
	if not ctx then
		vim.notify("[agent-review] " .. err, vim.log.levels.ERROR)
		return nil
	end
	return ctx, (require("agent-review.testfiles").filter(git.changed_files(ctx.root, ctx.base_sha)))
end

---@class AgentReviewPickerItem
---@field path string
---@field abs string
---@field lnum integer
---@field display string
---@field change AgentReviewChange
---@field root string
---@field base_sha string
---@field hunk_index? integer

---@return AgentReviewPickerItem[]
function M.items()
	local ctx, files = context()
	if not ctx then
		return {}
	end
	return vim.tbl_map(function(c)
		return {
			path = c.file.path,
			abs = ctx.root .. "/" .. c.file.path,
			lnum = c.lnum,
			display = ("%-9s %s  +%d -%d"):format(
				changes.STATUS_LABELS[c.file.status] or c.file.status,
				c.file.old_path and (c.file.old_path .. " -> " .. c.file.path) or c.file.path,
				c.added,
				c.removed
			),
			change = c,
			root = ctx.root,
			base_sha = ctx.base_sha,
		}
	end, changes.collect(ctx.root, ctx.base_sha, files))
end

---@return AgentReviewPickerItem[]
function M.hunk_items()
	local out = {}
	for _, item in ipairs(M.items()) do
		local c = item.change
		for i, h in ipairs(c.hunks) do
			local text = h.work_count > 0 and (c.work[h.work_start] or "")
				or ("(removed) " .. (c.base[h.base_start] or ""))
			table.insert(
				out,
				vim.tbl_extend("force", item, {
					lnum = math.max(h.work_start, 1),
					hunk_index = i,
					display = ("%s:%d  -%d +%d  %s"):format(
						item.path,
						math.max(h.work_start, 1),
						h.base_count,
						h.work_count,
						vim.trim(text)
					),
				})
			)
		end
	end
	return out
end

---@param item AgentReviewPickerItem
function M.select(item)
	if item then
		require("agent-review").open_at(item.path, item.lnum)
	end
end

local function use_telescope()
	local choice = config.options.picker
	if choice == "ui_select" then
		return false
	end
	local ok = pcall(require, "telescope")
	return ok
end

local function ui_select(items, prompt)
	if #items == 0 then
		return vim.notify("[agent-review] no changes", vim.log.levels.INFO)
	end
	vim.ui.select(items, {
		prompt = prompt,
		format_item = function(i)
			return i.display
		end,
	}, M.select)
end

function M.pick()
	if use_telescope() then
		return require("agent-review.telescope").files()
	end
	ui_select(M.items(), "Agent Review: changed files")
end

function M.pick_hunks()
	if use_telescope() then
		return require("agent-review.telescope").hunks()
	end
	ui_select(M.hunk_items(), "Agent Review: changed hunks")
end

return M
