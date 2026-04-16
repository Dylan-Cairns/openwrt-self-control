local context_helpers = require("quietwrt.context")
local operations = require("quietwrt.operations")

local M = {}

function M.new_context(options)
  return context_helpers.new_context(options)
end

function M.load_view_state(context)
  return operations.load_view_state(context)
end

function M.apply_current_mode(context)
  return operations.apply_current_mode(context)
end

function M.add_entry(context, destination, raw_value)
  return operations.add_entry(context, destination, raw_value)
end

function M.install(context)
  return operations.install(context)
end

function M.set_toggle(context, toggle_name, enabled)
  return operations.set_toggle(context, toggle_name, enabled)
end

function M.set_schedule(context, schedule_name, start_value, end_value)
  return operations.set_schedule(context, schedule_name, start_value, end_value)
end

function M.restore_lists(context, restore_paths)
  return operations.restore_lists(context, restore_paths)
end

function M.status(context, options)
  return operations.status(context, options)
end

return M
