local enforcement = require("quietwrt.enforcement")
local firewall = require("quietwrt.firewall")
local lists_store = require("quietwrt.lists_store")
local rules = require("quietwrt.rules")
local runtime = require("quietwrt.runtime")
local settings_store = require("quietwrt.settings_store")

local M = {}

function M.apply_mode(context, options)
  options = options or {}

  if options.require_installed ~= false and not settings_store.detect_installed(context) then
    return false, "QuietWrt is not installed."
  end

  local parsed_config = options.parsed_config
  if not parsed_config then
    local config_error
    parsed_config, config_error = enforcement.read_state(context)
    if not parsed_config then
      return false, config_error
    end
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local lists = options.lists
  if not lists then
    local installed = options.installed
    if installed == nil then
      installed = true
    end

    local allow_bootstrap = options.allow_bootstrap == true
    local list_error
    lists, list_error = lists_store.load(context, parsed_config, {
      installed = installed,
      allow_bootstrap = allow_bootstrap,
    })
    if not lists then
      return false, list_error
    end
  end

  local settings = options.settings
  if settings == nil then
    local settings_error
    settings, settings_error = settings_store.read_settings(context, true)
    if not settings then
      return false, settings_error
    end
  end

  local activity, activity_error = runtime.build_runtime_activity(settings, context.env.now())
  if not activity then
    return false, activity_error
  end

  local active_always_hosts, active_scheduled_hosts = runtime.build_active_hosts(lists, settings, activity)
  local compiled_rules = rules.compile_active_rules(
    active_always_hosts,
    active_scheduled_hosts,
    lists.passthrough_rules
  )

  local adguard_ok, adguard_error, adguard_changed = enforcement.apply_rules(context, parsed_config, compiled_rules)
  if not adguard_ok then
    return false, adguard_error
  end

  local curfew_enabled = activity.overnight_active
  local previous_firewall = firewall.capture_snapshot(context)
  local desired_firewall = firewall.desired_snapshot(curfew_enabled)
  if not firewall.snapshots_equal(previous_firewall, desired_firewall) then
    local firewall_ok, firewall_error = firewall.commit_snapshot(context, desired_firewall)
    if not firewall_ok then
      local rollback_errors = {}

      if adguard_changed then
        local restore_ok, restore_error = enforcement.restore_config(context, parsed_config.content)
        if not restore_ok then
          table.insert(rollback_errors, restore_error)
        end
      end

      local firewall_restore_ok, firewall_restore_error = firewall.commit_snapshot(context, previous_firewall)
      if not firewall_restore_ok then
        table.insert(rollback_errors, firewall_restore_error)
      end

      if #rollback_errors == 0 then
        return false, firewall_error .. " Previous state was restored."
      end

      return false, firewall_error .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
    end
  end

  return true, {
    settings = settings,
    activity = activity,
    active_rule_count = #compiled_rules,
    bootstrapped = lists.bootstrapped,
  }
end

return M
