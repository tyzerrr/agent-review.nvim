return require("telescope").register_extension({
	exports = {
		agent_review = function(opts)
			require("agent-review.telescope").files(opts)
		end,
		files = function(opts)
			require("agent-review.telescope").files(opts)
		end,
		hunks = function(opts)
			require("agent-review.telescope").hunks(opts)
		end,
	},
})
