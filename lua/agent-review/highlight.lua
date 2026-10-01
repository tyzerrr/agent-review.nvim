local config = require("agent-review.config")

local M = {}

local GREEN = 0x2ea043
local RED = 0xf85149

local function blend(fg, bg, alpha)
	local function ch(c, shift)
		return bit.band(bit.rshift(c, shift), 0xff)
	end
	local out = 0
	for _, shift in ipairs({ 16, 8, 0 }) do
		local v = math.floor(ch(fg, shift) * alpha + ch(bg, shift) * (1 - alpha) + 0.5)
		out = out + bit.lshift(v, shift)
	end
	return out
end

local function normal_bg()
	local bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
	if bg then
		return bg
	end
	return vim.o.background == "light" and 0xffffff or 0x1e1e1e
end

function M.setup()
	local bg = normal_bg()
	local fg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).fg
		or (vim.o.background == "light" and 0x000000 or 0xd4d4d4)
	-- 行全体は淡く、行内の変更部分は濃くしてVSCodeと同じ2段階の強弱をつける。
	local groups = {
		AgentReviewAdd = { bg = blend(GREEN, bg, 0.15) },
		AgentReviewAddText = { bg = blend(GREEN, bg, 0.40) },
		AgentReviewDelete = { bg = blend(RED, bg, 0.15) },
		AgentReviewDeleteText = { bg = blend(RED, bg, 0.40) },
		AgentReviewFiller = { fg = blend(fg, bg, 0.25) },
		AgentReviewWinbarBase = { fg = RED, bold = true },
		AgentReviewWinbarWork = { fg = GREEN, bold = true },
	}
	for name, spec in pairs(groups) do
		vim.api.nvim_set_hl(0, name, config.options.highlights[name] or spec)
	end
end

-- Vimのdiffは「相手側に無い行」をどちらの窓でもDiffAddで塗る。
-- base側ではそれは削除行なので、窓ごとに赤/緑へ割り当て直す。
local WINHL = {
	base = {
		DiffAdd = "AgentReviewDelete",
		DiffChange = "AgentReviewDelete",
		DiffText = "AgentReviewDeleteText",
		DiffTextAdd = "AgentReviewDeleteText",
		DiffDelete = "AgentReviewFiller",
	},
	work = {
		DiffAdd = "AgentReviewAdd",
		DiffChange = "AgentReviewAdd",
		DiffText = "AgentReviewAddText",
		DiffTextAdd = "AgentReviewAddText",
		DiffDelete = "AgentReviewFiller",
	},
}

---@param side "base"|"work"
function M.apply(win, side)
	local parts = {}
	for from, to in pairs(WINHL[side]) do
		table.insert(parts, from .. ":" .. to)
	end
	table.sort(parts)
	vim.wo[win].winhighlight = table.concat(parts, ",")
	local fill = vim.wo[win].fillchars
	fill = fill:gsub("diff:[^,]*,?", ""):gsub(",$", "")
	vim.wo[win].fillchars = (fill == "" and "" or fill .. ",") .. "diff:" .. config.options.fillchar
end

return M
