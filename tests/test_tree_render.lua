local tree = require("agent-review.tree")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function change(path, status, added, removed)
	return { file = { path = path, status = status or "M" }, added = added or 1, removed = removed or 0 }
end

local function paths(files)
	return vim.tbl_map(function(f)
		return f.path
	end, files)
end

T["sort() puts folders before files at every level, like a file explorer"] = function()
	local files = vim.tbl_map(function(p)
		return { path = p, status = "M" }
	end, { "b.lua", "a.lua", "lua/z.lua", "lua/x/y.lua", "docs/readme.md", "a.lua.bak" })
	eq(paths(tree.sort(files)), { "docs/readme.md", "lua/x/y.lua", "lua/z.lua", "a.lua", "a.lua.bak", "b.lua" })
end

T["sort() ignores case, like VSCode's explorer"] = function()
	local files = vim.tbl_map(function(p)
		return { path = p, status = "M" }
	end, { "README.md", "main.go", "Makefile", "lib/x.go", "Docs/y.md" })
	eq(paths(tree.sort(files)), { "Docs/y.md", "lib/x.go", "main.go", "Makefile", "README.md" })
	local r = tree.build(vim.tbl_map(function(p)
		return change(p)
	end, { "README.md", "main.go" }))
	eq(r.lines, { "  main.go", "  README.md" })
end

T["build() renders folders and files with indentation"] = function()
	local r = tree.build({
		change("docs/readme.md"),
		change("lua/x/y.lua"),
		change("lua/z.lua"),
		change("a.lua"),
	})
	eq(r.lines, {
		"▾ docs/",
		"    readme.md",
		"▾ lua/",
		"  ▾ x/",
		"      y.lua",
		"    z.lua",
		"  a.lua",
	})
	eq(r.nodes[1], { kind = "dir", path = "docs", depth = 0, open = true })
	eq(r.nodes[2].kind, "file")
	eq(r.nodes[2].path, "docs/readme.md")
	eq(r.file_line["lua/x/y.lua"], 5)
	eq(r.file_line["a.lua"], 7)
end

T["build() merges folders that only contain one folder (compact folders)"] = function()
	local r = tree.build({ change("lua/agent-review/a.lua"), change("lua/agent-review/b.lua") })
	eq(r.lines, { "▾ lua/agent-review/", "    a.lua", "    b.lua" })
	eq(r.nodes[1].path, "lua/agent-review")
end

T["build() hides the files of collapsed folders"] = function()
	local r = tree.build({ change("lua/x/y.lua"), change("lua/z.lua"), change("a.lua") }, { collapsed = { ["lua/x"] = true } })
	eq(r.lines, { "▾ lua/", "  ▸ x/", "    z.lua", "  a.lua" })
	eq(r.nodes[2].open, false)
	eq(r.file_line["lua/x/y.lua"], nil)
end

T["build() shows status, line counts and viewed marks as virtual text"] = function()
	local r = tree.build({ change("a.lua", "M", 3, 1), change("new.lua", "?", 5, 0), change("old.lua", "D", 0, 2) }, {
		viewed = function(path)
			return path == "a.lua"
		end,
	})
	local function text(l)
		return table.concat(vim.tbl_map(function(chunk)
			return chunk[1]
		end, r.virt[l]))
	end
	eq(text(1), "✓ +3 -1 M")
	eq(text(2), "+5 U")
	eq(text(3), "-2 D")
end

T["build() colors file names by status"] = function()
	local r = tree.build({ change("a.lua", "M"), change("new.lua", "A"), change("old.lua", "D") })
	local by_line = {}
	for _, h in ipairs(r.highlights) do
		by_line[h.line] = by_line[h.line] or {}
		by_line[h.line][h.group] = true
	end
	eq(by_line[0]["AgentReviewTreeModified"], true)
	eq(by_line[1]["AgentReviewTreeAdded"], true)
	eq(by_line[2]["AgentReviewTreeDeleted"], true)
end

T["build() dims viewed files"] = function()
	local r = tree.build({ change("a.lua") }, {
		viewed = function()
			return true
		end,
	})
	eq(r.highlights[1].group, "AgentReviewTreeViewed")
end

T["summary() counts files, lines and viewed files"] = function()
	local list = { change("a.lua", "M", 3, 1), change("b.lua", "M", 2, 2) }
	eq(tree.summary(list, function(p)
		return p == "a.lua"
	end), "1/2 viewed  +5 -3")
	eq(tree.summary({ change("a.lua", "M", 1, 0) }), "1 file  +1 -0")
	eq(tree.summary({}), "no changes")
end

return T
