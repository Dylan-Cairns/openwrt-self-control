local M = {}

local appdata = (os.getenv("APPDATA") or ""):gsub("\\", "/")
local package_parts = {
  "app/?.lua",
  "app/?/init.lua",
  "tests/?.lua",
}

if appdata ~= "" then
  table.insert(package_parts, appdata .. "/luarocks/share/lua/5.3/?.lua")
end

table.insert(package_parts, package.path)
package.path = table.concat(package_parts, ";")

local sep = package.config:sub(1, 1)
local temp_counter = 0

local function shell_escape(path)
  if sep == "\\" then
    return '"' .. tostring(path):gsub('"', '""') .. '"'
  end
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function powershell_single_quote(path)
  return "'" .. tostring(path):gsub("'", "''") .. "'"
end

function M.join_path(...)
  local parts = { ... }
  return table.concat(parts, sep)
end

function M.create_dir(path)
  local command
  if sep == "\\" then
    command = "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path " .. powershell_single_quote(path) .. " | Out-Null\""
  else
    command = "mkdir -p " .. shell_escape(path)
  end
  local result = os.execute(command)
  return result == true or result == 0
end

function M.remove_tree(path)
  local command
  if sep == "\\" then
    command = "powershell -NoProfile -Command \"Remove-Item -Recurse -Force -LiteralPath " .. powershell_single_quote(path) .. " -ErrorAction SilentlyContinue\""
  else
    command = "rm -rf " .. shell_escape(path)
  end
  os.execute(command)
end

function M.make_temp_dir()
  local base = os.getenv("TEMP") or os.getenv("TMP") or "."
  temp_counter = temp_counter + 1
  local path = M.join_path(
    base,
    "quietwrt-tests-" .. tostring(os.time()) .. "-" .. tostring(temp_counter) .. "-" .. tostring(math.random(100000, 999999))
  )
  assert(M.create_dir(path), "failed to create temp dir " .. path)
  return path
end

function M.read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

function M.write_file(path, content)
  local handle = io.open(path, "wb")
  if not handle then
    return false
  end
  handle:write(content or "")
  handle:close()
  return true
end

function M.path_exists(path)
  local handle = io.open(path, "rb")
  if handle then
    handle:close()
    return true
  end
  return false
end

function M.make_context(overrides)
  overrides = overrides or {}

  local root = M.make_temp_dir()
  local data_dir = M.join_path(root, "quietwrt-data")
  local paths = {
    config_path = M.join_path(root, "AdGuardHome.yaml"),
    data_dir = data_dir,
    always_list_path = M.join_path(data_dir, "always-blocked.txt"),
    workday_list_path = M.join_path(data_dir, "workday-blocked.txt"),
    passthrough_rules_path = M.join_path(data_dir, "passthrough-rules.txt"),
    restart_adguard_command = "restart-adguard",
    crontab_path = M.join_path(root, "root.crontab"),
    quietwrtctl_path = "/usr/bin/quietwrtctl",
    cgi_path = M.join_path(root, "www", "cgi-bin", "quietwrt"),
    module_dir = M.join_path(root, "usr", "lib", "lua", "quietwrt"),
    init_service_path = M.join_path(root, "etc", "init.d", "quietwrt"),
    enable_init_service_command = "enable-init-service",
    disable_init_service_command = "disable-init-service",
    init_service_enabled_path = M.join_path(root, "etc", "rc.d", "S99quietwrt"),
    restart_cron_command = "restart-cron",
    restart_firewall_command = "restart-firewall",
  }

  assert(M.create_dir(data_dir), "failed to create fixture data dir " .. data_dir)
  assert(M.create_dir(M.join_path(root, "www", "cgi-bin")), "failed to create fixture cgi dir")
  assert(M.create_dir(M.join_path(root, "usr", "lib", "lua", "quietwrt")), "failed to create fixture module dir")
  assert(M.create_dir(M.join_path(root, "etc", "init.d")), "failed to create fixture init.d dir")
  assert(M.create_dir(M.join_path(root, "etc", "rc.d")), "failed to create fixture rc.d dir")

  local command_log = {}
  local execute = overrides.execute or function(log, command)
    table.insert(command_log, command)
    return 0
  end

  local capture_map = overrides.capture_map or {}
  local capture = overrides.capture or function(command)
    if capture_map[command] ~= nil then
      return capture_map[command]
    end
    return ""
  end

  local env = {
    read_file = M.read_file,
    write_file = M.write_file,
    rename_file = os.rename,
    remove_file = os.remove,
    file_exists = M.path_exists,
    ensure_dir = function(path)
      return M.create_dir(path)
    end,
    execute = function(command)
      return execute(command_log, command)
    end,
    capture = capture,
    now = overrides.now or function()
      return { hour = 10, min = 0 }
    end,
  }

  return {
    root = root,
    paths = paths,
    env = env,
    commands = command_log,
    cleanup = function()
      M.remove_tree(root)
    end,
  }
end

function M.write_config(path, user_rules, protection_enabled)
  local rules_text = {}
  for _, rule in ipairs(user_rules or {}) do
    table.insert(rules_text, "  - '" .. rule:gsub("'", "''") .. "'")
  end

  local content = {
    "protection_enabled: " .. ((protection_enabled == false) and "false" or "true"),
    "user_rules:",
  }

  for _, line in ipairs(rules_text) do
    table.insert(content, line)
  end

  if #rules_text == 0 then
    content[2] = "user_rules: []"
  end

  assert(M.write_file(path, table.concat(content, "\n") .. "\n"))
end

return M
