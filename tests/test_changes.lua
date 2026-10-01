local H = dofile("tests/helpers.lua")
local git = require("agent-review.git")
local changes = require("agent-review.changes")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function setup()
	local root = H.make_repo({
		["mod.txt"] = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" },
		["del.txt"] = { "a", "b" },
		["old.txt"] = { "r1", "r2", "r3", "r4", "r5", "r6" },
	})
	-- 3行目を変更、8行目の後に2行追加
	H.write(root, "mod.txt", { "1", "2", "THREE", "4", "5", "6", "7", "8", "8a", "8b", "9", "10" })
	vim.fn.delete(root .. "/del.txt")
	H.git(root, { "mv", "old.txt", "new.txt" })
	H.write(root, "new.txt", { "r1", "r2", "r3", "r4", "r5", "r6", "r7" })
	H.write(root, "untracked.txt", { "u1", "u2", "u3" })
	local sha = git.resolve_rev(root, "HEAD")
	local by = {}
	for _, c in ipairs(changes.collect(root, sha, git.changed_files(root, sha))) do
		by[c.file.path] = c
	end
	return root, sha, by
end

T["collect() counts added/removed lines and finds the first hunk"] = function()
	local _, _, by = setup()
	local mod = by["mod.txt"]
	eq(mod.added, 3)
	eq(mod.removed, 1)
	eq(mod.lnum, 3)
	eq(#mod.hunks, 2)
	eq(mod.hunks[2].work_start, 9)
	eq(mod.hunks[2].work_count, 2)
end

T["collect() handles deleted, untracked and renamed files"] = function()
	local _, _, by = setup()
	eq({ by["del.txt"].added, by["del.txt"].removed, by["del.txt"].lnum }, { 0, 2, 1 })
	eq({ by["untracked.txt"].added, by["untracked.txt"].removed, by["untracked.txt"].lnum }, { 3, 0, 1 })
	-- リネーム元と比較するので、追加の1行だけが差分になる
	eq({ by["new.txt"].added, by["new.txt"].removed, by["new.txt"].lnum }, { 1, 0, 7 })
end

T["unified() returns a git-style diff with headers"] = function()
	local root, sha, by = setup()
	local lines = changes.unified(root, sha, by["new.txt"].file)
	eq(lines[1], "--- a/old.txt")
	eq(lines[2], "+++ b/new.txt")
	eq(lines[3]:match("^@@") ~= nil, true)
	eq(lines[#lines], "+r7")
end

T["qf_items() builds file entries and hunk entries"] = function()
	local root, sha, by = setup()
	local list = changes.collect(root, sha, git.changed_files(root, sha))
	local files = changes.qf_items(root, list, "files")
	eq(#files, 4)
	eq(files[1].filename, root .. "/del.txt")
	eq(files[1].text:match("deleted") ~= nil, true)
	local hunks = changes.qf_items(root, list, "hunks")
	local mod_hunks = vim.tbl_filter(function(i)
		return i.filename == root .. "/mod.txt"
	end, hunks)
	eq(#mod_hunks, 2)
	eq(mod_hunks[1].lnum, 3)
	eq(mod_hunks[1].text:match("THREE") ~= nil, true)
	eq(mod_hunks[2].lnum, 9)
end

return T
