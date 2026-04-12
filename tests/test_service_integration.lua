local helper = require("test_helper")
local lu = require("luaunit")
local service = require("quietwrt.service")

TestServiceIntegration = {}

function TestServiceIntegration:test_install_bootstraps_lists_and_marks_the_installation()
  local fixture = helper.make_context({
    now = function()
      return { hour = 19, min = 0 }
    end,
  })
  helper.write_config(fixture.paths.config_path, {
    "||example.com^",
    "@@||allowed.com^",
  })

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.install(context)
  lu.assertTrue(ok)
  lu.assertTrue(result.bootstrapped)
  lu.assertEquals(result.mode.code, "internet_off")
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "example.com\n")
  lu.assertEquals(helper.read_file(fixture.paths.workday_list_path), "")
  lu.assertEquals(helper.read_file(fixture.paths.passthrough_rules_path), "@@||allowed.com^\n")

  local crontab = helper.read_file(fixture.paths.crontab_path)
  lu.assertStrContains(crontab, "*/10 * * * * /usr/bin/quietwrtctl sync")
  lu.assertStrContains(crontab, "30 16 * * * /usr/bin/quietwrtctl sync")

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "uci set quietwrt.settings.schema_version='1'")
  lu.assertStrContains(joined, "enable-init-service")
  lu.assertStrContains(joined, "uci set firewall.quietwrt_curfew.enabled='1'")
  fixture.cleanup()
end

function TestServiceIntegration:test_install_fails_closed_when_adguard_protection_is_disabled()
  local fixture = helper.make_context()
  helper.write_config(fixture.paths.config_path, {}, false)

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, err = service.install(context)
  lu.assertFalse(ok)
  lu.assertStrContains(err, "protection is disabled")
  lu.assertNil(helper.read_file(fixture.paths.always_list_path))
  lu.assertNil(helper.read_file(fixture.paths.workday_list_path))
  lu.assertNil(helper.read_file(fixture.paths.passthrough_rules_path))
  lu.assertEquals(#fixture.commands, 0)
  fixture.cleanup()
end

function TestServiceIntegration:test_load_view_state_requires_a_managed_install()
  local fixture = helper.make_context()
  helper.write_config(fixture.paths.config_path, {})

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local state, err = service.load_view_state(context)
  lu.assertNil(state)
  lu.assertStrContains(err, "not installed")
  fixture.cleanup()
end

function TestServiceIntegration:test_add_entry_moves_host_to_always_and_updates_config()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "1",
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "1",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    },
  })

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

function TestServiceIntegration:test_partial_missing_list_state_fails_closed_without_rewriting_lists()
  local fixture = helper.make_context({
    now = function()
      return { hour = 17, min = 0 }
    end,
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "1",
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "1",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    },
  })

  helper.write_config(fixture.paths.config_path, {
    "||always.com^",
  })
  helper.write_file(fixture.paths.always_list_path, "always.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, err = service.apply_current_mode(context)
  lu.assertFalse(ok)
  lu.assertStrContains(err, "incomplete")
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "always.com\n")
  lu.assertEquals(helper.read_file(fixture.paths.workday_list_path), "work.com\n")
  lu.assertNil(helper.read_file(fixture.paths.passthrough_rules_path))
  fixture.cleanup()
end

function TestServiceIntegration:test_invalid_manual_host_line_is_rejected()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "1",
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "1",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    },
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "Example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, err = service.apply_current_mode(context)
  lu.assertFalse(ok)
  lu.assertStrContains(err, "always-blocked.txt")
  lu.assertStrContains(err, "line 1")
  fixture.cleanup()
end

function TestServiceIntegration:test_firewall_failure_restores_previous_state()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "1",
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "1",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    },
    execute = function(log, command)
      table.insert(log, command)
      if command == "restart-firewall" then
        return 1
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
  lu.assertStrContains(err, "Firewall update failed")
  lu.assertEquals(helper.read_file(fixture.paths.config_path), original)
  fixture.cleanup()
end

function TestServiceIntegration:test_install_rolls_back_bootstrapped_lists_schedule_and_boot_service_on_apply_failure()
  local fixture = helper.make_context({
    execute = function(log, command)
      table.insert(log, command)
      if command == "restart-firewall" then
        return 1
      end
      return 0
    end,
  })

  helper.write_config(fixture.paths.config_path, {})

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, err = service.install(context)
  lu.assertFalse(ok)
  lu.assertStrContains(err, "Firewall update failed")
  lu.assertNil(helper.read_file(fixture.paths.always_list_path))
  lu.assertNil(helper.read_file(fixture.paths.workday_list_path))
  lu.assertNil(helper.read_file(fixture.paths.passthrough_rules_path))
  lu.assertNil(helper.read_file(fixture.paths.crontab_path))

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "enable-init-service")
  lu.assertStrContains(joined, "disable-init-service")
  fixture.cleanup()
end

function TestServiceIntegration:test_apply_current_mode_fails_closed_when_adguard_protection_is_disabled()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "1",
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "1",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    },
  })

  helper.write_config(fixture.paths.config_path, {}, false)
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, err = service.apply_current_mode(context)
  lu.assertFalse(ok)
  lu.assertStrContains(err, "protection is disabled")
  fixture.cleanup()
end

function TestServiceIntegration:test_status_json_reports_flags_counts_and_hardening()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "1",
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "0",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
      ["uci -q get firewall.quietwrt_dns_int.name"] = "QuietWrt-Intercept-DNS",
      ["uci -q get firewall.quietwrt_dot_fwd.name"] = "QuietWrt-Deny-DoT",
      ["uci -q get firewall.quietwrt_curfew.name"] = "QuietWrt-Internet-Curfew",
    },
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, output = service.status(context, {
    json = true,
  })
  lu.assertTrue(ok)
  lu.assertStrContains(output, '"installed":true')
  lu.assertStrContains(output, '"always_enabled":true')
  lu.assertStrContains(output, '"workday_enabled":false')
  lu.assertStrContains(output, '"always_count":1')
  lu.assertStrContains(output, '"enforcement_ready":true')
  lu.assertStrContains(output, '"dns_intercept":true')
  fixture.cleanup()
end

function TestServiceIntegration:test_status_json_reports_disabled_protection_and_enforcement_not_ready()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "1",
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "1",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    },
  })

  helper.write_config(fixture.paths.config_path, {}, false)
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, output = service.status(context, {
    json = true,
  })
  lu.assertTrue(ok)
  lu.assertStrContains(output, '"protection_enabled":false')
  lu.assertStrContains(output, '"enforcement_ready":false')
  fixture.cleanup()
end

function TestServiceIntegration:test_set_toggle_updates_settings_and_reapplies()
  local capture_state = {
    ["uci -q get quietwrt.settings.schema_version"] = "1",
    ["uci -q get quietwrt.settings.always_enabled"] = "1",
    ["uci -q get quietwrt.settings.workday_enabled"] = "1",
    ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
  }

  local fixture = helper.make_context({
    capture = function(command)
      return capture_state[command] or ""
    end,
    execute = function(log, command)
      table.insert(log, command)

      local option, value = command:match("^uci set quietwrt%.settings%.([%w_]+)='([^']+)'$")
      if option and value then
        capture_state["uci -q get quietwrt.settings." .. option] = value
      end

      return 0
    end,
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.set_toggle(context, "workday", false)
  lu.assertTrue(ok)
  lu.assertEquals(result.settings.workday_enabled, false)

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "uci set quietwrt.settings.workday_enabled='0'")
  lu.assertStrContains(joined, "uci set quietwrt.settings.schema_version='1'")
  fixture.cleanup()
end

function TestServiceIntegration:test_restore_lists_updates_only_the_provided_backup_file()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.schema_version"] = "1",
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "1",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    },
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "old.example\n")
  helper.write_file(fixture.paths.workday_list_path, "work.example\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local restore_always_path = helper.join_path(fixture.root, "quietwrt-always-restore.txt")
  helper.write_file(restore_always_path, "new.example\n")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.restore_lists(context, {
    always_path = restore_always_path,
  })
  lu.assertTrue(ok)
  lu.assertEquals(result.mode.code, "always_and_workday")
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "new.example\n")
  lu.assertEquals(helper.read_file(fixture.paths.workday_list_path), "work.example\n")

  local config = helper.read_file(fixture.paths.config_path)
  lu.assertStrContains(config, "||new.example^")
  lu.assertStrContains(config, "||work.example^")
  fixture.cleanup()
end
