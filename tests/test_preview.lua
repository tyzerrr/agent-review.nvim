local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
	hooks = {
		pre_case = child.setup,
		post_once = child.stop,
	},
})

local function render(path)
	return child.lua(
		[[
		local path = ...
		local picker = require("agent-review.picker")
		local item = vim.tbl_filter(function(i) return i.path == path end, picker.items())[1]
		local buf = vim.api.nvim_create_buf(false, true)
		local first = require("agent-review.preview").render(buf, item)
		local ns = vim.api.nvim_get_namespaces()["agent-review-preview"]
		local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
		local added, removed = {}, {}
		for _, m in ipairs(marks) do
			if m[4].line_hl_group == "AgentReviewAdd" then
				table.insert(added, m[2] + 1)
			end
			for _, vl in ipairs(m[4].virt_lines or {}) do
				local text = ""
				for _, chunk in ipairs(vl) do
					text = text .. chunk[1]
				end
				table.insert(removed, { row = m[2] + 1, above = m[4].virt_lines_above, text = vim.trim(text) })
			end
		end
		return {
			lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
			added = added,
			removed = removed,
			first = first,
			ts = vim.treesitter.highlighter.active[buf] ~= nil,
			syntax_chunk = (function()
				for _, m in ipairs(marks) do
					for _, vl in ipairs(m[4].virt_lines or {}) do
						for _, chunk in ipairs(vl) do
							if type(chunk[2]) == "table" and #chunk[2] > 1 then
								return true
							end
						end
					end
				end
				return false
			end)(),
		}
	]],
		{ path }
	)
end

T["render() shows working content with language syntax and diff overlays"] = function()
	local root = H.make_repo({ ["a.lua"] = { "local a = 1", "local b = 2", "return a" } })
	H.write(root, "a.lua", { "local a = 1", "local c = 3", "local d = 4", "return a" })
	child.lua("vim.cmd.cd(...)", { root })
	local r = render("a.lua")
	eq(r.lines, { "local a = 1", "local c = 3", "local d = 4", "return a" })
	eq(r.added, { 2, 3 })
	eq(#r.removed, 1)
	eq(r.removed[1].text, "local b = 2")
	eq(r.removed[1].row, 2)
	eq(r.removed[1].above, true)
	eq(r.first, 2)
	-- lua の treesitter パーサは Neovim 同梱
	eq(r.ts, true)
	eq(r.syntax_chunk, true)
end

T["render() shows pure deletions below the preceding line"] = function()
	local root = H.make_repo({ ["a.lua"] = { "one", "two", "three" } })
	H.write(root, "a.lua", { "one", "three" })
	child.lua("vim.cmd.cd(...)", { root })
	local r = render("a.lua")
	eq(r.added, {})
	eq(r.removed[1].text, "two")
	eq(r.removed[1].row, 1)
	eq(r.removed[1].above, false)
end

T["render() handles deleted files as all-removed"] = function()
	local root = H.make_repo({ ["gone.lua"] = { "x", "y" }, ["keep.lua"] = { "k" } })
	vim.fn.delete(root .. "/gone.lua")
	child.lua("vim.cmd.cd(...)", { root })
	local r = render("gone.lua")
	eq(r.lines, { "" })
	eq(#r.removed, 2)
	eq(r.removed[1].above, true)
end

T["render() handles new files as all-added"] = function()
	local root = H.make_repo({ ["keep.lua"] = { "k" } })
	H.write(root, "new.lua", { "n1", "n2" })
	child.lua("vim.cmd.cd(...)", { root })
	local r = render("new.lua")
	eq(r.added, { 1, 2 })
	eq(r.removed, {})
end

return T
