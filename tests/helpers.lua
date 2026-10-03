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

---GitHubに見立てたbareリポジトリ（origin）と、そこからcloneしたユーザーのリポジトリを作る。
---PR #number は refs/pull/<number>/head に置き、PRの分岐後に main も1コミット進める（merge-baseの確認用）。
---GIT_CONFIG_GLOBAL の insteadOf で https://github.com/o/r.git への通信を origin に向けるので、ネットワークに出ない。
---@return { origin: string, user: string, url: string, gitconfig: string, head: string, fork_point: string, main: string }
function H.github_fixture(number)
	number = number or 7
	local origin = vim.fn.resolve(vim.fn.tempname())
	vim.fn.mkdir(origin, "p")
	run(origin, { "git", "init", "-q", "--bare", "-b", "main" })

	local work = H.make_repo({
		["app.go"] = { "package app", "func A() int { return 1 }" },
		["util.go"] = { "package app", "func U() int { return 1 }" },
		["gone.go"] = { "package legacy", "", "// Deprecated helpers removed by the PR.", "func Old() string { return \"old\" }" },
	})
	run(work, { "git", "remote", "add", "origin", origin })
	run(work, { "git", "push", "-q", "origin", "main" })
	local fork_point = vim.trim(run(work, { "git", "rev-parse", "HEAD" }))

	run(work, { "git", "switch", "-q", "-c", "feature" })
	H.write(work, "app.go", { "package app", "func A() int { return 2 }" })
	H.write(work, "new.go", { "package app", "func N() {}" })
	vim.fn.delete(work .. "/gone.go")
	run(work, { "git", "add", "-A" })
	run(work, { "git", "commit", "-q", "-m", "feature" })
	local head = vim.trim(run(work, { "git", "rev-parse", "HEAD" }))
	run(work, { "git", "push", "-q", "origin", ("HEAD:refs/pull/%d/head"):format(number) })

	run(work, { "git", "switch", "-q", "main" })
	H.write(work, "util.go", { "package app", "func U() int { return 3 }" })
	run(work, { "git", "commit", "-q", "-am", "main moves on" })
	run(work, { "git", "push", "-q", "origin", "main" })
	local main = vim.trim(run(work, { "git", "rev-parse", "HEAD" }))

	local url = "https://github.com/o/r.git"
	local gitconfig = vim.fn.tempname()
	vim.fn.writefile({
		("[url %q]"):format(origin),
		"\tinsteadOf = " .. url,
		"[user]",
		"\temail = test@example.com",
		"\tname = test",
		"[protocol \"file\"]",
		"\tallow = always",
	}, gitconfig)

	local user = vim.fn.resolve(vim.fn.tempname())
	vim.system({ "git", "clone", "-q", origin, user }, { env = { GIT_CONFIG_GLOBAL = gitconfig } }):wait()
	run(user, { "git", "remote", "set-url", "origin", url })
	return { origin = origin, user = user, url = url, gitconfig = gitconfig, head = head, fork_point = fork_point, main = main, work = work }
end

---fixture の origin に、PRの新しいコミットをpushする（PRが更新された状況）。
function H.push_pr_update(fx, number, rel, lines)
	run(fx.work, { "git", "switch", "-q", "--detach", fx.head })
	H.write(fx.work, rel, lines)
	run(fx.work, { "git", "commit", "-q", "-am", "update" })
	local head = vim.trim(run(fx.work, { "git", "rev-parse", "HEAD" }))
	run(fx.work, { "git", "push", "-q", "-f", "origin", ("HEAD:refs/pull/%d/head"):format(number) })
	run(fx.work, { "git", "switch", "-q", "main" })
	return head
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
