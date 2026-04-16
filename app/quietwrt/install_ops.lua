local apply_engine = require("quietwrt.apply_engine")
local cron = require("quietwrt.cron")
local enforcement = require("quietwrt.enforcement")
local firewall = require("quietwrt.firewall")
local lists_store = require("quietwrt.lists_store")
local settings_store = require("quietwrt.settings_store")

local M = {}

local function append_rollback_errors(message, rollback_errors)
  if rollback_errors == nil or #rollback_errors == 0 then
    return message
  end

  return message .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
end

local function rollback_install(context, rollback_state)
  local rollback_errors = {}

  if rollback_state.applied then
    local restore_ok, restore_error = enforcement.restore_config(
      context,
      rollback_state.original_adguard_config
    )
    if not restore_ok then
      table.insert(rollback_errors, restore_error)
    end

    local firewall_ok, firewall_error = firewall.commit_snapshot(
      context,
      rollback_state.original_firewall
    )
    if not firewall_ok then
      table.insert(rollback_errors, firewall_error)
    end
  end

  if rollback_state.schedule_changed then
    local schedule_ok, schedule_error = cron.restore_schedule(
      context,
      rollback_state.original_crontab
    )
    if not schedule_ok then
      table.insert(rollback_errors, schedule_error)
    end
  end

  if rollback_state.boot_service_changed then
    local boot_service_ok, boot_service_error = cron.restore_boot_sync_service(
      context,
      rollback_state.boot_service_enabled
    )
    if not boot_service_ok then
      table.insert(rollback_errors, boot_service_error)
    end
  end

  if rollback_state.bootstrapped_lists then
    local cleanup_ok, cleanup_error = lists_store.remove_bootstrapped_files(context)
    if not cleanup_ok then
      table.insert(rollback_errors, cleanup_error)
    end
  end

  if rollback_state.original_settings ~= nil then
    local settings_ok, settings_error = settings_store.persist_settings(context, rollback_state.original_settings)
    if not settings_ok then
      table.insert(rollback_errors, settings_error)
    end
  end

  return rollback_errors
end

function M.install(context)
  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return false, config_error
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local install_state = settings_store.read_install_state(context)
  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = install_state.installed,
    allow_bootstrap = not install_state.installed,
  })
  if not lists then
    return false, list_error
  end

  local staged_settings
  if install_state.installed then
    local settings_error
    staged_settings, settings_error = settings_store.read_settings(context, true)
    if not staged_settings then
      return false, settings_error
    end
  else
    staged_settings = settings_store.seed_install_settings(context)
  end

  local original_settings = nil
  if install_state.installed then
    original_settings = settings_store.copy_settings(staged_settings)
  end

  local rollback_state = {
    original_crontab = context.env.read_file(context.paths.crontab_path),
    boot_service_enabled = context.env.file_exists(context.paths.init_service_enabled_path),
    bootstrapped_lists = lists.bootstrapped == true,
    original_adguard_config = parsed_config.content,
    original_firewall = firewall.capture_snapshot(context),
    original_settings = original_settings,
    schedule_changed = true,
    boot_service_changed = false,
    applied = false,
  }

  local schedule_ok, schedule_error = cron.install_schedule(context, staged_settings)
  if not schedule_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(schedule_error, rollback_errors)
  end

  local boot_service_ok, boot_service_error = cron.enable_boot_sync_service(context)
  if not boot_service_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(boot_service_error, rollback_errors)
  end
  rollback_state.boot_service_changed = true

  local applied, apply_result = apply_engine.apply_mode(context, {
    require_installed = false,
    parsed_config = parsed_config,
    lists = lists,
    settings = staged_settings,
  })
  if not applied then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(apply_result, rollback_errors)
  end
  rollback_state.applied = true

  local settings_ok, settings_result = settings_store.persist_settings(context, staged_settings)
  if not settings_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(settings_result, rollback_errors)
  end

  return true, {
    settings = settings_result,
    active_rule_count = apply_result.active_rule_count,
    bootstrapped = lists.bootstrapped,
  }
end

return M
