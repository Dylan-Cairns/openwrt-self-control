local adguard = require("quietwrt.adguard")
local rules = require("quietwrt.rules")
local schedule = require("quietwrt.schedule")
local util = require("quietwrt.util")

local M = {}

local QUIETWRT_SCHEMA_VERSION = "2"
local MANAGED_FIREWALL_SECTIONS = {
  "quietwrt_dns_int",
  "quietwrt_dot_fwd",
  "quietwrt_curfew",
}

local HOST_LISTS = {
  { name = "always", key = "always_hosts", path_key = "always_list_path" },
  { name = "workday", key = "workday_hosts", path_key = "workday_list_path" },
  { name = "after_work", key = "after_work_hosts", path_key = "after_work_list_path" },
}

local SCHEDULES = {
  { name = "workday", start_key = "workday_start", end_key = "workday_end" },
  { name = "after_work", start_key = "after_work_start", end_key = "after_work_end" },
  { name = "overnight", start_key = "overnight_start", end_key = "overnight_end" },
}

local TOGGLES = {
  { name = "always", key = "always_enabled" },
  { name = "workday", key = "workday_enabled" },
  { name = "after_work", key = "after_work_enabled" },
  { name = "overnight", key = "overnight_enabled" },
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
    settings_config_path = "/etc/config/quietwrt",
    data_dir = data_dir,
    always_list_path = data_dir .. "/always-blocked.txt",
    workday_list_path = data_dir .. "/workday-blocked.txt",
    after_work_list_path = data_dir .. "/after-work-blocked.txt",
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
    restart_firewall_command = "/etc/init.d/firewall restart >/tmp/quietwrt-firewall-restart.log 2>&1",
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
    return "AdGuard Home protection is disabled in " .. paths.config_path
      .. ". QuietWrt cannot enforce blocklists until it is enabled."
  end

  return "Could not confirm that AdGuard Home protection is enabled in " .. paths.config_path
    .. ". QuietWrt fails closed until it is enabled."
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
    after_work_hosts = {},
    passthrough_rules = {},
    bootstrapped = false,
  }
end

local function clone_lists(lists)
  return {
    always_hosts = util.clone_array(lists.always_hosts),
    workday_hosts = util.clone_array(lists.workday_hosts),
    after_work_hosts = util.clone_array(lists.after_work_hosts),
    passthrough_rules = util.clone_array(lists.passthrough_rules),
  }
end

local function read_lists(env, paths)
  local existing = {
    passthrough_content = env.read_file(paths.passthrough_rules_path),
  }

  for _, definition in ipairs(HOST_LISTS) do
    existing[definition.name .. "_content"] = env.read_file(paths[definition.path_key])
  end

  return existing
end

local function persist_selected_lists(env, paths, data)
  local ok, err = ensure_data_dir(env, paths)
  if not ok then
    return false, err
  end

  local writes = {}
  for _, definition in ipairs(HOST_LISTS) do
    local hosts = data[definition.key]
    if hosts ~= nil then
      table.insert(writes, {
        path = paths[definition.path_key],
        content = rules.serialize_hosts_file(hosts),
      })
    end
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
    after_work_hosts = data.after_work_hosts,
    passthrough_rules = data.passthrough_rules,
  })
end

local function missing_list_paths(existing, paths)
  local missing = {}
  for _, definition in ipairs(HOST_LISTS) do
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

  for _, definition in ipairs(HOST_LISTS) do
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

local function read_install_state(env, paths)
  local schema_version = util.trim(env.capture("uci -q get quietwrt.settings.schema_version") or "")
  return {
    installed = schema_version == QUIETWRT_SCHEMA_VERSION,
    schema_version = schema_version ~= "" and schema_version or nil,
    settings_path_present = env.file_exists(paths.settings_config_path),
  }
end

local function load_lists(env, paths, parsed_config, options)
  options = options or {}

  local existing = read_lists(env, paths)
  local have_all_lists = existing.always_content ~= nil
    and existing.workday_content ~= nil
    and existing.after_work_content ~= nil
    and existing.passthrough_content ~= nil
  local have_no_lists = existing.always_content == nil
    and existing.workday_content == nil
    and existing.after_work_content == nil
    and existing.passthrough_content == nil

  if have_all_lists then
    return parse_existing_lists(existing, paths)
  end

  if options.allow_bootstrap and not options.installed and have_no_lists then
    local always_hosts, passthrough_rules = rules.partition_user_rules(parsed_config.rules)
    local bootstrapped = {
      always_hosts = always_hosts,
      workday_hosts = {},
      after_work_hosts = {},
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

local function read_required_bool(env, option_name)
  local raw = util.trim(env.capture("uci -q get quietwrt.settings." .. option_name) or "")
  if raw == "" then
    return nil, "Missing QuietWrt setting quietwrt.settings." .. option_name .. "."
  end

  local value = uci_to_bool(raw, nil)
  if value == nil then
    return nil, "Invalid QuietWrt setting quietwrt.settings." .. option_name .. "."
  end

  return value, nil
end

local function read_required_hhmm(env, option_name, label)
  local raw = util.trim(env.capture("uci -q get quietwrt.settings." .. option_name) or "")
  if raw == "" then
    return nil, "Missing QuietWrt setting quietwrt.settings." .. option_name .. "."
  end

  local normalized, err = schedule.normalize_hhmm(raw)
  if not normalized then
    return nil, label .. ": " .. err
  end

  return normalized, nil
end

local function read_settings(env, installed)
  if installed ~= true then
    return {
      always_enabled = false,
      workday_enabled = false,
      after_work_enabled = false,
      overnight_enabled = false,
      schema_version = nil,
    }, nil
  end

  local settings = {
    schema_version = QUIETWRT_SCHEMA_VERSION,
  }

  for _, toggle in ipairs(TOGGLES) do
    local value, err = read_required_bool(env, toggle.key)
    if value == nil then
      return nil, err
    end
    settings[toggle.key] = value
  end

  for _, definition in ipairs(SCHEDULES) do
    local start_value, start_error = read_required_hhmm(env, definition.start_key, schedule.window_label(definition.name) .. " start time")
    if start_value == nil then
      return nil, start_error
    end

    local end_value, end_error = read_required_hhmm(env, definition.end_key, schedule.window_label(definition.name) .. " end time")
    if end_value == nil then
      return nil, end_error
    end

    local window, window_error = schedule.build_window(definition.name, start_value, end_value)
    if not window then
      return nil, window_error
    end

    settings[definition.start_key] = window.start
    settings[definition.end_key] = window["end"]
  end

  return settings, nil
end

local function copy_settings(settings)
  local copied = {}
  for key, value in pairs(settings or {}) do
    copied[key] = value
  end
  return copied
end

local function default_install_settings()
  local defaults = schedule.default_windows()
  return {
    always_enabled = true,
    workday_enabled = true,
    after_work_enabled = true,
    overnight_enabled = false,
    workday_start = defaults.workday.start,
    workday_end = defaults.workday["end"],
    after_work_start = defaults.after_work.start,
    after_work_end = defaults.after_work["end"],
    overnight_start = defaults.overnight.start,
    overnight_end = defaults.overnight["end"],
    schema_version = QUIETWRT_SCHEMA_VERSION,
  }
end

local function write_settings(env, paths, settings, schema_version)
  if not env.file_exists(paths.settings_config_path) then
    local created = env.write_file(paths.settings_config_path, "")
    if not created then
      return false, "write " .. paths.settings_config_path
    end
  end

  local commands = {
    "uci -q delete quietwrt.settings >/dev/null 2>&1 || true",
    "uci set quietwrt.settings='settings'",
  }

  for _, toggle in ipairs(TOGGLES) do
    table.insert(commands, "uci set quietwrt.settings." .. toggle.key .. "='" .. bool_to_uci(settings[toggle.key]) .. "'")
  end

  for _, definition in ipairs(SCHEDULES) do
    table.insert(commands, "uci set quietwrt.settings." .. definition.start_key .. "='" .. tostring(settings[definition.start_key]) .. "'")
    table.insert(commands, "uci set quietwrt.settings." .. definition.end_key .. "='" .. tostring(settings[definition.end_key]) .. "'")
  end

  if schema_version ~= nil then
    table.insert(commands, "uci set quietwrt.settings.schema_version='" .. tostring(schema_version) .. "'")
  end

  table.insert(commands, "uci commit quietwrt")
  return run_commands(env, commands)
end

local function persist_settings(env, paths, settings)
  local ok, failed_command = write_settings(env, paths, settings, settings and settings.schema_version or nil)
  if ok then
    return true, settings
  end

  return false, "QuietWrt settings update failed while running: " .. failed_command
end

local function build_schedule_windows(settings)
  local windows = {}
  for _, definition in ipairs(SCHEDULES) do
    local window, err = schedule.build_window(
      definition.name,
      settings[definition.start_key],
      settings[definition.end_key]
    )
    if not window then
      return nil, err
    end
    windows[definition.name] = window
  end
  return windows, nil
end

local function build_runtime_activity(settings, now_table)
  local windows, err = build_schedule_windows(settings)
  if not windows then
    return nil, err
  end

  local workday_window_active = schedule.window_contains(windows.workday, now_table)
  local after_work_window_active = schedule.window_contains(windows.after_work, now_table)
  local overnight_window_active = schedule.window_contains(windows.overnight, now_table)

  return {
    schedule = windows,
    workday_window_active = workday_window_active,
    after_work_window_active = after_work_window_active,
    overnight_window_active = overnight_window_active,
    workday_active = settings.workday_enabled and workday_window_active,
    after_work_active = settings.after_work_enabled and after_work_window_active,
    overnight_active = settings.overnight_enabled and overnight_window_active,
  }, nil
end

local function build_active_hosts(lists, settings, activity)
  local always_hosts = {}
  if settings.always_enabled then
    always_hosts = lists.always_hosts
  end

  local scheduled_hosts = {}
  if activity.workday_active then
    for _, host in ipairs(lists.workday_hosts or {}) do
      table.insert(scheduled_hosts, host)
    end
  end

  if activity.after_work_active then
    for _, host in ipairs(lists.after_work_hosts or {}) do
      table.insert(scheduled_hosts, host)
    end
  end

  return always_hosts, util.sorted_unique(scheduled_hosts)
end

local function serialize_window(window)
  return {
    start = window.start,
    ["end"] = window["end"],
    display_start = window.display_start,
    display_end = window.display_end,
    overnight = window.overnight,
  }
end

local function serialize_schedule_windows(windows)
  return {
    workday = serialize_window(windows.workday),
    after_work = serialize_window(windows.after_work),
    overnight = serialize_window(windows.overnight),
  }
end

local function build_view_state(parsed_config, lists, settings, activity, hardening_state, installed, enforcement_ready)
  local active_always_hosts, active_scheduled_hosts = build_active_hosts(lists, settings, activity)
  local active_rules = rules.compile_active_rules(
    active_always_hosts,
    active_scheduled_hosts,
    lists.passthrough_rules
  )

  local protection_enabled = nil
  if parsed_config ~= nil then
    protection_enabled = parsed_config.protection_enabled
  end

  return {
    installed = installed,
    protection_enabled = protection_enabled,
    enforcement_ready = enforcement_ready,
    settings = settings,
    schedule = serialize_schedule_windows(activity.schedule),
    always_hosts = lists.always_hosts,
    workday_hosts = lists.workday_hosts,
    after_work_hosts = lists.after_work_hosts,
    passthrough_rules = lists.passthrough_rules,
    active_rules = active_rules,
    active_rule_count = #active_rules,
    workday_window_active = activity.workday_window_active,
    after_work_window_active = activity.after_work_window_active,
    overnight_window_active = activity.overnight_window_active,
    workday_active = activity.workday_active,
    after_work_active = activity.after_work_active,
    overnight_active = activity.overnight_active,
    hardening = hardening_state,
    warnings = {},
  }
end

local function format_router_time(now_table)
  local hour = tonumber(now_table and now_table.hour)
  local min = tonumber(now_table and now_table.min)

  if hour == nil or min == nil then
    return "Unknown"
  end

  return string.format("%02d:%02d", hour, min)
end

local function detect_installed(env, paths)
  return read_install_state(env, paths).installed
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
    table.insert(commands, "uci -q delete firewall." .. section_name .. " >/dev/null 2>&1 || true")
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

local function build_cron_block(paths, settings)
  local boundaries = {}
  local seen = {}

  for _, definition in ipairs(SCHEDULES) do
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

local function install_schedule(env, paths, settings)
  local cron_block, cron_error = build_cron_block(paths, settings)
  if not cron_block then
    return false, cron_error
  end

  local original = env.read_file(paths.crontab_path) or ""
  local without_existing = strip_cron_block(original)

  local updated
  if without_existing == "" then
    updated = cron_block
  else
    updated = without_existing .. "\n\n" .. cron_block
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
    paths.after_work_list_path,
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

  if rollback_state.original_settings ~= nil then
    local settings_ok, settings_error = persist_settings(context.env, context.paths, rollback_state.original_settings)
    if not settings_ok then
      table.insert(rollback_errors, settings_error)
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

local function uninstalled_snapshot(now_table)
  return {
    installed = false,
    protection_enabled = nil,
    enforcement_ready = false,
    settings = {
      always_enabled = false,
      workday_enabled = false,
      after_work_enabled = false,
      overnight_enabled = false,
    },
    schedule = {},
    always_hosts = {},
    workday_hosts = {},
    after_work_hosts = {},
    passthrough_rules = {},
    active_rules = {},
    active_rule_count = 0,
    workday_window_active = false,
    after_work_window_active = false,
    overnight_window_active = false,
    workday_active = false,
    after_work_active = false,
    overnight_active = false,
    hardening = {
      dns_intercept = false,
      dot_block = false,
      overnight_rule = false,
    },
    warnings = {},
    router_time = format_router_time(now_table),
  }
end

local function status_snapshot(context)
  local install_state = read_install_state(context.env, context.paths)
  local now_table = context.env.now()

  if not install_state.installed then
    return uninstalled_snapshot(now_table), nil
  end

  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return nil, config_error
  end

  local settings, settings_error = read_settings(context.env, true)
  if not settings then
    return nil, settings_error
  end

  local lists, list_error = load_lists(context.env, context.paths, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return nil, list_error
  end

  local activity, activity_error = build_runtime_activity(settings, now_table)
  if not activity then
    return nil, activity_error
  end

  local warnings = {}
  local enforcement_ready = is_enforcement_ready(context.paths, parsed_config)
  local enforcement_warning = enforcement_error(context.paths, parsed_config)
  if enforcement_warning then
    table.insert(warnings, enforcement_warning)
  end

  local hardening = hardening_status(context.env)
  local snapshot = build_view_state(
    parsed_config,
    lists,
    settings,
    activity,
    hardening,
    true,
    enforcement_ready
  )
  snapshot.router_time = format_router_time(now_table)
  snapshot.install_state = install_state
  snapshot.warnings = warnings
  return snapshot, nil
end

local function render_status_text(snapshot)
  local schedule_snapshot = snapshot.schedule or {}
  local lines = {
    "Installed: " .. (snapshot.installed and "yes" or "no"),
    "Router time: " .. (snapshot.router_time or "Unknown"),
    "Protection: " .. (
      snapshot.protection_enabled == true and "enabled"
      or snapshot.protection_enabled == false and "disabled"
      or "unknown"
    ),
    "Enforcement ready: " .. (snapshot.enforcement_ready and "yes" or "no"),
    "Always enabled: " .. (snapshot.settings.always_enabled and "yes" or "no"),
    "Workday enabled: " .. (snapshot.settings.workday_enabled and "yes" or "no"),
    "Workday active now: " .. (snapshot.workday_active and "yes" or "no"),
    "Workday window: " .. (
      schedule_snapshot.workday and (schedule_snapshot.workday.display_start .. " to "
        .. schedule_snapshot.workday.display_end
        .. (schedule_snapshot.workday.overnight and " (overnight)" or ""))
      or "unknown"
    ),
    "After work enabled: " .. (snapshot.settings.after_work_enabled and "yes" or "no"),
    "After work active now: " .. (snapshot.after_work_active and "yes" or "no"),
    "After work window: " .. (
      schedule_snapshot.after_work and (schedule_snapshot.after_work.display_start .. " to "
        .. schedule_snapshot.after_work.display_end
        .. (schedule_snapshot.after_work.overnight and " (overnight)" or ""))
      or "unknown"
    ),
    "Overnight enabled: " .. (snapshot.settings.overnight_enabled and "yes" or "no"),
    "Overnight active now: " .. (snapshot.overnight_active and "yes" or "no"),
    "Overnight window: " .. (
      schedule_snapshot.overnight and (schedule_snapshot.overnight.display_start .. " to "
        .. schedule_snapshot.overnight.display_end
        .. (schedule_snapshot.overnight.overnight and " (overnight)" or ""))
      or "unknown"
    ),
    "Always blocked: " .. tostring(#snapshot.always_hosts),
    "Workday blocked: " .. tostring(#snapshot.workday_hosts),
    "After work blocked: " .. tostring(#snapshot.after_work_hosts),
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
    router_time = snapshot.router_time,
    protection_enabled = snapshot.protection_enabled,
    enforcement_ready = snapshot.enforcement_ready,
    always_enabled = snapshot.settings.always_enabled,
    workday_enabled = snapshot.settings.workday_enabled,
    after_work_enabled = snapshot.settings.after_work_enabled,
    overnight_enabled = snapshot.settings.overnight_enabled,
    workday_window_active = snapshot.workday_window_active,
    after_work_window_active = snapshot.after_work_window_active,
    overnight_window_active = snapshot.overnight_window_active,
    workday_active = snapshot.workday_active,
    after_work_active = snapshot.after_work_active,
    overnight_active = snapshot.overnight_active,
    schedule = snapshot.schedule,
    always_count = #snapshot.always_hosts,
    workday_count = #snapshot.workday_hosts,
    after_work_count = #snapshot.after_work_hosts,
    active_rule_count = snapshot.active_rule_count,
    hardening = snapshot.hardening,
    warnings = snapshot.warnings,
  })
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
    local settings_error
    settings, settings_error = read_settings(context.env, true)
    if not settings then
      return false, settings_error
    end
  end

  local activity, activity_error = build_runtime_activity(settings, context.env.now())
  if not activity then
    return false, activity_error
  end

  local active_always_hosts, active_scheduled_hosts = build_active_hosts(lists, settings, activity)
  local compiled_rules = rules.compile_active_rules(
    active_always_hosts,
    active_scheduled_hosts,
    lists.passthrough_rules
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

  local curfew_enabled = activity.overnight_active
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
    settings = settings,
    activity = activity,
    active_rule_count = #compiled_rules,
    bootstrapped = lists.bootstrapped,
  }
end

local function apply_settings_change(context, next_settings)
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

  local current_settings, current_settings_error = read_settings(context.env, true)
  if not current_settings then
    return false, current_settings_error
  end

  local lists, list_error = load_lists(context.env, context.paths, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return false, list_error
  end

  local original_crontab = context.env.read_file(context.paths.crontab_path)
  next_settings = copy_settings(next_settings)
  next_settings.schema_version = QUIETWRT_SCHEMA_VERSION

  local schedule_ok, schedule_error = install_schedule(context.env, context.paths, next_settings)
  if not schedule_ok then
    return false, schedule_error
  end

  local applied, apply_result = apply_mode(context, {
    parsed_config = parsed_config,
    lists = lists,
    settings = next_settings,
  })
  if not applied then
    local rollback_errors = {}
    local restored_schedule, restored_schedule_error = restore_schedule(context.env, context.paths, original_crontab)
    if not restored_schedule then
      table.insert(rollback_errors, restored_schedule_error)
    end
    return false, append_rollback_errors(apply_result, rollback_errors)
  end

  local settings_ok, settings_result = persist_settings(context.env, context.paths, next_settings)
  if not settings_ok then
    local rollback_errors = {}

    local restored_schedule, restored_schedule_error = restore_schedule(context.env, context.paths, original_crontab)
    if not restored_schedule then
      table.insert(rollback_errors, restored_schedule_error)
    end

    local restored_settings_ok, restored_settings_error = persist_settings(context.env, context.paths, current_settings)
    if not restored_settings_ok then
      table.insert(rollback_errors, restored_settings_error)
    end

    local restored, restore_error = apply_mode(context, {
      parsed_config = parsed_config,
      lists = lists,
      settings = current_settings,
    })
    if not restored then
      table.insert(rollback_errors, restore_error)
    end

    return false, append_rollback_errors(settings_result, rollback_errors)
  end

  return true, {
    settings = settings_result,
    active_rule_count = apply_result.active_rule_count,
  }
end

function M.new_context(options)
  options = options or {}
  return {
    env = default_env(options.env),
    paths = options.paths or default_paths(),
  }
end

function M.load_view_state(context)
  local snapshot, err = status_snapshot(context)
  if not snapshot then
    return nil, err
  end

  if not snapshot.installed then
    return nil, "QuietWrt is not installed."
  end

  if #snapshot.warnings > 0 then
    return nil, snapshot.warnings[1]
  end

  return snapshot, nil
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

  local previous_lists = clone_lists(lists)
  local result = rules.apply_addition(
    lists.always_hosts,
    {
      workday = lists.workday_hosts,
      after_work = lists.after_work_hosts,
    },
    destination,
    raw_value
  )

  if not result.ok then
    return result
  end

  local saved, save_error = persist_lists(context.env, context.paths, {
    always_hosts = result.always_hosts,
    workday_hosts = result.workday_hosts,
    after_work_hosts = result.after_work_hosts,
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

  local staged_settings
  if install_state.installed then
    local settings_error
    staged_settings, settings_error = read_settings(context.env, true)
    if not staged_settings then
      return false, settings_error
    end
  else
    staged_settings = default_install_settings()
  end

  local original_settings = nil
  if install_state.installed then
    original_settings = copy_settings(staged_settings)
  end

  local rollback_state = {
    original_crontab = context.env.read_file(context.paths.crontab_path),
    boot_service_enabled = context.env.file_exists(context.paths.init_service_enabled_path),
    bootstrapped_lists = lists.bootstrapped == true,
    original_adguard_config = parsed_config.content,
    original_firewall = capture_firewall_snapshot(context.env),
    original_settings = original_settings,
    schedule_changed = true,
    boot_service_changed = false,
    applied = false,
  }

  local schedule_ok, schedule_error = install_schedule(context.env, context.paths, staged_settings)
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

  local settings_ok, settings_result = persist_settings(context.env, context.paths, staged_settings)
  if not settings_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(settings_result, rollback_errors)
  end

  return true, {
    settings = settings_result,
    active_rule_count = apply_result.active_rule_count,
    bootstrapped = lists.bootstrapped,
  }
end

function M.set_toggle(context, toggle_name, enabled)
  local settings, err = read_settings(context.env, detect_installed(context.env, context.paths))
  if not settings then
    return false, err
  end

  if toggle_name == "always" then
    settings.always_enabled = enabled
  elseif toggle_name == "workday" then
    settings.workday_enabled = enabled
  elseif toggle_name == "after_work" then
    settings.after_work_enabled = enabled
  elseif toggle_name == "overnight" then
    settings.overnight_enabled = enabled
  else
    return false, "Unknown toggle: " .. tostring(toggle_name)
  end

  return apply_settings_change(context, settings)
end

function M.set_schedule(context, schedule_name, start_value, end_value)
  local settings, err = read_settings(context.env, detect_installed(context.env, context.paths))
  if not settings then
    return false, err
  end

  local updated_window, window_error = schedule.build_window(schedule_name, start_value, end_value)
  if not updated_window then
    return false, window_error
  end

  if schedule_name == "workday" then
    settings.workday_start = updated_window.start
    settings.workday_end = updated_window["end"]
  elseif schedule_name == "after_work" then
    settings.after_work_start = updated_window.start
    settings.after_work_end = updated_window["end"]
  elseif schedule_name == "overnight" then
    settings.overnight_start = updated_window.start
    settings.overnight_end = updated_window["end"]
  else
    return false, "Unknown schedule: " .. tostring(schedule_name)
  end

  return apply_settings_change(context, settings)
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
  local selected_count = 0

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
    selected_count = selected_count + 1
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
    selected_count = selected_count + 1
  end

  if restore_paths.after_work_path then
    local after_work_content = context.env.read_file(restore_paths.after_work_path)
    if after_work_content == nil then
      return false, "Could not read " .. restore_paths.after_work_path .. "."
    end

    local after_work_hosts, after_work_error = rules.load_hosts_file(after_work_content, restore_paths.after_work_path)
    if not after_work_hosts then
      return false, after_work_error
    end

    replacements.after_work_hosts = after_work_hosts
    selected_count = selected_count + 1
  end

  if selected_count == 0 then
    return false, "Provide at least one restore file."
  end

  local previous_lists = clone_lists(current_lists)
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
    active_rule_count = apply_result.active_rule_count,
  }
end

function M.status(context, options)
  local snapshot, err = status_snapshot(context)
  if not snapshot then
    return false, err
  end

  if options and options.json then
    return true, render_status_json(snapshot)
  end
  return true, render_status_text(snapshot)
end

return M
