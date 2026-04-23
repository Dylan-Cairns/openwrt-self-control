local app = require("quietwrt.app")
local helper = require("test_helper")
local lu = require("luaunit")

TestApp = {}

local function capture_cgi(env, options)
  local original_getenv = os.getenv
  local original_write = io.write
  local chunks = {}

  os.getenv = function(name)
    return env[name]
  end

  io.write = function(...)
    for index = 1, select("#", ...) do
      table.insert(chunks, tostring(select(index, ...)))
    end
  end

  local ok, result = xpcall(function()
    app.run_cgi(options)
  end, debug.traceback)

  os.getenv = original_getenv
  io.write = original_write

  if not ok then
    error(result)
  end

  return table.concat(chunks)
end

function TestApp:test_get_download_zip_returns_attachment()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "3",
    },
  })

  helper.write_file(fixture.paths.always_list_path, "always.example\n")
  helper.write_file(fixture.paths.workday_list_path, "work.example\n")
  helper.write_file(fixture.paths.after_work_list_path, "after.example\n")
  helper.write_file(fixture.paths.password_vault_list_path, "vault.example\n")

  local output = capture_cgi({
    REQUEST_METHOD = "GET",
    QUERY_STRING = "download=zip",
    SCRIPT_NAME = "/cgi-bin/quietwrt",
  }, {
    env = fixture.env,
    paths = fixture.paths,
  })

  lu.assertStrContains(output, "Content-Type: application/zip")
  lu.assertStrContains(output, 'Content-Disposition: attachment; filename="quietwrt-blocklists.zip"')
  lu.assertStrContains(output, "always-blocked.txtalways.example\n")
  lu.assertStrContains(output, "password-vault-blocked.txtvault.example\n")
  fixture.cleanup()
end
