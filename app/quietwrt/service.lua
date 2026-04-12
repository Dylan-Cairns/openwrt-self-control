local adguard = require("quietwrt.adguard")
local rules = require("quietwrt.rules")
local schedule = require("quietwrt.schedule")
local util = require("quietwrt.util")

local M = {}

local QUIETWRT_SCHEMA_VERSION = "1"
local MANAGED_FIREWALL_SECTIONS = {
  "quietwrt_dns_int",
  "quietwrt_dot_fwd",
  "quietwrt_curfew",
}

local function default_ensure_dir(path)
  return util.command_succeeded(os.execute("mkdir -p " .. util.shell_quote(path)))
end

local function default_capture(command)
  local handle = io.popen(command .. " 2>/dev/null", "r")
  if not handle then
    return nil
  end

  local output = handle:read("*a") or ""
  handle:close()
  return util.trim(output)
end

local function default_file_exists(path)
  local handle = io.open(path, "rb")
  if handle then
    handle:close()
    return true
  end
  return false
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
    cgi_path = "/www/cgi-bin/quietwrt",
    module_dir = "/usr/lib/lua/quietwrt",
    init_service_path = "/etc/init.d/quietwrt",
    enable_init_service_command = "/etc/init.d/quietwrt enable >/tmp/quietwrt-init-enable.log 2>&1",
    disable_init_service_command = "/etc/init.d/quietwrt disable >/tmp/quietwrt-init-disable.log 2>&1",
    init_service_enabled_path = "/etc/rc.d/S99quietwrt",
    restart_cron_command = "/etc/init.d/cron restart >/tmp/quietwrt-cron-restart.log 2>&1",
    restart_firewall_command = "service firewall restart >/tmp/quietwrt-firewall-restart.log 2>&1",
  }
end

local function default_env(overrides)
  local env = {
    read_file = util.read_file,
    write_file = util.write_file,
    rename_file = os.rename,
    remove_file = os.remove,
    execute = os.execute,
    capture = default_capture,
    ensure_dir = default_ensure_dir,
    file_exists = default_file_exists,
    now = function()
      return os.date("*t")
    end,
  }

  for key, value in pairs(overrides or {}) do
    env[key] = value
  end

  return env
end

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

local function uci_unquote(value)
  local text = util.trim(value)
  if text:sub(1, 1) == "'" and text:sub(-1) == "'" then
    return (text:sub(2, -2):gsub("'\\''", "'"))
  end
  return text
end

local function enforcement_error(paths, parsed_config)
  if parsed_config == nil then
    return "Could not read " .. paths.config_path .. "."
  end

  if parsed_config.protection_enabled == true then
    return nil
  end

  if parsed_config.protection_enabled == false then
    return "AdGuard Home protection is disabled in " .. paths.config_path .. ". QuietWrt cannot enforce blocklists until it is enabled."
  end

  return "Could not confirm that AdGuard Home protection is enabled in " .. paths.config_path .. ". QuietWrt fails closed until it is enabled."
end

local function is_enforcement_ready(paths, parsed_config)
  return enforcement_error(paths, parsed_config) == nil
end

local function require_enforcement_ready(paths, parsed_config)
  local err = enforcement_error(paths, parsed_config)
  if err then
    return false, err
  end
  return true, nil
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

local function run_commands(env, commands)
  for _, command in ipairs(commands or {}) do
    if not util.command_succeeded(env.execute(command)) then
      return false, command
    end
  end
  return true, nil
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

local function empty_lists_state()
  return {
    always_hosts = {},
    workday_hosts = {},
    passthrough_rules = {},
    bootstrapped = false,
  }
end

local function read_lists(env, paths)
  return {
    always_content = env.read_file(paths.always_list_path),
    workday_content = env.read_file(paths.workday_list_path),
    passthrough_content = env.read_file(paths.passthrough_rules_path),
  }
end

local function persist_selected_lists(env, paths, data)
  local ok, err = ensure_data_dir(env, paths)
  if not ok then
    return false, err
  end

  local writes = {}
  if data.always_hosts ~= nil then
    table.insert(writes, {
      path = paths.always_list_path,
      content = rules.serialize_hosts_file(data.always_hosts),
    })
  end

  if data.workday_hosts ~= nil then
    table.insert(writes, {
      path = paths.workday_list_path,
      content = rules.serialize_hosts_file(data.workday_hosts),
    })
  end

  if data.passthrough_rules ~= nil then
    table.insert(writes, {
      path = paths.passthrough_rules_path,
      content = rules.serialize_rules_file(data.passthrough_rules),
    })
  end

  for _, item in ipairs(writes) do
    local saved, save_error = write_atomic(env, item.path, item.content)
    if not saved then
      return false, save_error
    end
  end

  return true, nil
end

local function persist_lists(env, paths, data)
  return persist_selected_lists(env, paths, {
    always_hosts = data.always_hosts,
    workday_hosts = data.workday_hosts,
    passthrough_rules = data.passthrough_rules,
  })
end

local function missing_list_paths(existing, paths)
  local missing = {}
  if existing.always_content == nil then
    table.insert(missing, paths.always_list_path)
  end
  if existing.workday_content == nil then
    table.insert(missing, paths.workday_list_path)
  end
  if existing.passthrough_content == nil then
    table.insert(missing, paths.passthrough_rules_path)
  end
  return missing
end

local function parse_existing_lists(existing, paths)
  local always_hosts, always_error = rules.load_hosts_file(existing.always_content, paths.always_list_path)
  if not always_hosts then
    return nil, always_error
  end

  local workday_hosts, workday_error = rules.load_hosts_file(existing.workday_content, paths.workday_list_path)
  if not workday_hosts then
    return nil, workday_error
  end

  local passthrough_rules, passthrough_error = rules.load_rules_file(existing.passthrough_content, paths.passthrough_rules_path)
  if not passthrough_rules then
    return nil, passthrough_error
  end

  return {
    always_hosts = always_hosts,
    workday_hosts = workday_hosts,
    passthrough_rules = passthrough_rules,
    bootstrapped = false,
  }, nil
end

local function detect_legacy_install(env, paths)
  local setting_markers = {
    env.capture("uci -q get quietwrt.settings.always_enabled"),
    env.capture("uci -q get quietwrt.settings.workday_enabled"),
    env.capture("uci -q get quietwrt.settings.overnight_enabled"),
  }

  for _, marker in ipairs(setting_markers) do
    if util.trim(marker or "") ~= "" then
      return true
    end
  end

  return env.file_exists(paths.always_list_path)
    or env.file_exists(paths.workday_list_path)
    or env.file_exists(paths.passthrough_rules_path)
end

local function read_install_state(env, paths)
  local schema_version = util.trim(env.capture("uci -q get quietwrt.settings.schema_version") or "")
  local installed = schema_version == QUIETWRT_SCHEMA_VERSION
  local legacy = false

  if not installed and detect_legacy_install(env, paths) then
    installed = true
    legacy = true
  end

  return {
    installed = installed,
    legacy = legacy,
    schema_version = schema_version ~= "" and schema_version or nil,
  }
end

local function load_lists(env, paths, parsed_config, options)
  options = options or {}

  local existing = read_lists(env, paths)
  local have_all_lists = existing.always_content ~= nil
    and existing.workday_content ~= nil
    and existing.passthrough_content ~= nil
  local have_no_lists = existing.always_content == nil
    and existing.workday_content == nil
    and existing.passthrough_content == nil

  if have_all_lists then
    return parse_existing_lists(existing, paths)
  end

  if options.allow_bootstrap and not options.installed and have_no_lists then
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

  if have_no_lists and not options.installed then
    return empty_lists_state(), nil
  end

  return nil, "QuietWrt canonical list state is incomplete. Missing: " .. table.concat(missing_list_paths(existing, paths), ", ")
end

local function read_settings(env, fallback_enabled)
  local fallback = fallback_enabled == true
  return {
    always_enabled = uci_to_bool(env.capture("uci -q get quietwrt.settings.always_enabled"), fallback),
    workday_enabled = uci_to_bool(env.capture("uci -q get quietwrt.settings.workday_enabled"), fallback),
    overnight_enabled = uci_to_bool(env.capture("uci -q get quietwrt.settings.overnight_enabled"), fallback),
  }
end

local function write_settings(env, settings, schema_version)
  local commands = {
    "uci -q delete quietwrt.settings",
    "uci set quietwrt.settings='settings'",
    "uci set quietwrt.settings.always_enabled='" .. bool_to_uci(settings.always_enabled) .. "'",
    "uci set quietwrt.settings.workday_enabled='" .. bool_to_uci(settings.workday_enabled) .. "'",
    "uci set quietwrt.settings.overnight_enabled='" .. bool_to_uci(settings.overnight_enabled) .. "'",
  }

  if schema_version ~= nil then
    table.insert(commands, "uci set quietwrt.settings.schema_version='" .. tostring(schema_version) .. "'")
  end

  table.insert(commands, "uci commit quietwrt")
  return run_commands(env, commands)
end

local function resolve_settings(env, paths, settings, options)
  local current = read_settings(env, true)
  local install_state = read_install_state(env, paths)
  local desired = {
    always_enabled = settings and settings.always_enabled,
    workday_enabled = settings and settings.workday_enabled,
    overnight_enabled = settings and settings.overnight_enabled,
  }

  if desired.always_enabled == nil then
    desired.always_enabled = current.always_enabled
  end

  if desired.workday_enabled == nil then
    desired.workday_enabled = current.workday_enabled
  end

  if desired.overnight_enabled == nil then
    desired.overnight_enabled = current.overnight_enabled
  end

  local desired_schema_version = nil
  if options and options.schema_version ~= nil then
    desired_schema_version = options.schema_version
  elseif install_state.schema_version ~= nil then
    desired_schema_version = install_state.schema_version
  end

  desired.schema_version = desired_schema_version
  return desired
end

local function persist_settings(env, settings)
  local ok, failed_command = write_settings(env, settings, settings and settings.schema_version or nil)
  if ok then
    return true, settings
  end

  return false, "QuietWrt settings update failed while running: " .. failed_command
end

local function ensure_settings(env, paths, settings, options)
  local desired = resolve_settings(env, paths, settings, options)
  return persist_settings(env, desired)
end

local function build_active_hosts(lists, settings, scheduled_mode)
  local always_hosts = {}
  local workday_hosts = {}

  if settings.always_enabled then
    always_hosts = lists.always_hosts
  end

  if scheduled_mode.code == "always_and_workday" and settings.workday_enabled then
    workday_hosts = lists.workday_hosts
  end

  return always_hosts, workday_hosts
end

local function build_view_state(parsed_config, lists, settings, current_mode, scheduled_mode, hardening_state, installed, enforcement_ready)
  local active_always_hosts, active_workday_hosts = build_active_hosts(lists, settings, scheduled_mode)
  local active_rules = rules.compile_active_rules(
    active_always_hosts,
    active_workday_hosts,
    lists.passthrough_rules,
    { code = "always_and_workday" }
  )

  local protection_enabled = nil
  if parsed_config ~= nil then
    protection_enabled = parsed_config.protection_enabled
  end

  return {
    installed = installed,
    protection_enabled = protection_enabled,
    enforcement_ready = enforcement_ready,
    current_mode = current_mode,
    settings = settings,
    always_hosts = lists.always_hosts,
    workday_hosts = lists.workday_hosts,
    passthrough_rules = lists.passthrough_rules,
    active_rules = active_rules,
    active_rule_count = #active_rules,
    hardening = hardening_state,
    warnings = {},
  }
end

local function detect_installed(env, paths)
  return read_install_state(env, paths).installed
end

local function current_effective_mode(settings, now_table)
  local scheduled_mode = schedule.mode_at(now_table)

  if scheduled_mode.code == "internet_off" and not settings.overnight_enabled then
    return {
      code = "disabled_overnight",
      label = "Overnight block disabled",
      description = "Internet remains available because overnight blocking is disabled.",
    }, scheduled_mode
  end

  if scheduled_mode.code == "always_only" and not settings.always_enabled then
    return {
      code = "lists_disabled",
      label = "Lists disabled",
      description = "No blocklists are currently active.",
    }, scheduled_mode
  end

  if scheduled_mode.code == "always_and_workday" then
    if settings.always_enabled and settings.workday_enabled then
      return {
        code = "always_and_workday",
        label = "Always + Workday",
        description = "Both Always blocked and Workday blocked are active.",
      }, scheduled_mode
    end

    if settings.always_enabled then
      return {
        code = "always_only",
        label = "Always only",
        description = "Only the Always blocked list is active.",
      }, scheduled_mode
    end

    if settings.workday_enabled then
      return {
        code = "workday_only",
        label = "Workday only",
        description = "Only the Workday blocked list is active.",
      }, scheduled_mode
    end

    return {
      code = "lists_disabled",
      label = "Lists disabled",
      description = "No blocklists are currently active.",
    }, scheduled_mode
  end

  return scheduled_mode, scheduled_mode
end

local function hardening_status(env)
  local dns_name = env.capture("uci -q get firewall.quietwrt_dns_int.name")
  local dot_name = env.capture("uci -q get firewall.quietwrt_dot_fwd.name")
  local overnight_name = env.capture("uci -q get firewall.quietwrt_curfew.name")

  return {
    dns_intercept = dns_name ~= nil and dns_name ~= "",
    dot_block = dot_name ~= nil and dot_name ~= "",
    overnight_rule = overnight_name ~= nil and overnight_name ~= "",
  }
end

local function capture_firewall_section(env, section_name)
  local output = env.capture("uci -q show firewall." .. section_name)
  if output == nil or output == "" then
    return nil
  end

  local snapshot = {}
  for _, line in ipairs(util.split_lines(output)) do
    local section_type = line:match("^firewall%." .. section_name .. "=([^%s]+)$")
    if section_type then
      snapshot._type = uci_unquote(section_type)
    else
      local option_name, option_value = line:match("^firewall%." .. section_name .. "%.([%w_]+)=(.+)$")
      if option_name then
        snapshot[option_name] = uci_unquote(option_value)
      end
    end
  end

  if snapshot._type == nil then
    return nil
  end

  return snapshot
end

local function capture_firewall_snapshot(env)
  local snapshot = {}
  for _, section_name in ipairs(MANAGED_FIREWALL_SECTIONS) do
    snapshot[section_name] = capture_firewall_section(env, section_name)
  end
  return snapshot
end

local function desired_firewall_snapshot(curfew_enabled)
  local value = curfew_enabled and "1" or "0"
  return {
    quietwrt_dns_int = {
      _type = "redirect",
      family = "ipv4",
      name = "QuietWrt-Intercept-DNS",
      proto = "tcp udp",
      src = "lan",
      src_dport = "53",
      target = "DNAT",
    },
    quietwrt_dot_fwd = {
      _type = "rule",
      dest = "wan",
      dest_port = "853",
      family = "ipv4",
      name = "QuietWrt-Deny-DoT",
      proto = "tcp udp",
      src = "lan",
      target = "REJECT",
    },
    quietwrt_curfew = {
      _type = "rule",
      dest = "wan",
      enabled = value,
      family = "ipv4",
      name = "QuietWrt-Internet-Curfew",
      proto = "all",
      src = "lan",
      target = "REJECT",
    },
  }
end

local function firewall_snapshots_equal(left, right)
  return util.json_encode(left or {}) == util.json_encode(right or {})
end

local function build_firewall_commands(snapshot, paths)
  local commands = {}

  for _, section_name in ipairs(MANAGED_FIREWALL_SECTIONS) do
    table.insert(commands, "uci -q delete firewall." .. section_name)
  end

  for _, section_name in ipairs(MANAGED_FIREWALL_SECTIONS) do
    local section = snapshot[section_name]
    if section ~= nil then
      table.insert(commands, "uci set firewall." .. section_name .. "='" .. tostring(section._type) .. "'")

      local option_names = {}
      for option_name, _ in pairs(section) do
        if option_name ~= "_type" then
          table.insert(option_names, option_name)
        end
      end
      table.sort(option_names)

      for _, option_name in ipairs(option_names) do
        table.insert(
          commands,
          "uci set firewall." .. section_name .. "." .. option_name .. "='" .. tostring(section[option_name]) .. "'"
        )
      end
    end
  end

  table.insert(commands, "uci commit firewall")
  table.insert(commands, paths.restart_firewall_command)
  return commands
end

local function commit_firewall_snapshot(env, paths, snapshot)
  local ok, failed_command = run_commands(env, build_firewall_commands(snapshot, paths))
  if ok then
    return true, nil
  end

  return false, "Firewall update failed while running: " .. failed_command
end

local function build_cron_block(paths)
  return table.concat({
    "# BEGIN quietwrt schedule",
    "*/10 * * * * " .. paths.quietwrtctl_path .. " sync",
    "0 4 * * * " .. paths.quietwrtctl_path .. " sync",
    "30 16 * * * " .. paths.quietwrtctl_path .. " sync",
    "30 18 * * * " .. paths.quietwrtctl_path .. " sync",
    "# END quietwrt schedule",
    "",
  }, "\n")
end

local function strip_cron_block(original)
  return original
    :gsub("\n?# BEGIN quietwrt schedule\n.-\n# END quietwrt schedule", "")
    :gsub("^# BEGIN quietwrt schedule\n.-\n# END quietwrt schedule\n?", "")
    :gsub("%s+$", "")
end

local function install_schedule(env, paths)
  local original = env.read_file(paths.crontab_path) or ""
  local without_existing = strip_cron_block(original)

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

local function enable_boot_sync_service(env, paths)
  if util.command_succeeded(env.execute(paths.enable_init_service_command)) then
    return true, nil
  end

  return false, "Could not enable the QuietWrt boot sync service at " .. paths.init_service_path .. "."
end

local function restore_file(env, path, content)
  if content == nil then
    env.remove_file(path)
    if env.file_exists(path) then
      return false, "Could not remove " .. path .. "."
    end
    return true, nil
  end

  return write_atomic(env, path, content)
end

local function restore_schedule(env, paths, original_content)
  local saved, save_error = restore_file(env, paths.crontab_path, original_content)
  if not saved then
    return false, save_error
  end

  if util.command_succeeded(env.execute(paths.restart_cron_command)) then
    return true, nil
  end

  return false, "Cron restart failed while restoring " .. paths.crontab_path .. "."
end

local function restore_boot_sync_service(env, paths, was_enabled)
  local command = was_enabled and paths.enable_init_service_command or paths.disable_init_service_command
  if util.command_succeeded(env.execute(command)) then
    return true, nil
  end

  if was_enabled then
    return false, "Could not re-enable the QuietWrt boot sync service at " .. paths.init_service_path .. "."
  end

  return false, "Could not disable the QuietWrt boot sync service at " .. paths.init_service_path .. "."
end

local function remove_bootstrapped_lists(env, paths)
  local errors = {}
  for _, path in ipairs({
    paths.always_list_path,
    paths.workday_list_path,
    paths.passthrough_rules_path,
  }) do
    env.remove_file(path)
    if env.file_exists(path) then
      table.insert(errors, "Could not remove " .. path .. ".")
    end
  end

  if #errors > 0 then
    return false, table.concat(errors, " | ")
  end

  return true, nil
end

local function restore_adguard_config(env, paths, content)
  local saved, save_error = write_atomic(env, paths.config_path, content)
  if not saved then
    return false, save_error
  end

  if util.command_succeeded(env.execute(paths.restart_adguard_command)) then
    return true, nil
  end

  return false, "AdGuard Home restart failed while restoring the previous config."
end

local function apply_adguard_config(env, paths, original_config, updated_config)
  if updated_config == original_config then
    return true, nil, false
  end

  local saved, save_error = write_atomic(env, paths.config_path, updated_config)
  if not saved then
    return false, save_error, false
  end

  if util.command_succeeded(env.execute(paths.restart_adguard_command)) then
    return true, nil, true
  end

  local restore_ok, restore_error = restore_adguard_config(env, paths, original_config)
  if restore_ok then
    return false, "AdGuard Home restart failed. The previous config was restored.", false
  end

  return false, "AdGuard Home restart failed and the previous config could not be restored: " .. restore_error, false
end

local function restore_previous_lists(context, previous_lists)
  local rollback_errors = {}

  local saved, save_error = persist_lists(context.env, context.paths, previous_lists)
  if not saved then
    table.insert(rollback_errors, save_error)
    return rollback_errors
  end

  local restored, restore_error = M.apply_current_mode(context)
  if not restored then
    table.insert(rollback_errors, restore_error)
  end

  return rollback_errors
end

local function rollback_install(context, rollback_state)
  local rollback_errors = {}

  if rollback_state.applied then
    local restore_ok, restore_error = restore_adguard_config(
      context.env,
      context.paths,
      rollback_state.original_adguard_config
    )
    if not restore_ok then
      table.insert(rollback_errors, restore_error)
    end

    local firewall_ok, firewall_error = commit_firewall_snapshot(
      context.env,
      context.paths,
      rollback_state.original_firewall
    )
    if not firewall_ok then
      table.insert(rollback_errors, firewall_error)
    end
  end

  if rollback_state.schedule_changed then
    local schedule_ok, schedule_error = restore_schedule(
      context.env,
      context.paths,
      rollback_state.original_crontab
    )
    if not schedule_ok then
      table.insert(rollback_errors, schedule_error)
    end
  end

  if rollback_state.boot_service_changed then
    local boot_service_ok, boot_service_error = restore_boot_sync_service(
      context.env,
      context.paths,
      rollback_state.boot_service_enabled
    )
    if not boot_service_ok then
      table.insert(rollback_errors, boot_service_error)
    end
  end

  if rollback_state.bootstrapped_lists then
    local cleanup_ok, cleanup_error = remove_bootstrapped_lists(context.env, context.paths)
    if not cleanup_ok then
      table.insert(rollback_errors, cleanup_error)
    end
  end

  return rollback_errors
end

local function append_rollback_errors(message, rollback_errors)
  if rollback_errors == nil or #rollback_errors == 0 then
    return message
  end

  return message .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
end

local function status_snapshot(context)
  local install_state = read_install_state(context.env, context.paths)
  local installed = install_state.installed
  local settings = read_settings(context.env, installed)
  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  local lists = empty_lists_state()
  local warnings = {}
  local enforcement_ready = false

  if not parsed_config then
    table.insert(warnings, config_error)
  else
    enforcement_ready = is_enforcement_ready(context.paths, parsed_config)
    local enforcement_warning = enforcement_error(context.paths, parsed_config)
    if enforcement_warning then
      table.insert(warnings, enforcement_warning)
    end

    local loaded_lists, list_error = load_lists(context.env, context.paths, parsed_config, {
      installed = installed,
      allow_bootstrap = false,
    })
    if not loaded_lists then
      table.insert(warnings, list_error)
    else
      lists = loaded_lists
    end
  end

  local effective_mode, scheduled_mode = current_effective_mode(settings, context.env.now())
  local hardening = installed and hardening_status(context.env) or {
    dns_intercept = false,
    dot_block = false,
    overnight_rule = false,
  }
  local snapshot = build_view_state(
    parsed_config,
    lists,
    settings,
    effective_mode,
    scheduled_mode,
    hardening,
    installed,
    enforcement_ready
  )
  snapshot.install_state = install_state
  snapshot.scheduled_mode = scheduled_mode
  snapshot.warnings = warnings
  return snapshot
end

local function render_status_text(snapshot)
  local lines = {
    "Installed: " .. (snapshot.installed and "yes" or "no"),
    "Mode: " .. snapshot.current_mode.label,
    "Protection: " .. (
      snapshot.protection_enabled == true and "enabled"
      or snapshot.protection_enabled == false and "disabled"
      or "unknown"
    ),
    "Enforcement ready: " .. (snapshot.enforcement_ready and "yes" or "no"),
    "Always enabled: " .. (snapshot.settings.always_enabled and "yes" or "no"),
    "Workday enabled: " .. (snapshot.settings.workday_enabled and "yes" or "no"),
    "Overnight enabled: " .. (snapshot.settings.overnight_enabled and "yes" or "no"),
    "Always blocked: " .. tostring(#snapshot.always_hosts),
    "Workday blocked: " .. tostring(#snapshot.workday_hosts),
    "Active rules: " .. tostring(snapshot.active_rule_count),
    "DNS intercept hardening: " .. (snapshot.hardening.dns_intercept and "yes" or "no"),
    "DoT block hardening: " .. (snapshot.hardening.dot_block and "yes" or "no"),
    "Overnight rule present: " .. (snapshot.hardening.overnight_rule and "yes" or "no"),
  }

  if #snapshot.warnings > 0 then
    table.insert(lines, "Warnings: " .. table.concat(snapshot.warnings, " | "))
  end

  return table.concat(lines, "\n")
end

local function render_status_json(snapshot)
  return util.json_encode({
    installed = snapshot.installed,
    mode = snapshot.current_mode.code,
    mode_label = snapshot.current_mode.label,
    scheduled_mode = snapshot.scheduled_mode.code,
    protection_enabled = snapshot.protection_enabled,
    enforcement_ready = snapshot.enforcement_ready,
    always_enabled = snapshot.settings.always_enabled,
    workday_enabled = snapshot.settings.workday_enabled,
    overnight_enabled = snapshot.settings.overnight_enabled,
    always_count = #snapshot.always_hosts,
    workday_count = #snapshot.workday_hosts,
    active_rule_count = snapshot.active_rule_count,
    hardening = snapshot.hardening,
    warnings = snapshot.warnings,
  })
end

function M.new_context(options)
  options = options or {}
  return {
    env = default_env(options.env),
    paths = options.paths or default_paths(),
  }
end

function M.load_view_state(context)
  local snapshot = status_snapshot(context)
  if not snapshot.installed then
    return nil, "QuietWrt is not installed."
  end

  if #snapshot.warnings > 0 then
    return nil, snapshot.warnings[1]
  end

  return snapshot, nil
end

local function apply_mode(context, options)
  options = options or {}

  if options.require_installed ~= false and not detect_installed(context.env, context.paths) then
    return false, "QuietWrt is not installed."
  end

  local parsed_config = options.parsed_config
  if not parsed_config then
    local config_error
    parsed_config, config_error = read_adguard_state(context.env, context.paths)
    if not parsed_config then
      return false, config_error
    end
  end

  local enforcement_ok, enforcement_check_error = require_enforcement_ready(context.paths, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local lists = options.lists
  if not lists then
    local installed = options.installed
    if installed == nil then
      installed = true
    end

    local allow_bootstrap = options.allow_bootstrap == true
    local list_error
    lists, list_error = load_lists(context.env, context.paths, parsed_config, {
      installed = installed,
      allow_bootstrap = allow_bootstrap,
    })
    if not lists then
      return false, list_error
    end
  end

  local settings = options.settings
  if settings == nil then
    settings = read_settings(context.env, true)
  end

  local effective_mode, scheduled_mode = current_effective_mode(settings, context.env.now())
  local active_always_hosts, active_workday_hosts = build_active_hosts(lists, settings, scheduled_mode)
  local compiled_rules = rules.compile_active_rules(
    active_always_hosts,
    active_workday_hosts,
    lists.passthrough_rules,
    { code = "always_and_workday" }
  )

  local updated_config = adguard.serialize_config(parsed_config, compiled_rules)
  local original_config = parsed_config.content
  local adguard_ok, adguard_error, adguard_changed = apply_adguard_config(
    context.env,
    context.paths,
    original_config,
    updated_config
  )
  if not adguard_ok then
    return false, adguard_error
  end

  local curfew_enabled = scheduled_mode.code == "internet_off" and settings.overnight_enabled
  local previous_firewall = capture_firewall_snapshot(context.env)
  local desired_firewall = desired_firewall_snapshot(curfew_enabled)
  if not firewall_snapshots_equal(previous_firewall, desired_firewall) then
    local firewall_ok, firewall_error = commit_firewall_snapshot(context.env, context.paths, desired_firewall)
    if not firewall_ok then
      local rollback_errors = {}

      if adguard_changed then
        local restore_ok, restore_error = restore_adguard_config(context.env, context.paths, original_config)
        if not restore_ok then
          table.insert(rollback_errors, restore_error)
        end
      end

      local firewall_restore_ok, firewall_restore_error = commit_firewall_snapshot(context.env, context.paths, previous_firewall)
      if not firewall_restore_ok then
        table.insert(rollback_errors, firewall_restore_error)
      end

      if #rollback_errors == 0 then
        return false, firewall_error .. " Previous state was restored."
      end

      return false, firewall_error .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
    end
  end

  return true, {
    mode = effective_mode,
    scheduled_mode = scheduled_mode,
    active_rule_count = #compiled_rules,
    bootstrapped = lists.bootstrapped,
  }
end

function M.apply_current_mode(context)
  return apply_mode(context, {
    require_installed = true,
  })
end

function M.add_entry(context, destination, raw_value)
  if not detect_installed(context.env, context.paths) then
    return {
      ok = false,
      kind = "error",
      message = "QuietWrt is not installed.",
    }
  end

  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return {
      ok = false,
      kind = "error",
      message = config_error,
    }
  end

  local enforcement_ok, enforcement_check_error = require_enforcement_ready(context.paths, parsed_config)
  if not enforcement_ok then
    return {
      ok = false,
      kind = "error",
      message = enforcement_check_error,
    }
  end

  local lists, list_error = load_lists(context.env, context.paths, parsed_config, {
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

  local previous_lists = {
    always_hosts = util.clone_array(lists.always_hosts),
    workday_hosts = util.clone_array(lists.workday_hosts),
    passthrough_rules = util.clone_array(lists.passthrough_rules),
  }

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

  result.mode = apply_result.mode
  result.active_rule_count = apply_result.active_rule_count
  return result
end

function M.install(context)
  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return false, config_error
  end

  local enforcement_ok, enforcement_check_error = require_enforcement_ready(context.paths, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local install_state = read_install_state(context.env, context.paths)
  local lists, list_error = load_lists(context.env, context.paths, parsed_config, {
    installed = install_state.installed,
    allow_bootstrap = not install_state.installed,
  })
  if not lists then
    return false, list_error
  end

  local desired_settings_input = install_state.installed and {} or {
    always_enabled = true,
    workday_enabled = true,
    overnight_enabled = true,
  }
  local staged_settings = resolve_settings(context.env, context.paths, desired_settings_input, {
    schema_version = QUIETWRT_SCHEMA_VERSION,
  })

  local rollback_state = {
    original_crontab = context.env.read_file(context.paths.crontab_path),
    boot_service_enabled = context.env.file_exists(context.paths.init_service_enabled_path),
    bootstrapped_lists = lists.bootstrapped == true,
    original_adguard_config = parsed_config.content,
    original_firewall = capture_firewall_snapshot(context.env),
    schedule_changed = true,
    boot_service_changed = false,
    applied = false,
  }

  local schedule_ok, schedule_error = install_schedule(context.env, context.paths)
  if not schedule_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(schedule_error, rollback_errors)
  end

  local boot_service_ok, boot_service_error = enable_boot_sync_service(context.env, context.paths)
  if not boot_service_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(boot_service_error, rollback_errors)
  end
  rollback_state.boot_service_changed = true

  local applied, apply_result = apply_mode(context, {
    require_installed = false,
    parsed_config = parsed_config,
    lists = lists,
    settings = staged_settings,
  })
  if not applied then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(apply_result, rollback_errors)
  end
  rollback_state.applied = true

  local settings_ok, settings_result = persist_settings(context.env, staged_settings)
  if not settings_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(settings_result, rollback_errors)
  end

  return true, {
    mode = apply_result.mode,
    settings = settings_result,
    active_rule_count = apply_result.active_rule_count,
    bootstrapped = lists.bootstrapped,
  }
end

function M.set_toggle(context, toggle_name, enabled)
  if not detect_installed(context.env, context.paths) then
    return false, "QuietWrt is not installed."
  end

  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return false, config_error
  end

  local enforcement_ok, enforcement_check_error = require_enforcement_ready(context.paths, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local settings = read_settings(context.env, true)

  if toggle_name == "always" then
    settings.always_enabled = enabled
  elseif toggle_name == "workday" then
    settings.workday_enabled = enabled
  elseif toggle_name == "overnight" then
    settings.overnight_enabled = enabled
  else
    return false, "Unknown toggle: " .. tostring(toggle_name)
  end

  local settings_ok, settings_error = ensure_settings(context.env, context.paths, settings)
  if not settings_ok then
    return false, settings_error
  end

  local applied, apply_result = M.apply_current_mode(context)
  if not applied then
    return false, apply_result
  end

  return true, {
    mode = apply_result.mode,
    settings = settings,
    active_rule_count = apply_result.active_rule_count,
  }
end

function M.restore_lists(context, restore_paths)
  if not detect_installed(context.env, context.paths) then
    return false, "QuietWrt is not installed."
  end

  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return false, config_error
  end

  local enforcement_ok, enforcement_check_error = require_enforcement_ready(context.paths, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local current_lists, list_error = load_lists(context.env, context.paths, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not current_lists then
    return false, list_error
  end

  local replacements = {}
  if restore_paths.always_path then
    local always_content = context.env.read_file(restore_paths.always_path)
    if always_content == nil then
      return false, "Could not read " .. restore_paths.always_path .. "."
    end

    local always_hosts, always_error = rules.load_hosts_file(always_content, restore_paths.always_path)
    if not always_hosts then
      return false, always_error
    end

    replacements.always_hosts = always_hosts
  end

  if restore_paths.workday_path then
    local workday_content = context.env.read_file(restore_paths.workday_path)
    if workday_content == nil then
      return false, "Could not read " .. restore_paths.workday_path .. "."
    end

    local workday_hosts, workday_error = rules.load_hosts_file(workday_content, restore_paths.workday_path)
    if not workday_hosts then
      return false, workday_error
    end

    replacements.workday_hosts = workday_hosts
  end

  if replacements.always_hosts == nil and replacements.workday_hosts == nil then
    return false, "Provide at least one restore file."
  end

  local previous_lists = {
    always_hosts = util.clone_array(current_lists.always_hosts),
    workday_hosts = util.clone_array(current_lists.workday_hosts),
    passthrough_rules = util.clone_array(current_lists.passthrough_rules),
  }

  local saved, save_error = persist_selected_lists(context.env, context.paths, replacements)
  if not saved then
    return false, save_error
  end

  local applied, apply_result = M.apply_current_mode(context)
  if not applied then
    local rollback_errors = restore_previous_lists(context, previous_lists)
    if #rollback_errors == 0 then
      return false, apply_result
    end
    return false, apply_result .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
  end

  return true, {
    mode = apply_result.mode,
    active_rule_count = apply_result.active_rule_count,
  }
end

function M.status(context, options)
  local snapshot = status_snapshot(context)
  if options and options.json then
    return true, render_status_json(snapshot)
  end
  return true, render_status_text(snapshot)
end

return M
