local util = require("quietwrt.util")

local M = {}

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

function M.default_paths()
  local data_dir = "/etc/quietwrt"
  return {
    config_path = "/etc/AdGuardHome/config.yaml",
    settings_config_path = "/etc/config/quietwrt",
    data_dir = data_dir,
    always_list_path = data_dir .. "/always-blocked.txt",
    workday_list_path = data_dir .. "/workday-blocked.txt",
    after_work_list_path = data_dir .. "/after-work-blocked.txt",
    password_vault_list_path = data_dir .. "/password-vault-blocked.txt",
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

function M.default_env(overrides)
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

function M.write_atomic(env, path, content)
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

function M.run_commands(env, commands)
  for _, command in ipairs(commands or {}) do
    if not util.command_succeeded(env.execute(command)) then
      return false, command
    end
  end

  return true, nil
end

function M.ensure_data_dir(env, paths)
  if env.ensure_dir(paths.data_dir) then
    return true, nil
  end

  return false, "Could not create " .. paths.data_dir .. "."
end

function M.new_context(options)
  options = options or {}
  return {
    env = M.default_env(options.env),
    paths = options.paths or M.default_paths(),
  }
end

return M
