local util = require("quietwrt.util")

local M = {}

local function is_ipv4(value)
  local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return false
  end

  a = tonumber(a)
  b = tonumber(b)
  c = tonumber(c)
  d = tonumber(d)

  return a <= 255 and b <= 255 and c <= 255 and d <= 255
end

local function is_valid_host(host)
  if type(host) ~= "string" or host == "" or #host > 253 or not host:find(".", 1, true) then
    return false
  end

  if host:sub(1, 1) == "." or host:sub(-1) == "." then
    return false
  end

  if host:find("..", 1, true) then
    return false
  end

  if not host:match("^[a-z0-9%.%-]+$") then
    return false
  end

  local label_count = 0
  for label in host:gmatch("([^.]+)") do
    label_count = label_count + 1
    if #label > 63 then
      return false
    end

    if label:match("^%-") or label:match("%-$") then
      return false
    end
  end

  return label_count >= 2
end

function M.normalize_host_input(value)
  local candidate = util.trim(value):lower()
  if candidate == "" then
    return nil, "Enter a domain, hostname, or full URL."
  end

  candidate = candidate:gsub("^[a-z][a-z0-9+.-]*://", "")
  candidate = candidate:gsub("^//", "")
  candidate = candidate:match("^([^/%?#]+)") or candidate
  candidate = candidate:gsub("^.-@", "")
  candidate = candidate:gsub(":%d+$", "")
  candidate = candidate:gsub("%.$", "")

  if candidate:find("[%*|%^%s]") then
    return nil, "Only plain domains and URLs are supported."
  end

  if is_ipv4(candidate) then
    return nil, "IP addresses are not supported here."
  end

  if not is_valid_host(candidate) then
    return nil, "That does not look like a valid hostname."
  end

  return candidate, nil
end

function M.classify_rule(rule)
  local text = util.trim(rule)
  if text == "" or text:sub(1, 1) == "#" or text:sub(1, 1) == "!" then
    return nil, nil
  end

  local allow = false
  if text:sub(1, 2) == "@@" then
    allow = true
    text = text:sub(3)
  end

  local extracted = text:match("^%|%|([^%^/$]+)%^")
  if not extracted then
    extracted = text:match("^([^/%s]+)$")
  end

  if not extracted then
    return nil, nil
  end

  local normalized = M.normalize_host_input(extracted)
  if not normalized then
    return nil, nil
  end

  if allow then
    return "allow", normalized
  end

  return "block", normalized
end

function M.classify_rule_for_host(rule, host)
  local kind, extracted_host = M.classify_rule(rule)
  if extracted_host ~= host then
    return nil
  end
  return kind
end

function M.block_rule_for_host(host)
  return "||" .. host .. "^"
end

function M.parse_hosts_file(content)
  local hosts = {}
  for _, line in ipairs(util.split_lines(content)) do
    local text = util.trim(line)
    if text ~= "" and text:sub(1, 1) ~= "#" then
      table.insert(hosts, text)
    end
  end
  return util.sorted_unique(hosts)
end

function M.serialize_hosts_file(hosts)
  local normalized = util.sorted_unique(hosts)
  if #normalized == 0 then
    return ""
  end
  return table.concat(normalized, "\n") .. "\n"
end

function M.parse_rules_file(content)
  return util.stable_dedupe(util.split_lines(content))
end

function M.serialize_rules_file(lines)
  local normalized = util.stable_dedupe(lines)
  if #normalized == 0 then
    return ""
  end
  return table.concat(normalized, "\n") .. "\n"
end

function M.partition_user_rules(rules)
  local always_hosts = {}
  local passthrough_rules = {}

  for _, rule in ipairs(rules or {}) do
    local kind, host = M.classify_rule(rule)
    if kind == "block" and host then
      table.insert(always_hosts, host)
    else
      table.insert(passthrough_rules, util.trim(rule))
    end
  end

  return util.sorted_unique(always_hosts), util.stable_dedupe(passthrough_rules)
end

function M.compile_active_rules(always_hosts, workday_hosts, passthrough_rules, mode)
  local active_hosts = util.clone_array(always_hosts or {})
  if mode and mode.code == "always_and_workday" then
    for _, host in ipairs(workday_hosts or {}) do
      table.insert(active_hosts, host)
    end
  end

  active_hosts = util.sorted_unique(active_hosts)

  local compiled = util.stable_dedupe(passthrough_rules or {})
  for _, host in ipairs(active_hosts) do
    table.insert(compiled, M.block_rule_for_host(host))
  end

  return compiled
end

function M.apply_addition(always_hosts, workday_hosts, destination, raw_value)
  local host, normalize_error = M.normalize_host_input(raw_value)
  if not host then
    return {
      ok = false,
      kind = "error",
      message = normalize_error,
    }
  end

  always_hosts = util.sorted_unique(always_hosts or {})
  workday_hosts = util.sorted_unique(workday_hosts or {})

  local in_always = util.contains(always_hosts, host)
  local in_workday = util.contains(workday_hosts, host)

  if destination == "always" then
    if in_always then
      return {
        ok = false,
        kind = "info",
        message = host .. " is already always blocked.",
        host = host,
        always_hosts = always_hosts,
        workday_hosts = workday_hosts,
      }
    end

    table.insert(always_hosts, host)
    always_hosts = util.sorted_unique(always_hosts)

    if in_workday then
      workday_hosts = util.remove_value(workday_hosts, host)
      workday_hosts = util.sorted_unique(workday_hosts)
      return {
        ok = true,
        kind = "success",
        message = "Moved " .. host .. " from Workday blocked to Always blocked.",
        host = host,
        always_hosts = always_hosts,
        workday_hosts = workday_hosts,
      }
    end

    return {
      ok = true,
      kind = "success",
      message = "Added " .. host .. " to Always blocked.",
      host = host,
      always_hosts = always_hosts,
      workday_hosts = workday_hosts,
    }
  end

  if destination ~= "workday" then
    return {
      ok = false,
      kind = "error",
      message = "Choose either Always blocked or Workday blocked.",
    }
  end

  if in_always then
    return {
      ok = false,
      kind = "error",
      message = host .. " is already always blocked.",
      host = host,
      always_hosts = always_hosts,
      workday_hosts = workday_hosts,
    }
  end

  if in_workday then
    return {
      ok = false,
      kind = "info",
      message = host .. " is already workday blocked.",
      host = host,
      always_hosts = always_hosts,
      workday_hosts = workday_hosts,
    }
  end

  table.insert(workday_hosts, host)
  workday_hosts = util.sorted_unique(workday_hosts)

  return {
    ok = true,
    kind = "success",
    message = "Added " .. host .. " to Workday blocked.",
    host = host,
    always_hosts = always_hosts,
    workday_hosts = workday_hosts,
  }
end

return M
