local context_helpers = require("quietwrt.context")
local rules = require("quietwrt.rules")
local schema = require("quietwrt.schema")
local util = require("quietwrt.util")

local M = {}

local function read_lists(context)
  local existing = {
    passthrough_content = context.env.read_file(context.paths.passthrough_rules_path),
  }

  for _, definition in ipairs(schema.HOST_LISTS) do
    existing[definition.name .. "_content"] = context.env.read_file(context.paths[definition.path_key])
  end

  return existing
end

local function missing_list_paths(existing, paths)
  local missing = {}

  for _, definition in ipairs(schema.HOST_LISTS) do
    if existing[definition.name .. "_content"] == nil then
      table.insert(missing, paths[definition.path_key])
    end
  end

  if existing.passthrough_content == nil then
    table.insert(missing, paths.passthrough_rules_path)
  end

  return missing
end

local function parse_existing_lists(existing, paths)
  local parsed = {
    passthrough_rules = {},
    bootstrapped = false,
  }

  for _, definition in ipairs(schema.HOST_LISTS) do
    local hosts, host_error = rules.load_hosts_file(existing[definition.name .. "_content"], paths[definition.path_key])
    if not hosts then
      return nil, host_error
    end

    parsed[definition.key] = hosts
  end

  local passthrough_rules, passthrough_error = rules.load_rules_file(existing.passthrough_content, paths.passthrough_rules_path)
  if not passthrough_rules then
    return nil, passthrough_error
  end

  parsed.passthrough_rules = passthrough_rules
  return parsed, nil
end

function M.empty_state()
  return {
    always_hosts = {},
    workday_hosts = {},
    after_work_hosts = {},
    password_vault_hosts = {},
    passthrough_rules = {},
    bootstrapped = false,
  }
end

function M.clone(lists)
  return {
    always_hosts = util.clone_array(lists.always_hosts),
    workday_hosts = util.clone_array(lists.workday_hosts),
    after_work_hosts = util.clone_array(lists.after_work_hosts),
    password_vault_hosts = util.clone_array(lists.password_vault_hosts),
    passthrough_rules = util.clone_array(lists.passthrough_rules),
  }
end

function M.persist_selected(context, data)
  local ok, err = context_helpers.ensure_data_dir(context.env, context.paths)
  if not ok then
    return false, err
  end

  local writes = {}
  for _, definition in ipairs(schema.HOST_LISTS) do
    local hosts = data[definition.key]
    if hosts ~= nil then
      table.insert(writes, {
        path = context.paths[definition.path_key],
        content = rules.serialize_hosts_file(hosts),
      })
    end
  end

  if data.passthrough_rules ~= nil then
    table.insert(writes, {
      path = context.paths.passthrough_rules_path,
      content = rules.serialize_rules_file(data.passthrough_rules),
    })
  end

  for _, item in ipairs(writes) do
    local saved, save_error = context_helpers.write_atomic(context.env, item.path, item.content)
    if not saved then
      return false, save_error
    end
  end

  return true, nil
end

function M.persist(context, data)
  return M.persist_selected(context, {
    always_hosts = data.always_hosts,
    workday_hosts = data.workday_hosts,
    after_work_hosts = data.after_work_hosts,
    password_vault_hosts = data.password_vault_hosts,
    passthrough_rules = data.passthrough_rules,
  })
end

function M.load(context, parsed_config, options)
  options = options or {}

  local existing = read_lists(context)
  local have_all_lists = existing.passthrough_content ~= nil
  local have_no_lists = existing.passthrough_content == nil

  for _, definition in ipairs(schema.HOST_LISTS) do
    have_all_lists = have_all_lists and existing[definition.name .. "_content"] ~= nil
    have_no_lists = have_no_lists and existing[definition.name .. "_content"] == nil
  end

  if have_all_lists then
    return parse_existing_lists(existing, context.paths)
  end

  if options.allow_bootstrap and not options.installed and have_no_lists then
    local always_hosts, passthrough_rules = rules.partition_user_rules(parsed_config.rules)
    local bootstrapped = {
      always_hosts = always_hosts,
      workday_hosts = {},
      after_work_hosts = {},
      password_vault_hosts = {},
      passthrough_rules = passthrough_rules,
      bootstrapped = true,
    }

    local saved, save_error = M.persist(context, bootstrapped)
    if not saved then
      return nil, save_error
    end

    return bootstrapped, nil
  end

  if options.allow_bootstrap and not options.installed and not have_no_lists then
    local repaired = {
      passthrough_content = existing.passthrough_content or "",
    }

    for _, definition in ipairs(schema.HOST_LISTS) do
      repaired[definition.name .. "_content"] = existing[definition.name .. "_content"] or ""
    end

    local repaired_lists, repaired_error = parse_existing_lists(repaired, context.paths)
    if not repaired_lists then
      return nil, repaired_error
    end

    local saved, save_error = M.persist(context, repaired_lists)
    if not saved then
      return nil, save_error
    end

    return repaired_lists, nil
  end

  if have_no_lists and not options.installed then
    return M.empty_state(), nil
  end

  return nil, "QuietWrt canonical list state is incomplete. Missing: "
    .. table.concat(missing_list_paths(existing, context.paths), ", ")
end

function M.remove_bootstrapped_files(context)
  local errors = {}

  for _, path in ipairs({
    context.paths.always_list_path,
    context.paths.workday_list_path,
    context.paths.after_work_list_path,
    context.paths.password_vault_list_path,
    context.paths.passthrough_rules_path,
  }) do
    context.env.remove_file(path)
    if context.env.file_exists(path) then
      table.insert(errors, "Could not remove " .. path .. ".")
    end
  end

  if #errors > 0 then
    return false, table.concat(errors, " | ")
  end

  return true, nil
end

return M
