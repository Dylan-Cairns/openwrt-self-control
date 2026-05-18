local context_helpers = require("quietwrt.context")
local enforcement = require("quietwrt.enforcement")
local firewall = require("quietwrt.firewall")
local lists_store = require("quietwrt.lists_store")
local rules = require("quietwrt.rules")
local schema = require("quietwrt.schema")
local settings_store = require("quietwrt.settings_store")
local util = require("quietwrt.util")

local M = {}

local function marker_path(context)
  return context.paths.failsafe_marker_path
end

local function marker_content(reason, warnings)
  local lines = {
    "QuietWrt entered failsafe-open mode.",
    "Reason: " .. tostring(reason or "Unknown failure."),
  }

  for _, warning in ipairs(warnings or {}) do
    table.insert(lines, "Warning: " .. tostring(warning))
  end

  return table.concat(lines, "\n") .. "\n"
end

function M.read_marker(context)
  local path = marker_path(context)
  if path == nil or path == "" then
    return {
      active = false,
    }
  end

  local content = context.env.read_file(path)
  if content == nil then
    return {
      active = false,
    }
  end

  local reason = content:match("Reason:%s*([^\n]+)") or util.trim(content)
  return {
    active = true,
    reason = reason ~= "" and reason or "QuietWrt entered failsafe-open mode.",
    content = content,
  }
end

function M.clear_marker(context)
  local path = marker_path(context)
  if path == nil or path == "" then
    return true, nil
  end

  context.env.remove_file(path)
  if context.env.file_exists(path) then
    return false, "Could not remove " .. path .. "."
  end

  return true, nil
end

function M.write_marker(context, reason, warnings)
  local ok, err = context_helpers.ensure_data_dir(context.env, context.paths)
  if not ok then
    return false, err
  end

  return context_helpers.write_atomic(context.env, marker_path(context), marker_content(reason, warnings))
end

local function disabled_settings(context)
  local settings = nil
  if settings_store.detect_installed(context) then
    settings = settings_store.read_settings(context, true)
  end

  if settings == nil then
    settings = settings_store.default_install_settings()
  end

  for _, toggle in ipairs(schema.TOGGLES) do
    settings[toggle.key] = false
  end
  settings.schema_version = schema.SCHEMA_VERSION
  return settings
end

local function clear_adguard_rules_if_readable(context)
  local parsed_config = enforcement.read_state(context)
  if parsed_config == nil then
    return true, nil, "skipped"
  end

  local _, parsed_passthrough_rules = rules.partition_user_rules(parsed_config.rules)
  local passthrough_rules = parsed_passthrough_rules or {}
  local lists = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if lists ~= nil then
    passthrough_rules = lists.passthrough_rules or {}
  end

  local compiled_rules = rules.compile_active_rules({}, {}, passthrough_rules)
  local ok, err = enforcement.apply_rules(context, parsed_config, compiled_rules)
  if not ok then
    return false, err
  end

  return true, nil, "cleared"
end

function M.enter_failsafe_open(context, reason)
  local warnings = {}

  local firewall_ok, firewall_error = firewall.clear_managed(context)
  if not firewall_ok then
    table.insert(warnings, firewall_error)
  end

  local settings_ok, settings_error = settings_store.persist_settings(context, disabled_settings(context))
  if not settings_ok then
    table.insert(warnings, settings_error)
  end

  local adguard_ok, adguard_error = clear_adguard_rules_if_readable(context)
  if not adguard_ok then
    table.insert(warnings, adguard_error)
  end

  local marker_ok, marker_error = M.write_marker(context, reason, warnings)
  if not marker_ok then
    table.insert(warnings, marker_error)
  end

  if not firewall_ok then
    return false, table.concat(warnings, " | ")
  end

  return true, {
    failsafe_open = true,
    reason = reason,
    warnings = warnings,
  }
end

function M.validate_boot_state(context)
  local install_state = settings_store.read_install_state(context)
  if not install_state.installed then
    if install_state.settings_path_present then
      return false, "QuietWrt settings are incomplete or use an unsupported schema version."
    end

    return true, nil
  end

  local settings, settings_error = settings_store.read_settings(context, true)
  if not settings then
    return false, settings_error
  end

  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return false, config_error
  end

  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return false, list_error
  end

  return true, nil
end

function M.boot_check(context)
  local healthy, failure = M.validate_boot_state(context)
  if healthy then
    M.clear_marker(context)
    return true, {
      healthy = true,
    }
  end

  local opened, result = M.enter_failsafe_open(context, failure)
  if not opened then
    return false, result
  end

  return true, result
end

return M
