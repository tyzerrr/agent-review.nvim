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

-- main から feature を切り、両方を1コミットずつ進める。
local function forked_repo()
	local root = H.make_repo({ ["a.txt"] = { "1" } })
	local fork = vim.trim(H.git(root, { "rev-parse", "HEAD" }))
	H.git(root, { "switch", "-q", "-c", "feature" })
	H.write(root, "a.txt", { "feature" })
	H.git(root, { "commit", "-q", "-am", "feature" })
	H.git(root, { "switch", "-q", "main" })
	H.write(root, "b.txt", { "main" })
	H.git(root, { "add", "b.txt" })
	H.git(root, { "commit", "-q", "-m", "main moves on" })
	H.git(root, { "switch", "-q", "feature" })
	return root, fork
end

T["merge_base() returns the fork point, or nil for unknown refs"] = function()
	local root, fork = forked_repo()
	eq(git.merge_base(root, "HEAD", "main"), fork)
	eq(git.merge_base(root, "HEAD", "no-such-ref"), nil)
end

T["default_branch() prefers the remote's HEAD"] = function()
	local root = forked_repo()
	local origin = vim.fn.tempname()
	H.git(vim.fn.getcwd(), { "clone", "-q", "--bare", root, origin })
	H.git(root, { "remote", "add", "origin", origin })
	H.git(root, { "fetch", "-q", "origin" })
	H.git(root, { "remote", "set-head", "origin", "main" })
	eq(git.default_branch(root), "origin/main")
end

T["default_branch() falls back to origin/main, main and master"] = function()
	local root = forked_repo()
	eq(git.default_branch(root), "main")
	H.git(root, { "branch", "-q", "-m", "main", "master" })
	eq(git.default_branch(root), "master")
	H.git(root, { "branch", "-q", "-m", "master", "trunk" })
	eq(git.default_branch(root), nil)
end

return T
