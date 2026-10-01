local H = {}

local function run(cwd, cmd)
	local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
	if res.code ~= 0 then
		error(("command failed: %s\n%s"):format(table.concat(cmd, " "), res.stderr))
	end
	return res.stdout
end

function H.write(root, rel, lines)
	local path = root .. "/" .. rel
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(lines, path)
	return path
end

-- files: { [relpath] = lines }。コミット済みの状態を作り、その上で作業ツリーを変更させる。
function H.make_repo(files)
	local root = vim.fn.resolve(vim.fn.tempname())
	vim.fn.mkdir(root, "p")
	run(root, { "git", "init", "-q", "-b", "main" })
	run(root, { "git", "config", "user.email", "test@example.com" })
	run(root, { "git", "config", "user.name", "test" })
	run(root, { "git", "config", "commit.gpgsign", "false" })
	for rel, lines in pairs(files or {}) do
		H.write(root, rel, lines)
	end
	run(root, { "git", "add", "-A" })
	run(root, { "git", "commit", "-q", "--allow-empty", "-m", "init" })
	return root
end

function H.git(root, args)
	return run(root, vim.list_extend({ "git" }, args))
end

function H.new_child()
	local child = MiniTest.new_child_neovim()
	child.setup = function()
		child.restart({ "-u", "scripts/minimal_init.lua" })
		child.o.columns = 200
		child.o.lines = 50
	end
	return child
end

return H
