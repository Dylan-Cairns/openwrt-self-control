local M = {}
local json_object_mt = {
  __json_object = true,
}

function M.trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.html_escape(value)
  local escaped = tostring(value or "")
  escaped = escaped:gsub("&", "&amp;")
  escaped = escaped:gsub("<", "&lt;")
  escaped = escaped:gsub(">", "&gt;")
  escaped = escaped:gsub('"', "&quot;")
  return escaped
end

function M.url_encode(value)
  return (tostring(value or ""):gsub("[^%w%-_%.~]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

function M.url_decode(value)
  value = tostring(value or ""):gsub("%+", " ")
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

function M.parse_form_encoded(value)
  local result = {}
  for pair in tostring(value or ""):gmatch("([^&]+)") do
    local key, raw = pair:match("^([^=]*)=(.*)$")
    if key == nil then
      key = pair
      raw = ""
    end
    result[M.url_decode(key)] = M.url_decode(raw)
  end
  return result
end

function M.split_lines(content)
  local normalized = tostring(content or ""):gsub("\r\n", "\n")
  if normalized == "" then
    return {}
  end

  if normalized:sub(-1) ~= "\n" then
    normalized = normalized .. "\n"
  end

  local lines = {}
  for line in normalized:gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return lines
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

function M.command_succeeded(result)
  return result == true or result == 0
end

function M.stable_dedupe(items)
  local seen = {}
  local result = {}

  for _, item in ipairs(items or {}) do
    local text = M.trim(item)
    if text ~= "" and not seen[text] then
      seen[text] = true
      table.insert(result, text)
    end
  end

  return result
end

function M.sorted_unique(items)
  local result = M.stable_dedupe(items)
  table.sort(result)
  return result
end

function M.clone_array(items)
  local result = {}
  for _, item in ipairs(items or {}) do
    table.insert(result, item)
  end
  return result
end

function M.contains(items, value)
  for _, item in ipairs(items or {}) do
    if item == value then
      return true
    end
  end
  return false
end

function M.remove_value(items, value)
  local result = {}
  for _, item in ipairs(items or {}) do
    if item ~= value then
      table.insert(result, item)
    end
  end
  return result
end

function M.shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function json_escape(value)
  local escaped = tostring(value or "")
  escaped = escaped:gsub("\\", "\\\\")
  escaped = escaped:gsub('"', '\\"')
  escaped = escaped:gsub("\b", "\\b")
  escaped = escaped:gsub("\f", "\\f")
  escaped = escaped:gsub("\n", "\\n")
  escaped = escaped:gsub("\r", "\\r")
  escaped = escaped:gsub("\t", "\\t")
  return escaped
end

local function is_array(value)
  if type(value) ~= "table" then
    return false
  end

  if getmetatable(value) == json_object_mt then
    return false
  end

  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
  end

  return count == #value
end

function M.json_object(value)
  return setmetatable(value or {}, json_object_mt)
end

function M.json_encode(value)
  local value_type = type(value)

  if value_type == "nil" then
    return "null"
  end

  if value_type == "boolean" then
    return value and "true" or "false"
  end

  if value_type == "number" then
    return tostring(value)
  end

  if value_type == "string" then
    return '"' .. json_escape(value) .. '"'
  end

  if value_type ~= "table" then
    error("Unsupported JSON value type: " .. value_type)
  end

  if is_array(value) then
    local items = {}
    for _, item in ipairs(value) do
      table.insert(items, M.json_encode(item))
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local keys = {}
  for key, _ in pairs(value) do
    table.insert(keys, key)
  end
  table.sort(keys)

  local parts = {}
  for _, key in ipairs(keys) do
    table.insert(parts, M.json_encode(tostring(key)) .. ":" .. M.json_encode(value[key]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

return M
