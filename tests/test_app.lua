local app = require("quietwrt.app")
local helper = require("test_helper")
local lu = require("luaunit")

TestApp = {}

local function capture_cgi(env, options)
  local original_getenv = os.getenv
  local original_read = io.read
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

  io.read = function(length)
    return tostring(env.STDIN or ""):sub(1, length)
  end

  local ok, result = xpcall(function()
    app.run_cgi(options)
  end, debug.traceback)

  os.getenv = original_getenv
  io.read = original_read
  io.write = original_write

  if not ok then
    error(result)
  end

  return table.concat(chunks)
end

local function installed_capture_map()
  return {
    ["uci -q get quietwrt.settings.schema_version"] = "4",
    ["uci -q get quietwrt.settings.always_enabled"] = "1",
    ["uci -q get quietwrt.settings.workday_enabled"] = "1",
    ["uci -q get quietwrt.settings.after_work_enabled"] = "1",
    ["uci -q get quietwrt.settings.password_vault_enabled"] = "1",
    ["uci -q get quietwrt.settings.overnight_enabled"] = "0",
    ["uci -q get quietwrt.settings.saturday_blockout_enabled"] = "0",
    ["uci -q get quietwrt.settings.workday_start"] = "0400",
    ["uci -q get quietwrt.settings.workday_end"] = "1630",
    ["uci -q get quietwrt.settings.after_work_start"] = "1630",
    ["uci -q get quietwrt.settings.after_work_end"] = "1900",
    ["uci -q get quietwrt.settings.password_vault_start"] = "0945",
    ["uci -q get quietwrt.settings.password_vault_end"] = "0930",
    ["uci -q get quietwrt.settings.overnight_start"] = "1900",
    ["uci -q get quietwrt.settings.overnight_end"] = "0400",
  }
end

function TestApp:test_get_download_zip_returns_attachment()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "4",
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

function TestApp:test_post_import_zip_merges_uploaded_archive()
  local archive = require("quietwrt.archive")
  local fixture = helper.make_context({
    capture_map = installed_capture_map(),
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "current.example\n")
  helper.write_file(fixture.paths.workday_list_path, "")
  helper.write_file(fixture.paths.after_work_list_path, "")
  helper.write_file(fixture.paths.password_vault_list_path, "")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local zip = assert(archive.zip({
    {
      name = "always-blocked.txt",
      content = "current.example\nnew.example\n",
    },
    {
      name = "workday-blocked.txt",
      content = "",
    },
    {
      name = "after-work-blocked.txt",
      content = "",
    },
    {
      name = "password-vault-blocked.txt",
      content = "",
    },
  }))
  local boundary = "quietwrt-test-boundary"
  local body = table.concat({
    "--" .. boundary,
    'Content-Disposition: form-data; name="action"',
    "",
    "import_zip",
    "--" .. boundary,
    'Content-Disposition: form-data; name="blocklists_zip"; filename="quietwrt-blocklists.zip"',
    "Content-Type: application/zip",
    "",
    zip,
    "--" .. boundary .. "--",
    "",
  }, "\r\n")

  local output = capture_cgi({
    REQUEST_METHOD = "POST",
    CONTENT_TYPE = "multipart/form-data; boundary=" .. boundary,
    CONTENT_LENGTH = tostring(#body),
    SCRIPT_NAME = "/cgi-bin/quietwrt",
    STDIN = body,
  }, {
    env = fixture.env,
    paths = fixture.paths,
  })

  lu.assertStrContains(output, "Status: 303 See Other")
  lu.assertStrContains(output, "kind=success")
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "current.example\nnew.example\n")
  fixture.cleanup()
end
