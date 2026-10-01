NVIM ?= nvim

.PHONY: test test-file deps

deps:
	@test -d deps/mini.nvim || git clone --depth 1 https://github.com/echasnovski/mini.nvim deps/mini.nvim
	@test -d deps/plenary.nvim || git clone --depth 1 https://github.com/nvim-lua/plenary.nvim deps/plenary.nvim
	@test -d deps/telescope.nvim || git clone --depth 1 https://github.com/nvim-telescope/telescope.nvim deps/telescope.nvim

test: deps
	$(NVIM) --headless --noplugin -u scripts/minimal_init.lua -l scripts/run_tests.lua

# make test-file FILE=tests/test_git.lua
test-file: deps
	TEST_FILE=$(FILE) $(NVIM) --headless --noplugin -u scripts/minimal_init.lua -l scripts/run_tests.lua
