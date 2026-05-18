local apply_engine = require("quietwrt.apply_engine")
local archive_ops = require("quietwrt.archive_ops")
local context_helpers = require("quietwrt.context")
local install_ops = require("quietwrt.install_ops")
local list_ops = require("quietwrt.list_ops")
local recovery = require("quietwrt.recovery")
local settings_ops = require("quietwrt.settings_ops")
local status_ops = require("quietwrt.status_ops")

local M = {}

local function locked(context, callback)
  return context_helpers.with_lock(context, callback)
end

local function locked_result(context, callback)
  local result, lock_error = context_helpers.with_lock(context, callback)
  if result == false then
    return {
      ok = false,
      kind = "error",
      message = lock_error,
    }
  end

  return result
end

function M.load_view_state(context)
  return status_ops.load_view_state(context)
end

function M.apply_current_mode(context)
  return locked(context, function()
    local failsafe = recovery.read_marker(context)
    if failsafe.active then
      local firewall_ok, firewall_error = recovery.enter_failsafe_open(context, failsafe.reason)
      if not firewall_ok then
        return false, firewall_error
      end

      return false, "QuietWrt is in failsafe-open mode: " .. failsafe.reason
    end

    return apply_engine.apply_mode(context, {
      require_installed = true,
      firewall_first = true,
    })
  end)
end

function M.add_entry(context, destination, raw_value)
  return locked_result(context, function()
    return list_ops.add_entry(context, destination, raw_value)
  end)
end

function M.download_blocklists_archive(context, format)
  return archive_ops.download_blocklists_archive(context, format)
end

function M.install(context)
  return locked(context, function()
    local ok, result = install_ops.install(context)
    if ok then
      recovery.clear_marker(context)
    end

    return ok, result
  end)
end

function M.boot_check(context)
  return locked(context, function()
    return recovery.boot_check(context)
  end)
end

function M.set_toggle(context, toggle_name, enabled)
  return locked(context, function()
    return settings_ops.set_toggle(context, toggle_name, enabled)
  end)
end

function M.enable_toggle(context, toggle_name)
  return locked(context, function()
    return settings_ops.enable_toggle(context, toggle_name)
  end)
end

function M.set_schedule(context, schedule_name, start_value, end_value)
  return locked(context, function()
    return settings_ops.set_schedule(context, schedule_name, start_value, end_value)
  end)
end

function M.restore_lists(context, restore_paths)
  return locked(context, function()
    return list_ops.restore_lists(context, restore_paths)
  end)
end

function M.import_blocklists_archive(context, content)
  return locked(context, function()
    return list_ops.import_blocklists_archive(context, content)
  end)
end

function M.status(context, options)
  return status_ops.status(context, options)
end

return M
