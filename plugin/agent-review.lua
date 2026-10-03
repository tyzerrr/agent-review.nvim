if vim.g.loaded_agent_review then
	return
end
vim.g.loaded_agent_review = true

local function complete_rev(arglead)
	local res = vim.system(
		{ "git", "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/tags", "refs/remotes" },
		{ text = true }
	):wait()
	local revs = { "HEAD", "HEAD~1", "HEAD~2", "HEAD~3" }
	if res.code == 0 then
		vim.list_extend(revs, vim.split(vim.trim(res.stdout), "\n", { plain = true }))
	end
	return vim.tbl_filter(function(r)
		return r ~= "" and vim.startswith(r, arglead)
	end, revs)
end

local function cmd(name, fn, opts)
	vim.api.nvim_create_user_command(name, fn, opts or {})
end

cmd("AgentReview", function(o)
	require("agent-review").open(o.args ~= "" and o.args or nil)
end, { nargs = "?", complete = complete_rev, desc = "Review changes against a git revision" })
cmd("AgentReviewToggle", function(o)
	require("agent-review").toggle(o.args ~= "" and o.args or nil)
end, { nargs = "?", complete = complete_rev, desc = "Toggle the review session" })
cmd("AgentReviewClose", function()
	require("agent-review").close()
end, { desc = "Close the review session" })
cmd("AgentReviewFiles", function()
	require("agent-review").files()
end, { desc = "Pick a changed file" })
cmd("AgentReviewHunks", function()
	require("agent-review").hunks()
end, { desc = "Pick a changed hunk" })
cmd("AgentReviewQuickfix", function(o)
	require("agent-review").quickfix(o.args ~= "" and o.args or nil)
end, {
	nargs = "?",
	complete = function()
		return { "files", "hunks", "comments" }
	end,
	desc = "Send changed files, hunks or PR review comments to the quickfix list",
})
cmd("AgentReviewPR", function(o)
	require("agent-review").pr_list(o.args ~= "" and o.args or nil)
end, {
	nargs = "?",
	complete = function(arglead)
		return vim.tbl_filter(function(n)
			return vim.startswith(n, arglead)
		end, require("agent-review.pr.list").preset_names())
	end,
	desc = "List GitHub pull requests (a preset from pr.presets), or review PR <number>",
})
cmd("AgentReviewPRConversation", function()
	require("agent-review").pr_conversation()
end, { desc = "Show the pull request's description, reviews and comments" })
cmd("AgentReviewPRClean", function()
	require("agent-review.pr.open").clean()
end, { desc = "Remove checked-out pull requests that are not being reviewed" })
cmd("AgentReviewRefresh", function()
	require("agent-review").refresh()
end, { desc = "Reload changed files and diff" })

require("agent-review.keymaps").define_plugs()
