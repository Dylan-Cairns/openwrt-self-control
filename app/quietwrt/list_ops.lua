local apply_engine = require("quietwrt.apply_engine")
local enforcement = require("quietwrt.enforcement")
local lists_store = require("quietwrt.lists_store")
local rules = require("quietwrt.rules")
local schema = require("quietwrt.schema")
local settings_store = require("quietwrt.settings_store")

local M = {}

local function apply_current_mode(context)
  return apply_engine.apply_mode(context, {
    require_installed = true,
  })
end

local function restore_previous_lists(context, previous_lists)
  local rollback_errors = {}

  local saved, save_error = lists_store.persist(context, previous_lists)
  if not saved then
    table.insert(rollback_errors, save_error)
    return rollback_errors
  end

  local restored, restore_error = apply_current_mode(context)
  if not restored then
    table.insert(rollback_errors, restore_error)
  end

  return rollback_errors
end

local function scheduled_lists(lists)
  local scheduled = {}

  for _, definition in ipairs(schema.HOST_LISTS) do
    if definition.name ~= "always" then
      scheduled[definition.name] = lists[definition.key]
    end
  end

  return scheduled
end

local function save_lists(context, result, passthrough_rules)
  local data = {
    passthrough_rules = passthrough_rules,
  }

  for _, definition in ipairs(schema.HOST_LISTS) do
    data[definition.key] = result[definition.key]
  end

  return lists_store.persist(context, data)
end

local function restore_arg_key(definition)
  return definition.name .. "_path"
end

local function load_restore_hosts(context, restore_paths, definition)
  local restore_path = restore_paths[restore_arg_key(definition)]
  if restore_path == nil then
    return nil, nil, false
  end

  local content = context.env.read_file(restore_path)
  if content == nil then
    return nil, "Could not read " .. restore_path .. ".", true
  end

  local hosts, err = rules.load_hosts_file(content, restore_path)
  if not hosts then
    return nil, err, true
  end

  return hosts, nil, true
end

function M.add_entry(context, destination, raw_value)
  if not settings_store.detect_installed(context) then
    return {
      ok = false,
      kind = "error",
      message = "QuietWrt is not installed.",
    }
  end

  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return {
      ok = false,
      kind = "error",
      message = config_error,
    }
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return {
      ok = false,
      kind = "error",
      message = enforcement_check_error,
    }
  end

  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return {
      ok = false,
      kind = "error",
      message = list_error,
    }
  end

  local previous_lists = lists_store.clone(lists)
  local result = rules.apply_addition(
    lists.always_hosts,
    scheduled_lists(lists),
    destination,
    raw_value
  )

  if not result.ok then
    return result
  end

  local saved, save_error = save_lists(context, result, lists.passthrough_rules)
  if not saved then
    return {
      ok = false,
      kind = "error",
      message = save_error,
    }
  end

  local applied, apply_result = apply_current_mode(context)
  if not applied then
    local rollback_errors = restore_previous_lists(context, previous_lists)
    local message = apply_result
    if #rollback_errors > 0 then
      message = message .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
    end

    return {
      ok = false,
      kind = "error",
      message = message,
    }
  end

  result.active_rule_count = apply_result.active_rule_count
  return result
end

function M.restore_lists(context, restore_paths)
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

  local current_lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not current_lists then
    return false, list_error
  end

  local replacements = {}
  local selected_count = 0

  for _, definition in ipairs(schema.HOST_LISTS) do
    local hosts, err, selected = load_restore_hosts(context, restore_paths, definition)
    if err ~= nil then
      return false, err
    end

    if selected then
      replacements[definition.key] = hosts
      selected_count = selected_count + 1
    end
  end

  if selected_count == 0 then
    return false, "Provide at least one restore file."
  end

  local previous_lists = lists_store.clone(current_lists)
  local saved, save_error = lists_store.persist_selected(context, replacements)
  if not saved then
    return false, save_error
  end

  local applied, apply_result = apply_current_mode(context)
  if not applied then
    local rollback_errors = restore_previous_lists(context, previous_lists)
    if #rollback_errors == 0 then
      return false, apply_result
    end
    return false, apply_result .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
  end

  return true, {
    active_rule_count = apply_result.active_rule_count,
  }
end

return M
