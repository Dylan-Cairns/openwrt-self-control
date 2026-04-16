local context_helpers = require("quietwrt.context")
local schedule = require("quietwrt.schedule")
local schema = require("quietwrt.schema")
local util = require("quietwrt.util")

local M = {}

local function build_cron_block(paths, settings)
  local boundaries = {}
  local seen = {}

  for _, definition in ipairs(schema.SCHEDULES) do
    for _, key in ipairs({ definition.start_key, definition.end_key }) do
      local hhmm = settings[key]
      if not seen[hhmm] then
        local minutes, minutes_error = schedule.minutes_of_hhmm(hhmm)
        if minutes == nil then
          return nil, minutes_error
        end

        local spec, spec_error = schedule.cron_spec(hhmm)
        if spec == nil then
          return nil, spec_error
        end

        table.insert(boundaries, {
          minutes = minutes,
          spec = spec,
        })
        seen[hhmm] = true
      end
    end
  end

  table.sort(boundaries, function(left, right)
    return left.minutes < right.minutes
  end)

  local lines = {
    "# BEGIN quietwrt schedule",
    "*/10 * * * * " .. paths.quietwrtctl_path .. " sync",
  }

  for _, boundary in ipairs(boundaries) do
    table.insert(lines, boundary.spec .. " " .. paths.quietwrtctl_path .. " sync")
  end

  table.insert(lines, "# END quietwrt schedule")
  table.insert(lines, "")
  return table.concat(lines, "\n"), nil
end

local function strip_cron_block(original)
  return original
    :gsub("\n?# BEGIN quietwrt schedule\n.-\n# END quietwrt schedule", "")
    :gsub("^# BEGIN quietwrt schedule\n.-\n# END quietwrt schedule\n?", "")
    :gsub("%s+$", "")
end

local function restore_file(context, path, content)
  if content == nil then
    context.env.remove_file(path)
    if context.env.file_exists(path) then
      return false, "Could not remove " .. path .. "."
    end
    return true, nil
  end

  return context_helpers.write_atomic(context.env, path, content)
end

function M.install_schedule(context, settings)
  local cron_block, cron_error = build_cron_block(context.paths, settings)
  if not cron_block then
    return false, cron_error
  end

  local original = context.env.read_file(context.paths.crontab_path) or ""
  local without_existing = strip_cron_block(original)

  local updated
  if without_existing == "" then
    updated = cron_block
  else
    updated = without_existing .. "\n\n" .. cron_block
  end

  local saved, save_error = context_helpers.write_atomic(context.env, context.paths.crontab_path, updated)
  if not saved then
    return false, save_error
  end

  if util.command_succeeded(context.env.execute(context.paths.restart_cron_command)) then
    return true, nil
  end

  return false, "Cron restart failed after updating " .. context.paths.crontab_path .. "."
end

function M.enable_boot_sync_service(context)
  if util.command_succeeded(context.env.execute(context.paths.enable_init_service_command)) then
    return true, nil
  end

  return false, "Could not enable the QuietWrt boot sync service at " .. context.paths.init_service_path .. "."
end

function M.restore_schedule(context, original_content)
  local saved, save_error = restore_file(context, context.paths.crontab_path, original_content)
  if not saved then
    return false, save_error
  end

  if util.command_succeeded(context.env.execute(context.paths.restart_cron_command)) then
    return true, nil
  end

  return false, "Cron restart failed while restoring " .. context.paths.crontab_path .. "."
end

function M.restore_boot_sync_service(context, was_enabled)
  local command = was_enabled and context.paths.enable_init_service_command or context.paths.disable_init_service_command
  if util.command_succeeded(context.env.execute(command)) then
    return true, nil
  end

  if was_enabled then
    return false, "Could not re-enable the QuietWrt boot sync service at " .. context.paths.init_service_path .. "."
  end

  return false, "Could not disable the QuietWrt boot sync service at " .. context.paths.init_service_path .. "."
end

return M
