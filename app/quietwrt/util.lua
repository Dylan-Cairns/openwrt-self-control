local M = {}

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

return M
