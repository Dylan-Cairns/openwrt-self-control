local util = require("quietwrt.util")

local M = {}

local function yaml_unquote(value)
  local text = util.trim(value)
  if text:sub(1, 1) == "'" and text:sub(-1) == "'" then
    return (text:sub(2, -2):gsub("''", "'"))
  end

  if text:sub(1, 1) == '"' and text:sub(-1) == '"' then
    text = text:sub(2, -2)
    text = text:gsub('\\"', '"')
    text = text:gsub("\\\\", "\\")
    return text
  end

  return text
end

local function yaml_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

function M.parse_config(content)
  local lines = util.split_lines(content)
  local rules = {}
  local protection_enabled = nil
  local user_rules_start = nil
  local user_rules_end = nil

  for i, line in ipairs(lines) do
    local enabled_value = line:match("^%s*protection_enabled:%s*(%S+)%s*$")
    if enabled_value ~= nil then
      protection_enabled = (enabled_value == "true")
    end

    if user_rules_start == nil and line:match("^user_rules:%s*$") then
      user_rules_start = i
      user_rules_end = #lines

      for j = i + 1, #lines do
        if lines[j]:match("^[^%s]") then
          user_rules_end = j - 1
          break
        end
      end

      for j = i + 1, user_rules_end do
        local item = lines[j]:match("^%s*-%s*(.-)%s*$")
        if item ~= nil and item ~= "" then
          table.insert(rules, yaml_unquote(item))
        end
      end
    end

    if user_rules_start == nil and line:match("^user_rules:%s*%[%s*%]%s*$") then
      user_rules_start = i
      user_rules_end = i
    end
  end

  return {
    lines = lines,
    rules = rules,
    protection_enabled = protection_enabled,
    user_rules_start = user_rules_start,
    user_rules_end = user_rules_end,
  }
end

function M.serialize_config(parsed, rules)
  local block = { "user_rules:" }
  for _, rule in ipairs(rules or {}) do
    table.insert(block, "  - " .. yaml_quote(rule))
  end

  local output = {}

  if parsed.user_rules_start then
    for i = 1, parsed.user_rules_start - 1 do
      table.insert(output, parsed.lines[i])
    end
    for _, line in ipairs(block) do
      table.insert(output, line)
    end
    for i = parsed.user_rules_end + 1, #parsed.lines do
      table.insert(output, parsed.lines[i])
    end
  else
    for _, line in ipairs(parsed.lines) do
      table.insert(output, line)
    end
    if output[#output] ~= "" then
      table.insert(output, "")
    end
    for _, line in ipairs(block) do
      table.insert(output, line)
    end
  end

  return table.concat(output, "\n") .. "\n"
end

return M
