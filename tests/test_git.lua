local H = dofile("tests/helpers.lua")
local git = require("agent-review.git")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function by_path(files)
	local out = {}
	for _, f in ipairs(files) do
		out[f.path] = f
	end
	return out
end

T["root() resolves the toplevel from a nested dir"] = function()
	local root = H.make_repo({ ["a/b/c.txt"] = { "x" } })
	eq(git.root(root .. "/a/b"), root)
end

T["root() returns nil outside a repository"] = function()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	eq(git.root(dir), nil)
end

T["resolve_rev() returns the commit sha or nil"] = function()
	local root = H.make_repo({ ["a.txt"] = { "x" } })
	local sha = vim.trim(H.git(root, { "rev-parse", "HEAD" }))
	eq(git.resolve_rev(root, "HEAD"), sha)
	eq(git.resolve_rev(root, "no-such-ref"), nil)
end

T["changed_files() reports modified, added, deleted, renamed and untracked"] = function()
	local root = H.make_repo({
		["mod.txt"] = { "a" },
		["del.txt"] = { "gone" },
		["old_name.txt"] = { "same", "content", "here", "for", "rename" },
	})
	H.write(root, "mod.txt", { "b" })
	vim.fn.delete(root .. "/del.txt")
	H.git(root, { "mv", "old_name.txt", "new_name.txt" })
	H.write(root, "staged_new.txt", { "s" })
	H.git(root, { "add", "staged_new.txt" })
	H.write(root, "dir with space/untracked.txt", { "u" })

	local files = by_path(git.changed_files(root, "HEAD"))
	eq(files["mod.txt"].status, "M")
	eq(files["del.txt"].status, "D")
	eq(files["new_name.txt"].status, "R")
	eq(files["new_name.txt"].old_path, "old_name.txt")
	eq(files["staged_new.txt"].status, "A")
	eq(files["dir with space/untracked.txt"].status, "?")
	eq(files["old_name.txt"], nil)
end

T["changed_files() is sorted by path"] = function()
	local root = H.make_repo({ ["b.txt"] = { "1" }, ["a.txt"] = { "1" } })
	H.write(root, "b.txt", { "2" })
	H.write(root, "a.txt", { "2" })
	local paths = vim.tbl_map(function(f)
		return f.path
	end, git.changed_files(root, "HEAD"))
	eq(paths, { "a.txt", "b.txt" })
end

T["show() returns base content, or nil when absent at base"] = function()
	local root = H.make_repo({ ["a.txt"] = { "line1", "line2" }, ["empty.txt"] = {} })
	H.write(root, "a.txt", { "changed" })
	eq(git.show(root, "HEAD", "a.txt"), { "line1", "line2" })
	eq(git.show(root, "HEAD", "empty.txt"), {})
	eq(git.show(root, "HEAD", "nope.txt"), nil)
end

T["git_dir() returns an absolute path"] = function()
	local root = H.make_repo({})
	eq(git.git_dir(root), root .. "/.git")
end

return T
