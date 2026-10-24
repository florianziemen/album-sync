std = "lua51"
max_line_length = 120
exclude_files = { ".rocks/", "src/flockr.lrdevplugin/json.lua" }

files["src/"] = { read_globals = { "import", "_PLUGIN", "LOC" } }
files["tests/"] = { std = "+busted" }
