local adguard = require("quietwrt.adguard")
local rules = require("quietwrt.rules")
local schedule = require("quietwrt.schedule")
local util = require("quietwrt.util")

local M = {}

local function default_ensure_dir(path)
  return util.command_succeeded(os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'"))
end

local function default_paths()
  local data_dir = "/etc/quietwrt"
  return {
    config_path = "/etc/AdGuardHome/config.yaml",
    data_dir = data_dir,
    always_list_path = data_dir .. "/always-blocked.txt",
    workday_list_path = data_dir .. "/workday-blocked.txt",
    passthrough_rules_path = data_dir .. "/passthrough-rules.txt",
    restart_adguard_command = "/etc/init.d/adguardhome restart >/tmp/quietwrt-adguard-restart.log 2>&1",
    crontab_path = "/etc/crontabs/root",
    quietwrtctl_path = "/usr/bin/quietwrtctl",
    restart_cron_command = "/etc/init.d/cron restart >/tmp/quietwrt-cron-restart.log 2>&1",
  }
end

local function default_env(overrides)
  local env = {
    read_file = util.read_file,
    write_file = util.write_file,
    rename_file = os.rename,
    remove_file = os.remove,
    execute = os.execute,
    ensure_dir = default_ensure_dir,
    now = function()
      return os.date("*t")
    end,
  }

  for key, value in pairs(overrides or {}) do
    env[key] = value
  end

  return env
end

local function write_atomic(env, path, content)
  local temp_path = path .. ".tmp"
  if not env.write_file(temp_path, content) then
    return false, "Could not write a temporary file for " .. path .. "."
  end

  if env.rename_file(temp_path, path) then
    return true, nil
  end

  env.remove_file(path)
  if env.rename_file(temp_path, path) then
    return true, nil
  end

  env.remove_file(temp_path)
  return false, "Could not replace " .. path .. "."
end

local function ensure_data_dir(env, paths)
  if env.ensure_dir(paths.data_dir) then
    return true, nil
  end
  return false, "Could not create " .. paths.data_dir .. "."
end

local function read_adguard_state(env, paths)
  local content = env.read_file(paths.config_path)
  if not content then
    return nil, "Could not read " .. paths.config_path .. "."
  end

  local parsed = adguard.parse_config(content)
  parsed.content = content
  return parsed, nil
end

local function read_lists(env, paths)
  return {
    always_content = env.read_file(paths.always_list_path),
    workday_content = env.read_file(paths.workday_list_path),
    passthrough_content = env.read_file(paths.passthrough_rules_path),
  }
end

local function persist_lists(env, paths, data)
  local ok, err = ensure_data_dir(env, paths)
  if not ok then
    return false, err
  end

  local writes = {
    {
      path = paths.always_list_path,
      content = rules.serialize_hosts_file(data.always_hosts),
    },
    {
      path = paths.workday_list_path,
      content = rules.serialize_hosts_file(data.workday_hosts),
    },
    {
      path = paths.passthrough_rules_path,
      content = rules.serialize_rules_file(data.passthrough_rules),
    },
  }

  for _, item in ipairs(writes) do
    local saved, save_error = write_atomic(env, item.path, item.content)
    if not saved then
      return false, save_error
    end
  end

  return true, nil
end

local function load_lists(env, paths, parsed_config)
  local existing = read_lists(env, paths)
  local have_all_lists = existing.always_content ~= nil
    and existing.workday_content ~= nil
    and existing.passthrough_content ~= nil

  if have_all_lists then
    return {
      always_hosts = rules.parse_hosts_file(existing.always_content),
      workday_hosts = rules.parse_hosts_file(existing.workday_content),
      passthrough_rules = rules.parse_rules_file(existing.passthrough_content),
      bootstrapped = false,
    }, nil
  end

  local always_hosts, passthrough_rules = rules.partition_user_rules(parsed_config.rules)
  local bootstrapped = {
    always_hosts = always_hosts,
    workday_hosts = {},
    passthrough_rules = passthrough_rules,
    bootstrapped = true,
  }

  local saved, save_error = persist_lists(env, paths, bootstrapped)
  if not saved then
    return nil, save_error
  end

  return bootstrapped, nil
end

local function build_view_state(parsed_config, lists, current_mode)
  local active_rules = rules.compile_active_rules(
    lists.always_hosts,
    lists.workday_hosts,
    lists.passthrough_rules,
    current_mode
  )

  return {
    protection_enabled = parsed_config.protection_enabled,
    current_mode = current_mode,
    always_hosts = lists.always_hosts,
    workday_hosts = lists.workday_hosts,
    passthrough_rules = lists.passthrough_rules,
    active_rules = active_rules,
    active_rule_count = #active_rules,
  }
end

local function run_commands(env, commands)
  for _, command in ipairs(commands or {}) do
    if not util.command_succeeded(env.execute(command)) then
      return false, command
    end
  end
  return true, nil
end

local function apply_curfew_state(env, enabled)
  local value = enabled and "1" or "0"
  local commands = {
    "uci -q delete firewall.quietwrt_curfew",
    "uci set firewall.quietwrt_curfew='rule'",
    "uci set firewall.quietwrt_curfew.name='QuietWrt-Internet-Curfew'",
    "uci set firewall.quietwrt_curfew.family='ipv4'",
    "uci set firewall.quietwrt_curfew.src='lan'",
    "uci set firewall.quietwrt_curfew.dest='wan'",
    "uci set firewall.quietwrt_curfew.proto='all'",
    "uci set firewall.quietwrt_curfew.target='REJECT'",
    "uci set firewall.quietwrt_curfew.enabled='" .. value .. "'",
    "uci commit firewall",
    "service firewall restart >/tmp/quietwrt-firewall-restart.log 2>&1",
  }

  local ok, failed_command = run_commands(env, commands)
  if ok then
    return true, nil
  end

  return false, "Firewall update failed while running: " .. failed_command
end

local function build_cron_block(paths)
  return table.concat({
    "# BEGIN quietwrt schedule",
    "0 4 * * * " .. paths.quietwrtctl_path .. " sync",
    "30 16 * * * " .. paths.quietwrtctl_path .. " sync",
    "30 18 * * * " .. paths.quietwrtctl_path .. " sync",
    "# END quietwrt schedule",
    "",
  }, "\n")
end

local function install_schedule(env, paths)
  local original = env.read_file(paths.crontab_path) or ""
  local without_existing = original
    :gsub("\n?# BEGIN quietwrt schedule\n.-\n# END quietwrt schedule", "")
    :gsub("^# BEGIN quietwrt schedule\n.-\n# END quietwrt schedule\n?", "")

  without_existing = without_existing:gsub("%s+$", "")

  local updated
  if without_existing == "" then
    updated = build_cron_block(paths)
  else
    updated = without_existing .. "\n\n" .. build_cron_block(paths)
  end

  local saved, save_error = write_atomic(env, paths.crontab_path, updated)
  if not saved then
    return false, save_error
  end

  if util.command_succeeded(env.execute(paths.restart_cron_command)) then
    return true, nil
  end

  return false, "Cron restart failed after updating " .. paths.crontab_path .. "."
end

function M.new_context(options)
  options = options or {}
  return {
    env = default_env(options.env),
    paths = options.paths or default_paths(),
  }
end

function M.load_view_state(context)
  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return nil, config_error
  end

  local lists, list_error = load_lists(context.env, context.paths, parsed_config)
  if not lists then
    return nil, list_error
  end

  local current_mode = schedule.mode_at(context.env.now())
  local view_state = build_view_state(parsed_config, lists, current_mode)
  view_state.bootstrapped = lists.bootstrapped
  return view_state, nil
end

function M.apply_current_mode(context)
  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return false, config_error
  end

  local lists, list_error = load_lists(context.env, context.paths, parsed_config)
  if not lists then
    return false, list_error
  end

  local current_mode = schedule.mode_at(context.env.now())
  local compiled_rules = rules.compile_active_rules(
    lists.always_hosts,
    lists.workday_hosts,
    lists.passthrough_rules,
    current_mode
  )

  local updated_config = adguard.serialize_config(parsed_config, compiled_rules)
  local original_config = parsed_config.content

  if updated_config ~= original_config then
    local saved, save_error = write_atomic(context.env, context.paths.config_path, updated_config)
    if not saved then
      return false, save_error
    end

    if not util.command_succeeded(context.env.execute(context.paths.restart_adguard_command)) then
      write_atomic(context.env, context.paths.config_path, original_config)
      context.env.execute(context.paths.restart_adguard_command)
      return false, "AdGuard Home restart failed. The previous config was restored."
    end
  end

  local curfew_enabled = (current_mode.code == "internet_off")
  local firewall_ok, firewall_error = apply_curfew_state(context.env, curfew_enabled)
  if not firewall_ok then
    return false, firewall_error
  end

  return true, {
    mode = current_mode,
    active_rule_count = #compiled_rules,
    bootstrapped = lists.bootstrapped,
  }
end

function M.add_entry(context, destination, raw_value)
  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return {
      ok = false,
      kind = "error",
      message = config_error,
    }
  end

  local lists, list_error = load_lists(context.env, context.paths, parsed_config)
  if not lists then
    return {
      ok = false,
      kind = "error",
      message = list_error,
    }
  end

  local result = rules.apply_addition(
    lists.always_hosts,
    lists.workday_hosts,
    destination,
    raw_value
  )

  if not result.ok then
    return result
  end

  local saved, save_error = persist_lists(context.env, context.paths, {
    always_hosts = result.always_hosts,
    workday_hosts = result.workday_hosts,
    passthrough_rules = lists.passthrough_rules,
  })

  if not saved then
    return {
      ok = false,
      kind = "error",
      message = save_error,
    }
  end

  local applied, apply_result = M.apply_current_mode(context)
  if not applied then
    return {
      ok = false,
      kind = "error",
      message = apply_result,
    }
  end

  result.mode = apply_result.mode
  result.active_rule_count = apply_result.active_rule_count
  return result
end

function M.install(context)
  local view_state, load_error = M.load_view_state(context)
  if not view_state then
    return false, load_error
  end

  local schedule_ok, schedule_error = install_schedule(context.env, context.paths)
  if not schedule_ok then
    return false, schedule_error
  end

  local applied, apply_result = M.apply_current_mode(context)
  if not applied then
    return false, apply_result
  end

  return true, {
    mode = apply_result.mode,
    bootstrapped = view_state.bootstrapped,
  }
end

function M.status(context)
  local view_state, load_error = M.load_view_state(context)
  if not view_state then
    return false, load_error
  end

  local lines = {
    "Mode: " .. view_state.current_mode.label,
    "Protection: " .. (
      view_state.protection_enabled == true and "enabled"
      or view_state.protection_enabled == false and "disabled"
      or "unknown"
    ),
    "Always blocked: " .. tostring(#view_state.always_hosts),
    "Workday blocked: " .. tostring(#view_state.workday_hosts),
    "Active rules: " .. tostring(view_state.active_rule_count),
  }

  return true, table.concat(lines, "\n")
end

return M
