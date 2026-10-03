local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			require("agent-review.config").setup({})
		end,
	},
})

local function is_test(path)
	return require("agent-review.testfiles").is_test(path)
end

local function expect_all(paths, expected)
	for _, p in ipairs(paths) do
		eq({ p, is_test(p) }, { p, expected })
	end
end

T["is_test()"] = MiniTest.new_set()

T["is_test()"]["Go"] = function()
	expect_all({ "server/user_test.go", "user_test.go", "pkg/testdata/input.json" }, true)
	expect_all({ "server/user.go", "contest.go", "server/latest.go" }, false)
end

T["is_test()"]["JavaScript and TypeScript"] = function()
	expect_all({
		"src/user.test.ts",
		"src/user.spec.tsx",
		"src/user.test.js",
		"src/user.spec.jsx",
		"src/user.test.mjs",
		"src/user.spec.cts",
		"src/__tests__/user.ts",
		"web/__tests__/deep/util.js",
	}, true)
	expect_all({ "src/latest.ts", "src/user.ts", "src/contest.tsx", "src/spec.ts", "src/testing.js" }, false)
end

T["is_test()"]["Python"] = function()
	expect_all({ "test_user.py", "app/test_user.py", "app/user_test.py", "conftest.py", "app/tests/helpers.py" }, true)
	expect_all({ "app/attestation.py", "app/user.py", "app/latest_test_data.json" }, false)
end

T["is_test()"]["Lua"] = function()
	expect_all({ "spec/user_spec.lua", "lua/x/user_spec.lua", "tests/test_user.lua", "lua/x/user_test.lua", "spec/helpers.lua" }, true)
	expect_all({ "lua/agent-review/session.lua", "lua/x/latest.lua" }, false)
end

T["is_test()"]["Rust"] = function()
	expect_all({ "tests/integration.rs", "crates/core/tests/api.rs", "src/user_test.rs", "src/user/tests.rs" }, true)
	expect_all({ "src/main.rs", "src/attest.rs", "src/latest.rs" }, false)
end

T["is_test()"]["patterns can be replaced and extended"] = function()
	require("agent-review.config").setup({ tests = { patterns = { "%.check%.ts$" } } })
	eq(is_test("src/a.check.ts"), true)
	eq(is_test("src/a_test.go"), false)
	require("agent-review.config").setup({ tests = { extra_patterns = { "^/e2e/" } } })
	eq(is_test("e2e/login.ts"), true)
	eq(is_test("src/a_test.go"), true)
end

T["filter()"] = MiniTest.new_set()

T["filter()"]["keeps everything by default"] = function()
	local files = { { path = "a.go" }, { path = "a_test.go" } }
	eq(#require("agent-review.testfiles").filter(files), 2)
end

T["filter()"]["drops test files with tests.hide"] = function()
	require("agent-review.config").setup({ tests = { hide = true } })
	local kept = require("agent-review.testfiles").filter({ { path = "a.go" }, { path = "a_test.go" } })
	eq(vim.tbl_map(function(f)
		return f.path
	end, kept), { "a.go" })
end

return T
