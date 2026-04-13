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
local suite_state = nil

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
  return M.create_dirs({ path })
end

function M.create_dirs(paths)
  local normalized = {}
  for _, path in ipairs(paths or {}) do
    if path ~= nil and path ~= "" then
      table.insert(normalized, tostring(path))
    end
  end

  if #normalized == 0 then
    return true
  end

  local command
  if sep == "\\" then
    local quoted = {}
    for _, path in ipairs(normalized) do
      table.insert(quoted, powershell_single_quote(path))
    end
    command = "powershell -NoProfile -Command \"$paths = @(" .. table.concat(quoted, ", ") .. "); foreach ($path in $paths) { New-Item -ItemType Directory -Force -Path $path | Out-Null }\""
  else
    local quoted = {}
    for _, path in ipairs(normalized) do
      table.insert(quoted, shell_escape(path))
    end
    command = "mkdir -p " .. table.concat(quoted, " ")
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

function M.make_temp_path(prefix)
  local base = os.getenv("TEMP") or os.getenv("TMP") or "."
  temp_counter = temp_counter + 1
  return M.join_path(
    base,
    (prefix or "quietwrt-tests") .. "-" .. tostring(os.time()) .. "-" .. tostring(temp_counter) .. "-" .. tostring(math.random(100000, 999999))
  )
end

function M.make_temp_dir()
  local path = M.make_temp_path()
  assert(M.create_dir(path), "failed to create temp dir " .. path)
  return path
end

function M.begin_suite()
  if suite_state ~= nil then
    return suite_state.root
  end

  local root = M.make_temp_path()
  assert(M.create_dir(root), "failed to create suite temp dir " .. root)
  suite_state = {
    root = root,
    counter = 0,
  }

  return root
end

function M.end_suite()
  if suite_state == nil then
    return true
  end

  local root = suite_state.root
  suite_state = nil
  M.remove_tree(root)
  return true
end

local function allocate_fixture_root()
  if suite_state ~= nil then
    suite_state.counter = suite_state.counter + 1
    return M.join_path(suite_state.root, "case-" .. tostring(suite_state.counter)), false
  end

  return M.make_temp_path(), true
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

  local root, owns_cleanup = allocate_fixture_root()
  local data_dir = M.join_path(root, "quietwrt-data")
  local paths = {
    config_path = M.join_path(root, "AdGuardHome.yaml"),
    settings_config_path = M.join_path(root, "etc", "config", "quietwrt"),
    data_dir = data_dir,
    always_list_path = M.join_path(data_dir, "always-blocked.txt"),
    workday_list_path = M.join_path(data_dir, "workday-blocked.txt"),
    after_work_list_path = M.join_path(data_dir, "after-work-blocked.txt"),
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

  assert(M.create_dirs({
    root,
    data_dir,
    M.join_path(root, "www", "cgi-bin"),
    M.join_path(root, "usr", "lib", "lua", "quietwrt"),
    M.join_path(root, "etc", "config"),
    M.join_path(root, "etc", "init.d"),
    M.join_path(root, "etc", "rc.d"),
  }), "failed to create fixture directory tree for " .. root)

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
      if owns_cleanup then
        M.remove_tree(root)
      end
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
