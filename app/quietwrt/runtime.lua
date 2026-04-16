local rules = require("quietwrt.rules")
local schedule = require("quietwrt.schedule")
local schema = require("quietwrt.schema")
local util = require("quietwrt.util")

local M = {}

local function serialize_window(window)
  return {
    start = window.start,
    ["end"] = window["end"],
    display_start = window.display_start,
    display_end = window.display_end,
    overnight = window.overnight,
  }
end

local function serialize_schedule_windows(windows)
  return {
    workday = serialize_window(windows.workday),
    after_work = serialize_window(windows.after_work),
    password_vault = serialize_window(windows.password_vault),
    overnight = serialize_window(windows.overnight),
  }
end

function M.build_schedule_windows(settings)
  local windows = {}

  for _, definition in ipairs(schema.SCHEDULES) do
    local window, err = schedule.build_window(
      definition.name,
      settings[definition.start_key],
      settings[definition.end_key]
    )
    if not window then
      return nil, err
    end

    windows[definition.name] = window
  end

  return windows, nil
end

function M.build_runtime_activity(settings, now_table)
  local windows, err = M.build_schedule_windows(settings)
  if not windows then
    return nil, err
  end

  local workday_window_active = schedule.window_contains(windows.workday, now_table)
  local after_work_window_active = schedule.window_contains(windows.after_work, now_table)
  local password_vault_window_active = schedule.window_contains(windows.password_vault, now_table)
  local overnight_window_active = schedule.window_contains(windows.overnight, now_table)

  return {
    schedule = windows,
    workday_window_active = workday_window_active,
    after_work_window_active = after_work_window_active,
    password_vault_window_active = password_vault_window_active,
    overnight_window_active = overnight_window_active,
    workday_active = settings.workday_enabled and workday_window_active,
    after_work_active = settings.after_work_enabled and after_work_window_active,
    password_vault_active = settings.password_vault_enabled and password_vault_window_active,
    overnight_active = settings.overnight_enabled and overnight_window_active,
  }, nil
end

function M.build_active_hosts(lists, settings, activity)
  local always_hosts = {}
  if settings.always_enabled then
    always_hosts = lists.always_hosts
  end

  local scheduled_hosts = {}
  if activity.workday_active then
    for _, host in ipairs(lists.workday_hosts or {}) do
      table.insert(scheduled_hosts, host)
    end
  end

  if activity.after_work_active then
    for _, host in ipairs(lists.after_work_hosts or {}) do
      table.insert(scheduled_hosts, host)
    end
  end

  if activity.password_vault_active then
    for _, host in ipairs(lists.password_vault_hosts or {}) do
      table.insert(scheduled_hosts, host)
    end
  end

  return always_hosts, util.sorted_unique(scheduled_hosts)
end

function M.build_view_state(parsed_config, lists, settings, activity, hardening_state, installed, enforcement_ready)
  local active_always_hosts, active_scheduled_hosts = M.build_active_hosts(lists, settings, activity)
  local active_rules = rules.compile_active_rules(
    active_always_hosts,
    active_scheduled_hosts,
    lists.passthrough_rules
  )

  local protection_enabled = nil
  if parsed_config ~= nil then
    protection_enabled = parsed_config.protection_enabled
  end

  return {
    installed = installed,
    protection_enabled = protection_enabled,
    enforcement_ready = enforcement_ready,
    settings = settings,
    schedule = serialize_schedule_windows(activity.schedule),
    always_hosts = lists.always_hosts,
    workday_hosts = lists.workday_hosts,
    after_work_hosts = lists.after_work_hosts,
    password_vault_hosts = lists.password_vault_hosts,
    passthrough_rules = lists.passthrough_rules,
    active_rules = active_rules,
    active_rule_count = #active_rules,
    workday_window_active = activity.workday_window_active,
    after_work_window_active = activity.after_work_window_active,
    password_vault_window_active = activity.password_vault_window_active,
    overnight_window_active = activity.overnight_window_active,
    workday_active = activity.workday_active,
    after_work_active = activity.after_work_active,
    password_vault_active = activity.password_vault_active,
    overnight_active = activity.overnight_active,
    hardening = hardening_state,
    warnings = {},
  }
end

function M.format_router_time(now_table)
  local hour = tonumber(now_table and now_table.hour)
  local min = tonumber(now_table and now_table.min)

  if hour == nil or min == nil then
    return "Unknown"
  end

  return string.format("%02d:%02d", hour, min)
end

function M.uninstalled_snapshot(now_table)
  return {
    installed = false,
    protection_enabled = nil,
    enforcement_ready = false,
    settings = {
      always_enabled = false,
      workday_enabled = false,
      after_work_enabled = false,
      password_vault_enabled = false,
      overnight_enabled = false,
    },
    schedule = {},
    always_hosts = {},
    workday_hosts = {},
    after_work_hosts = {},
    password_vault_hosts = {},
    passthrough_rules = {},
    active_rules = {},
    active_rule_count = 0,
    workday_window_active = false,
    after_work_window_active = false,
    password_vault_window_active = false,
    overnight_window_active = false,
    workday_active = false,
    after_work_active = false,
    password_vault_active = false,
    overnight_active = false,
    hardening = {
      dns_intercept = false,
      dot_block = false,
      overnight_rule = false,
    },
    warnings = {},
    router_time = M.format_router_time(now_table),
  }
end

return M
