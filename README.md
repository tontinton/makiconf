My maki config.

```sh
git clone git@github.com:tontinton/makiconf.git ~/.config/maki
```

Enabled `env` & `run` permission in `plugin.toml` for `lua/semble.lua`.

`lua/jev.lua` uses TypeSafe's Jev (needs `TYPESAFE_API_KEY` or `TYPESAFE_AI`,
plus `net`) to filter tool output, pick what compaction keeps, and push the
agent on when it stops early. Enable with
`require("jev").setup()` in `init.lua`, see `/jev` for stats and toggles.
