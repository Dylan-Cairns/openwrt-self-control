local adguard = require("quietwrt.adguard")
local context_helpers = require("quietwrt.context")
local util = require("quietwrt.util")

local M = {}

local function apply_config(context, original_config, updated_config)
  if updated_config == original_config then
    return true, nil, false
  end

  local saved, save_error = context_helpers.write_atomic(context.env, context.paths.config_path, updated_config)
  if not saved then
    return false, save_error, false
  end

  if util.command_succeeded(context.env.execute(context.paths.restart_adguard_command)) then
    return true, nil, true
  end

  local restore_ok, restore_error = M.restore_config(context, original_config)
  if restore_ok then
    return false, "AdGuard Home restart failed. The previous config was restored.", false
  end

  return false, "AdGuard Home restart failed and the previous config could not be restored: " .. restore_error, false
end

function M.read_state(context)
  local content = context.env.read_file(context.paths.config_path)
  if not content then
    return nil, "Could not read " .. context.paths.config_path .. "."
  end

  local parsed = adguard.parse_config(content)
  parsed.content = content
  return parsed, nil
end

function M.enforcement_error(context, parsed_config)
  if parsed_config == nil then
    return "Could not read " .. context.paths.config_path .. "."
  end

  if parsed_config.protection_enabled == true then
    return nil
  end

  if parsed_config.protection_enabled == false then
    return "AdGuard Home protection is disabled in " .. context.paths.config_path
      .. ". QuietWrt cannot enforce blocklists until it is enabled."
  end

  return "Could not confirm that AdGuard Home protection is enabled in " .. context.paths.config_path
    .. ". QuietWrt fails closed until it is enabled."
end

function M.is_ready(context, parsed_config)
  return M.enforcement_error(context, parsed_config) == nil
end

function M.require_ready(context, parsed_config)
  local err = M.enforcement_error(context, parsed_config)
  if err then
    return false, err
  end

  return true, nil
end

function M.restore_config(context, content)
  local saved, save_error = context_helpers.write_atomic(context.env, context.paths.config_path, content)
  if not saved then
    return false, save_error
  end

  if util.command_succeeded(context.env.execute(context.paths.restart_adguard_command)) then
    return true, nil
  end

  return false, "AdGuard Home restart failed while restoring the previous config."
end

function M.apply_rules(context, parsed_config, compiled_rules)
  local updated_config = adguard.serialize_config(parsed_config, compiled_rules)
  return apply_config(context, parsed_config.content, updated_config)
end

return M
