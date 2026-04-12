package.path = table.concat({
  "tests/?.lua",
  package.path,
}, ";")

local helper = require("test_helper")

local lu = require("luaunit")

local function run_suite()
  helper.begin_suite()
  dofile("tests/test_rules.lua")
  dofile("tests/test_schedule.lua")
  dofile("tests/test_service_integration.lua")
  dofile("tests/test_view.lua")
  return lu.LuaUnit.run()
end

local ok, result = xpcall(run_suite, debug.traceback)
local cleanup_ok, cleanup_err = pcall(helper.end_suite)

if not cleanup_ok then
  io.stderr:write("Test cleanup failed: ", tostring(cleanup_err), "\n")
end

if not ok then
  io.stderr:write(result, "\n")
  os.exit(1)
end

if not cleanup_ok then
  os.exit(1)
end

os.exit(result)
