-- 収集時のエラーでheadless nvimが終了せずにハングするのを防ぐ。
local file = vim.env.TEST_FILE
local ok, err = pcall(function()
	if file and file ~= "" then
		MiniTest.run_file(file)
	else
		MiniTest.run()
	end
end)
if not ok then
	io.stderr:write(tostring(err) .. "\n")
	vim.cmd("cquit 1")
end
