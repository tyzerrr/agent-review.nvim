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

H.FAKE_GH = vim.fn.getcwd() .. "/tests/fixtures/gh"

---偽ghの応答規則を書いたディレクトリを作る。FAKE_GH_DIR に渡して使う。
---@param rules table[] tests/fixtures/gh の規則
function H.fake_gh(rules)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	vim.fn.writefile({ vim.json.encode(rules) }, dir .. "/responses.json")
	return dir
end

---偽ghが受けた呼び出しの一覧（{ args, stdin, if_none_match }）。
function H.gh_calls(dir)
	local path = dir .. "/calls.jsonl"
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	return vim.tbl_map(vim.json.decode, vim.fn.readfile(path))
end

return H
