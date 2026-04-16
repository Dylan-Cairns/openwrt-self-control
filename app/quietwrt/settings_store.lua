local schedule = require("quietwrt.schedule")
local schema = require("quietwrt.schema")
local util = require("quietwrt.util")
local context_helpers = require("quietwrt.context")

local M = {}

local function bool_to_uci(value)
  return value and "1" or "0"
end

local function uci_to_bool(value, fallback)
  if value == "1" or value == "true" or value == "on" then
    return true
  end

  if value == "0" or value == "false" or value == "off" then
    return false
  end

  return fallback
end

local function read_required_bool(context, option_name)
  local raw = util.trim(context.env.capture("uci -q get quietwrt.settings." .. option_name) or "")
  if raw == "" then
    return nil, "Missing QuietWrt setting quietwrt.settings." .. option_name .. "."
  end

  local value = uci_to_bool(raw, nil)
  if value == nil then
    return nil, "Invalid QuietWrt setting quietwrt.settings." .. option_name .. "."
  end

  return value, nil
end

local function read_required_hhmm(context, option_name, label)
  local raw = util.trim(context.env.capture("uci -q get quietwrt.settings." .. option_name) or "")
  if raw == "" then
    return nil, "Missing QuietWrt setting quietwrt.settings." .. option_name .. "."
  end

  local normalized, err = schedule.normalize_hhmm(raw)
  if not normalized then
    return nil, label .. ": " .. err
  end

  return normalized, nil
end

local function write_settings(context, settings, schema_version)
  if not context.env.file_exists(context.paths.settings_config_path) then
    local created = context.env.write_file(context.paths.settings_config_path, "")
    if not created then
      return false, "write " .. context.paths.settings_config_path
    end
  end

  local commands = {
    "uci -q delete quietwrt.settings >/dev/null 2>&1 || true",
    "uci set quietwrt.settings='settings'",
  }

  for _, toggle in ipairs(schema.TOGGLES) do
    table.insert(commands, "uci set quietwrt.settings." .. toggle.key .. "='" .. bool_to_uci(settings[toggle.key]) .. "'")
  end

  for _, definition in ipairs(schema.SCHEDULES) do
    table.insert(commands, "uci set quietwrt.settings." .. definition.start_key .. "='" .. tostring(settings[definition.start_key]) .. "'")
    table.insert(commands, "uci set quietwrt.settings." .. definition.end_key .. "='" .. tostring(settings[definition.end_key]) .. "'")
  end

  if schema_version ~= nil then
    table.insert(commands, "uci set quietwrt.settings.schema_version='" .. tostring(schema_version) .. "'")
  end

  table.insert(commands, "uci commit quietwrt")
  return context_helpers.run_commands(context.env, commands)
end

function M.read_install_state(context)
  local schema_version = util.trim(context.env.capture("uci -q get quietwrt.settings.schema_version") or "")
  return {
    installed = schema_version == schema.SCHEMA_VERSION,
    schema_version = schema_version ~= "" and schema_version or nil,
    settings_path_present = context.env.file_exists(context.paths.settings_config_path),
  }
end

function M.detect_installed(context)
  return M.read_install_state(context).installed
end

function M.read_settings(context, installed)
  if installed ~= true then
    return {
      always_enabled = false,
      workday_enabled = false,
      after_work_enabled = false,
      password_vault_enabled = false,
      overnight_enabled = false,
      schema_version = nil,
    }, nil
  end

  local settings = {
    schema_version = schema.SCHEMA_VERSION,
  }

  for _, toggle in ipairs(schema.TOGGLES) do
    local value, err = read_required_bool(context, toggle.key)
    if value == nil then
      return nil, err
    end

    settings[toggle.key] = value
  end

  for _, definition in ipairs(schema.SCHEDULES) do
    local start_value, start_error = read_required_hhmm(
      context,
      definition.start_key,
      schedule.window_label(definition.name) .. " start time"
    )
    if start_value == nil then
      return nil, start_error
    end

    local end_value, end_error = read_required_hhmm(
      context,
      definition.end_key,
      schedule.window_label(definition.name) .. " end time"
    )
    if end_value == nil then
      return nil, end_error
    end

    local window, window_error = schedule.build_window(definition.name, start_value, end_value)
    if not window then
      return nil, window_error
    end

    settings[definition.start_key] = window.start
    settings[definition.end_key] = window["end"]
  end

  return settings, nil
end

function M.copy_settings(settings)
  local copied = {}
  for key, value in pairs(settings or {}) do
    copied[key] = value
  end
  return copied
end

function M.default_install_settings()
  local defaults = schedule.default_windows()
  return {
    always_enabled = true,
    workday_enabled = true,
    after_work_enabled = true,
    password_vault_enabled = true,
    overnight_enabled = false,
    workday_start = defaults.workday.start,
    workday_end = defaults.workday["end"],
    after_work_start = defaults.after_work.start,
    after_work_end = defaults.after_work["end"],
    password_vault_start = defaults.password_vault.start,
    password_vault_end = defaults.password_vault["end"],
    overnight_start = defaults.overnight.start,
    overnight_end = defaults.overnight["end"],
    schema_version = schema.SCHEMA_VERSION,
  }
end

function M.seed_install_settings(context)
  local defaults = M.default_install_settings()
  local settings = M.copy_settings(defaults)

  for _, toggle in ipairs(schema.TOGGLES) do
    local raw = util.trim(context.env.capture("uci -q get quietwrt.settings." .. toggle.key) or "")
    settings[toggle.key] = uci_to_bool(raw, defaults[toggle.key])
  end

  for _, definition in ipairs(schema.SCHEDULES) do
    local start_raw = util.trim(context.env.capture("uci -q get quietwrt.settings." .. definition.start_key) or "")
    local end_raw = util.trim(context.env.capture("uci -q get quietwrt.settings." .. definition.end_key) or "")
    local start_value = schedule.normalize_hhmm(start_raw)
    local end_value = schedule.normalize_hhmm(end_raw)

    if start_value ~= nil and end_value ~= nil then
      local window = schedule.build_window(definition.name, start_value, end_value)
      if window ~= nil then
        settings[definition.start_key] = window.start
        settings[definition.end_key] = window["end"]
      end
    end
  end

  settings.schema_version = schema.SCHEMA_VERSION
  return settings
end

function M.persist_settings(context, settings)
  local next_settings = M.copy_settings(settings)
  next_settings.schema_version = next_settings.schema_version or schema.SCHEMA_VERSION

  local ok, failed_command = write_settings(context, next_settings, next_settings.schema_version)
  if ok then
    return true, next_settings
  end

  return false, "QuietWrt settings update failed while running: " .. failed_command
end

return M
