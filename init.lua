maki.setup({
  always_yolo = true,
  always_thinking = "high",
  plugins = {
    edit = { edit_lines = true },
    task = { max_concurrent = 32 },
  },
})

local scroll = require("maki.scroll")

maki.keymap.set("n", "<C-e>", function()
  scroll(1)
end, { desc = "Scroll down one line" })

maki.keymap.set("n", "<C-y>", function()
  scroll(-1)
end, { desc = "Scroll up one line" })

-- require("semble")
-- require("jev").setup()
