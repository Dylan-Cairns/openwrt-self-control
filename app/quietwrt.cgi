#!/usr/bin/lua

local function add_package_path()
  local script_filename = os.getenv("SCRIPT_FILENAME") or (arg and arg[0]) or ""
  local script_dir = script_filename:match("^(.*)[/\\][^/\\]+$") or "."
  package.path = table.concat({
    script_dir .. "/quietwrt/?.lua",
    script_dir .. "/quietwrt/?/init.lua",
    "/usr/lib/lua/?.lua",
    "/usr/lib/lua/?/init.lua",
    package.path,
  }, ";")
end

add_package_path()
require("quietwrt.app").run_cgi()
