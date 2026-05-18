local util = require("quietwrt.util")

local M = {}
local unpack_values = table.unpack or unpack

local function default_ensure_dir(path)
  return util.command_succeeded(os.execute("mkdir -p " .. util.shell_quote(path)))
end

local function default_make_lock_dir(path)
  return util.command_succeeded(os.execute("mkdir " .. util.shell_quote(path) .. " >/dev/null 2>&1"))
end

local function default_remove_tree(path)
  return util.command_succeeded(os.execute("rm -rf " .. util.shell_quote(path) .. " >/dev/null 2>&1"))
end

local function default_pid()
  local handle = io.popen("echo ${PPID:-} 2>/dev/null", "r")
  if not handle then
    return ""
  end

  local output = handle:read("*a") or ""
  handle:close()
  return util.trim(output)
end

local function default_process_exists(pid)
  if not tostring(pid or ""):match("^%d+$") then
    return false
  end

  return util.command_succeeded(os.execute("kill -0 " .. tostring(pid) .. " >/dev/null 2>&1"))
end

local function default_sleep(seconds)
  seconds = tonumber(seconds) or 1
  if seconds <= 0 then
    return true
  end

  return util.command_succeeded(os.execute("sleep " .. tostring(seconds)))
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
    lock_dir = "/tmp/quietwrt.lock",
    failsafe_marker_path = data_dir .. "/failsafe-open.txt",
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
    make_lock_dir = default_make_lock_dir,
    remove_tree = default_remove_tree,
    file_exists = default_file_exists,
    pid = default_pid,
    process_exists = default_process_exists,
    sleep = default_sleep,
    time = os.time,
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
  local pid = ""
  if env.pid then
    pid = util.trim(env.pid() or "")
  end
  if pid == "" then
    pid = tostring((env.time or os.time)())
  end

  local temp_path = string.format(
    "%s.tmp.%s.%d",
    path,
    pid:gsub("[^%w_%-]", "_"),
    math.random(100000, 999999)
  )

  if not env.write_file(temp_path, content) then
    return false, "Could not write a temporary file for " .. path .. "."
  end

  if env.rename_file(temp_path, path) then
    return true, nil
  end

  env.remove_file(temp_path)
  return false, "Could not replace " .. path .. "."
end

function M.acquire_lock(context, options)
  options = options or {}
  local lock_dir = context.paths.lock_dir
  if lock_dir == nil or lock_dir == "" then
    return nil, "QuietWrt lock path is not configured."
  end

  local timeout_seconds = tonumber(options.timeout_seconds) or 30
  local wait_seconds = tonumber(options.wait_seconds) or 1
  local stale_seconds = tonumber(options.stale_seconds) or 300
  local started_at = context.env.time()

  while true do
    if context.env.make_lock_dir(lock_dir) then
      local pid = util.trim(context.env.pid() or "")
      context.env.write_file(lock_dir .. "/pid", pid .. "\n")
      context.env.write_file(lock_dir .. "/created_at", tostring(context.env.time()) .. "\n")
      return {
        path = lock_dir,
        released = false,
      }, nil
    end

    local now = context.env.time()
    local pid = util.trim(context.env.read_file(lock_dir .. "/pid") or "")
    local created_at = tonumber(util.trim(context.env.read_file(lock_dir .. "/created_at") or ""))
    local removed_stale = false

    if pid ~= "" and context.env.process_exists and not context.env.process_exists(pid) then
      context.env.remove_tree(lock_dir)
      removed_stale = true
    elseif created_at ~= nil and stale_seconds >= 0 and (now - created_at) > stale_seconds then
      context.env.remove_tree(lock_dir)
      removed_stale = true
    end

    if not removed_stale then
      if timeout_seconds <= 0 or (now - started_at) >= timeout_seconds then
        return nil, "QuietWrt is already applying another change."
      end

      context.env.sleep(wait_seconds)
    end
  end
end

function M.release_lock(context, lock)
  if lock == nil or lock.released then
    return true, nil
  end

  context.env.remove_tree(lock.path)
  lock.released = true
  return true, nil
end

local function pack_returns(...)
  return {
    n = select("#", ...),
    ...,
  }
end

function M.with_lock(context, callback, options)
  local lock, lock_error = M.acquire_lock(context, options)
  if not lock then
    return false, lock_error
  end

  local returns
  local ok, callback_error = xpcall(function()
    returns = pack_returns(callback())
  end, debug.traceback)

  M.release_lock(context, lock)

  if not ok then
    error(callback_error)
  end

  return unpack_values(returns, 1, returns.n)
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
