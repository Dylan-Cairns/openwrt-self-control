local apply_engine = require("quietwrt.apply_engine")
local cron = require("quietwrt.cron")
local enforcement = require("quietwrt.enforcement")
local lists_store = require("quietwrt.lists_store")
local schedule = require("quietwrt.schedule")
local schema = require("quietwrt.schema")
local settings_store = require("quietwrt.settings_store")

local M = {}

local function append_rollback_errors(message, rollback_errors)
  if rollback_errors == nil or #rollback_errors == 0 then
    return message
  end

  return message .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
end

local function find_toggle(toggle_name)
  for _, definition in ipairs(schema.TOGGLES) do
    if definition.name == toggle_name then
      return definition
    end
  end

  return nil
end

local function find_schedule(schedule_name)
  for _, definition in ipairs(schema.SCHEDULES) do
    if definition.name == schedule_name then
      return definition
    end
  end

  return nil
end

local function apply_settings_change(context, next_settings)
  if not settings_store.detect_installed(context) then
    return false, "QuietWrt is not installed."
  end

  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return false, config_error
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local current_settings, current_settings_error = settings_store.read_settings(context, true)
  if not current_settings then
    return false, current_settings_error
  end

  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return false, list_error
  end

  local original_crontab = context.env.read_file(context.paths.crontab_path)
  next_settings = settings_store.copy_settings(next_settings)

  local schedule_ok, schedule_error = cron.install_schedule(context, next_settings)
  if not schedule_ok then
    return false, schedule_error
  end

  local applied, apply_result = apply_engine.apply_mode(context, {
    parsed_config = parsed_config,
    lists = lists,
    settings = next_settings,
  })
  if not applied then
    local rollback_errors = {}
    local restored_schedule, restored_schedule_error = cron.restore_schedule(context, original_crontab)
    if not restored_schedule then
      table.insert(rollback_errors, restored_schedule_error)
    end
    return false, append_rollback_errors(apply_result, rollback_errors)
  end

  local settings_ok, settings_result = settings_store.persist_settings(context, next_settings)
  if not settings_ok then
    local rollback_errors = {}

    local restored_schedule, restored_schedule_error = cron.restore_schedule(context, original_crontab)
    if not restored_schedule then
      table.insert(rollback_errors, restored_schedule_error)
    end

    local restored_settings_ok, restored_settings_error = settings_store.persist_settings(context, current_settings)
    if not restored_settings_ok then
      table.insert(rollback_errors, restored_settings_error)
    end

    local restored, restore_error = apply_engine.apply_mode(context, {
      parsed_config = parsed_config,
      lists = lists,
      settings = current_settings,
    })
    if not restored then
      table.insert(rollback_errors, restore_error)
    end

    return false, append_rollback_errors(settings_result, rollback_errors)
  end

  return true, {
    settings = settings_result,
    active_rule_count = apply_result.active_rule_count,
  }
end

function M.set_toggle(context, toggle_name, enabled)
  local settings, err = settings_store.read_settings(context, settings_store.detect_installed(context))
  if not settings then
    return false, err
  end

  local definition = find_toggle(toggle_name)
  if definition == nil then
    return false, "Unknown toggle: " .. tostring(toggle_name)
  end

  settings[definition.key] = enabled
  return apply_settings_change(context, settings)
end

function M.set_schedule(context, schedule_name, start_value, end_value)
  local settings, err = settings_store.read_settings(context, settings_store.detect_installed(context))
  if not settings then
    return false, err
  end

  local updated_window, window_error = schedule.build_window(schedule_name, start_value, end_value)
  if not updated_window then
    return false, window_error
  end

  local definition = find_schedule(schedule_name)
  if definition == nil then
    return false, "Unknown schedule: " .. tostring(schedule_name)
  end

  settings[definition.start_key] = updated_window.start
  settings[definition.end_key] = updated_window["end"]
  return apply_settings_change(context, settings)
end

return M
