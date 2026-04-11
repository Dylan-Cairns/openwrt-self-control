local helper = require("test_helper")
local lu = require("luaunit")
local service = require("quietwrt.service")

TestServiceIntegration = {}

function TestServiceIntegration:test_bootstraps_lists_from_existing_adguard_rules()
  local fixture = helper.make_context()
  helper.write_config(fixture.paths.config_path, {
    "||example.com^",
    "@@||allowed.com^",
  })

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local state, err = service.load_view_state(context)
  lu.assertNil(err)
  lu.assertTrue(state.bootstrapped)
  lu.assertEquals(state.always_hosts, { "example.com" })
  lu.assertEquals(state.workday_hosts, {})
  lu.assertEquals(state.active_rules, {
    "@@||allowed.com^",
    "||example.com^",
  })
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "example.com\n")
  fixture.cleanup()
end

function TestServiceIntegration:test_add_entry_moves_host_to_always_and_updates_config()
  local fixture = helper.make_context()
  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "")
  helper.write_file(fixture.paths.workday_list_path, "example.com\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local result = service.add_entry(context, "always", "example.com")
  lu.assertTrue(result.ok)
  lu.assertStrContains(result.message, "Moved example.com")
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "example.com\n")
  lu.assertEquals(helper.read_file(fixture.paths.workday_list_path), "")
  lu.assertStrContains(helper.read_file(fixture.paths.config_path), "||example.com^")
  fixture.cleanup()
end

function TestServiceIntegration:test_restart_failure_restores_previous_config()
  local attempts = 0
  local fixture = helper.make_context({
    execute = function(log, command)
      table.insert(log, command)
      if command == "restart-adguard" then
        attempts = attempts + 1
        if attempts == 1 then
          return 1
        end
      end
      return 0
    end,
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local original = helper.read_file(fixture.paths.config_path)
  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, err = service.apply_current_mode(context)
  lu.assertFalse(ok)
  lu.assertStrContains(err, "restart failed")
  lu.assertEquals(helper.read_file(fixture.paths.config_path), original)
  fixture.cleanup()
end

function TestServiceIntegration:test_install_writes_cron_block_and_enables_curfew_in_off_hours()
  local fixture = helper.make_context({
    now = function()
      return { hour = 19, min = 0 }
    end,
  })
  helper.write_config(fixture.paths.config_path, {
    "||example.com^",
  })

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.install(context)
  lu.assertTrue(ok)
  lu.assertEquals(result.mode.code, "internet_off")
  lu.assertStrContains(helper.read_file(fixture.paths.crontab_path), "30 16 * * * /usr/bin/quietwrtctl sync")

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "restart-cron")
  lu.assertStrContains(joined, "uci set firewall.quietwrt_curfew.enabled='1'")
  fixture.cleanup()
end
