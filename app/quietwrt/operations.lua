local apply_engine = require("quietwrt.apply_engine")
local install_ops = require("quietwrt.install_ops")
local list_ops = require("quietwrt.list_ops")
local settings_ops = require("quietwrt.settings_ops")
local status_ops = require("quietwrt.status_ops")

local M = {}

function M.load_view_state(context)
  return status_ops.load_view_state(context)
end

function M.apply_current_mode(context)
  return apply_engine.apply_mode(context, {
    require_installed = true,
  })
end

function M.add_entry(context, destination, raw_value)
  return list_ops.add_entry(context, destination, raw_value)
end

function M.install(context)
  return install_ops.install(context)
end

function M.set_toggle(context, toggle_name, enabled)
  return settings_ops.set_toggle(context, toggle_name, enabled)
end

function M.set_schedule(context, schedule_name, start_value, end_value)
  return settings_ops.set_schedule(context, schedule_name, start_value, end_value)
end

function M.restore_lists(context, restore_paths)
  return list_ops.restore_lists(context, restore_paths)
end

function M.status(context, options)
  return status_ops.status(context, options)
end

return M
