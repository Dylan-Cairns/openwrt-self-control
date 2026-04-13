local helper = require("test_helper")
local lu = require("luaunit")
local service = require("quietwrt.service")

TestServiceIntegration = {}

local function installed_capture_map(overrides)
  local capture = {
    ["uci -q get quietwrt.settings.schema_version"] = "2",
    ["uci -q get quietwrt.settings.always_enabled"] = "1",
    ["uci -q get quietwrt.settings.workday_enabled"] = "1",
    ["uci -q get quietwrt.settings.after_work_enabled"] = "1",
    ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    ["uci -q get quietwrt.settings.workday_start"] = "0400",
    ["uci -q get quietwrt.settings.workday_end"] = "1630",
    ["uci -q get quietwrt.settings.after_work_start"] = "1630",
    ["uci -q get quietwrt.settings.after_work_end"] = "1900",
    ["uci -q get quietwrt.settings.overnight_start"] = "1900",
    ["uci -q get quietwrt.settings.overnight_end"] = "0400",
  }

  for key, value in pairs(overrides or {}) do
    capture[key] = value
  end

  return capture
end

local function installed_fixture(options)
  options = options or {}
  local capture_state = installed_capture_map(options.capture_map)

  local fixture = helper.make_context({
    now = options.now,
    capture = options.capture or function(command)
      return capture_state[command] or ""
    end,
    execute = options.execute or function(log, command)
      table.insert(log, command)

      local option, value = command:match("^uci set quietwrt%.settings%.([%w_]+)='([^']+)'$")
      if option and value then
        capture_state["uci -q get quietwrt.settings." .. option] = value
      end

      return 0
    end,
  })

  fixture.capture_state = capture_state
  return fixture
end

function TestServiceIntegration:test_install_bootstraps_lists_sets_default_schedule_and_marks_installation()
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
  lu.assertEquals(result.active_rule_count, 2)
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "example.com\n")
  lu.assertEquals(helper.read_file(fixture.paths.workday_list_path), "")
  lu.assertEquals(helper.read_file(fixture.paths.after_work_list_path), "")
  lu.assertEquals(helper.read_file(fixture.paths.passthrough_rules_path), "@@||allowed.com^\n")

  local crontab = helper.read_file(fixture.paths.crontab_path)
  lu.assertStrContains(crontab, "*/10 * * * * /usr/bin/quietwrtctl sync")
  lu.assertStrContains(crontab, "0 4 * * * /usr/bin/quietwrtctl sync")
  lu.assertStrContains(crontab, "30 16 * * * /usr/bin/quietwrtctl sync")
  lu.assertStrContains(crontab, "0 19 * * * /usr/bin/quietwrtctl sync")

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "uci set quietwrt.settings.schema_version='2'")
  lu.assertStrContains(joined, "uci set quietwrt.settings.after_work_enabled='1'")
  lu.assertStrContains(joined, "uci set quietwrt.settings.overnight_start='1900'")
  lu.assertStrContains(joined, "uci set firewall.quietwrt_curfew.enabled='0'")
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
  lu.assertNil(helper.read_file(fixture.paths.after_work_list_path))
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
  local fixture = installed_fixture()

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "")
  helper.write_file(fixture.paths.workday_list_path, "example.com\n")
  helper.write_file(fixture.paths.after_work_list_path, "")
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
  local fixture = installed_fixture({
    now = function()
      return { hour = 17, min = 0 }
    end,
  })

  helper.write_config(fixture.paths.config_path, {
    "||always.com^",
  })
  helper.write_file(fixture.paths.always_list_path, "always.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, err = service.apply_current_mode(context)
  lu.assertFalse(ok)
  lu.assertStrContains(err, "incomplete")
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "always.com\n")
  lu.assertEquals(helper.read_file(fixture.paths.workday_list_path), "work.com\n")
  lu.assertNil(helper.read_file(fixture.paths.after_work_list_path))
  fixture.cleanup()
end

function TestServiceIntegration:test_invalid_manual_host_line_is_rejected()
  local fixture = installed_fixture()

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "Example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "")
  helper.write_file(fixture.paths.after_work_list_path, "")
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
  local fixture = installed_fixture({
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
  helper.write_file(fixture.paths.after_work_list_path, "")
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
  lu.assertNil(helper.read_file(fixture.paths.after_work_list_path))
  lu.assertNil(helper.read_file(fixture.paths.passthrough_rules_path))
  lu.assertNil(helper.read_file(fixture.paths.crontab_path))

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "enable-init-service")
  lu.assertStrContains(joined, "disable-init-service")
  fixture.cleanup()
end

function TestServiceIntegration:test_install_writes_managed_firewall_sections_after_deleting_existing_ones()
  local fixture = helper.make_context()

  helper.write_config(fixture.paths.config_path, {
    "||example.com^",
  })

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.install(context)
  lu.assertTrue(ok)
  lu.assertEquals(result.active_rule_count, 1)

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "uci -q delete firewall.quietwrt_dns_int >/dev/null 2>&1 || true")
  lu.assertStrContains(joined, "uci set firewall.quietwrt_dns_int='redirect'")
  fixture.cleanup()
end

function TestServiceIntegration:test_apply_current_mode_fails_closed_when_adguard_protection_is_disabled()
  local fixture = installed_fixture()

  helper.write_config(fixture.paths.config_path, {}, false)
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "")
  helper.write_file(fixture.paths.after_work_list_path, "")
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

function TestServiceIntegration:test_status_json_reports_flags_counts_schedules_and_hardening()
  local fixture = installed_fixture({
    capture_map = {
      ["uci -q get quietwrt.settings.workday_enabled"] = "0",
      ["uci -q get firewall.quietwrt_dns_int.name"] = "QuietWrt-Intercept-DNS",
      ["uci -q get firewall.quietwrt_dot_fwd.name"] = "QuietWrt-Deny-DoT",
      ["uci -q get firewall.quietwrt_curfew.name"] = "QuietWrt-Internet-Curfew",
    },
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")
  helper.write_file(fixture.paths.after_work_list_path, "after.example\n")
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
  lu.assertStrContains(output, '"workday_enabled":false')
  lu.assertStrContains(output, '"after_work_enabled":true')
  lu.assertStrContains(output, '"after_work_count":1')
  lu.assertStrContains(output, '"display_start":"16:30"')
  lu.assertStrContains(output, '"dns_intercept":true')
  fixture.cleanup()
end

function TestServiceIntegration:test_status_json_reports_disabled_protection_and_enforcement_not_ready()
  local fixture = installed_fixture()

  helper.write_config(fixture.paths.config_path, {}, false)
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "")
  helper.write_file(fixture.paths.after_work_list_path, "")
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
  local fixture = installed_fixture()

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")
  helper.write_file(fixture.paths.after_work_list_path, "after.example\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.set_toggle(context, "after_work", false)
  lu.assertTrue(ok)
  lu.assertEquals(result.settings.after_work_enabled, false)

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "uci set quietwrt.settings.after_work_enabled='0'")
  lu.assertStrContains(joined, "uci set quietwrt.settings.schema_version='2'")
  fixture.cleanup()
end

function TestServiceIntegration:test_set_schedule_updates_cron_and_reapplies()
  local fixture = installed_fixture()

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")
  helper.write_file(fixture.paths.after_work_list_path, "after.example\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.set_schedule(context, "after_work", "1700", "2030")
  lu.assertTrue(ok)
  lu.assertEquals(result.settings.after_work_start, "1700")
  lu.assertEquals(result.settings.after_work_end, "2030")

  local crontab = helper.read_file(fixture.paths.crontab_path)
  lu.assertStrContains(crontab, "0 17 * * * /usr/bin/quietwrtctl sync")
  lu.assertStrContains(crontab, "30 20 * * * /usr/bin/quietwrtctl sync")
  fixture.cleanup()
end

function TestServiceIntegration:test_restore_lists_updates_only_the_provided_backup_file()
  local fixture = installed_fixture({
    now = function()
      return { hour = 17, min = 0 }
    end,
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "old.example\n")
  helper.write_file(fixture.paths.workday_list_path, "work.example\n")
  helper.write_file(fixture.paths.after_work_list_path, "after.example\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local restore_after_work_path = helper.join_path(fixture.root, "quietwrt-after-work-restore.txt")
  helper.write_file(restore_after_work_path, "new-after.example\n")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.restore_lists(context, {
    after_work_path = restore_after_work_path,
  })
  lu.assertTrue(ok)
  lu.assertEquals(result.active_rule_count > 0, true)
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "old.example\n")
  lu.assertEquals(helper.read_file(fixture.paths.after_work_list_path), "new-after.example\n")

  local config = helper.read_file(fixture.paths.config_path)
  lu.assertStrContains(config, "||new-after.example^")
  lu.assertStrContains(config, "||old.example^")
  fixture.cleanup()
end
