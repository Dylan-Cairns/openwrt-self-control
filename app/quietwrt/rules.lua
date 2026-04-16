local util = require("quietwrt.util")

local M = {}

local DESTINATION_LABELS = {
  always = "Always blocked",
  workday = "Workday blocked",
  after_work = "After work blocked",
  password_vault = "Password vault blocked",
}

local SCHEDULED_DESTINATIONS = {
  "workday",
  "after_work",
  "password_vault",
}

local function format_source_line(source_name, line_number)
  local label = source_name or "input"
  return label .. " line " .. tostring(line_number)
end

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

local function destination_label(name)
  return DESTINATION_LABELS[name] or tostring(name or "destination")
end

local function clone_scheduled_lists(source)
  local cloned = {}
  for _, name in ipairs(SCHEDULED_DESTINATIONS) do
    cloned[name] = util.sorted_unique(source and source[name] or {})
  end
  return cloned
end

local function find_scheduled_destination(scheduled_lists, host)
  for _, name in ipairs(SCHEDULED_DESTINATIONS) do
    if util.contains(scheduled_lists[name], host) then
      return name
    end
  end
  return nil
end

local function build_result(ok, kind, message, host, always_hosts, scheduled_lists)
  return {
    ok = ok,
    kind = kind,
    message = message,
    host = host,
    always_hosts = always_hosts,
    workday_hosts = scheduled_lists.workday,
    after_work_hosts = scheduled_lists.after_work,
    password_vault_hosts = scheduled_lists.password_vault,
  }
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

function M.load_hosts_file(content, source_name)
  local hosts = {}

  for line_number, line in ipairs(util.split_lines(content)) do
    local text = util.trim(line)
    if text ~= "" and text:sub(1, 1) ~= "#" then
      local normalized, normalize_error = M.normalize_host_input(text)
      if not normalized then
        return nil, format_source_line(source_name, line_number) .. ": " .. normalize_error
      end

      if normalized ~= text then
        return nil, format_source_line(source_name, line_number) .. ": Use canonical lowercase hostnames only."
      end

      table.insert(hosts, normalized)
    end
  end

  return util.sorted_unique(hosts), nil
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

function M.load_rules_file(content, source_name)
  local parsed = {}

  for line_number, line in ipairs(util.split_lines(content)) do
    local text = util.trim(line)
    if text ~= "" then
      local kind = M.classify_rule(text)
      if kind == "block" then
        return nil, format_source_line(source_name, line_number)
          .. ": Block rules belong in the always/workday/after work/password vault lists, not passthrough rules."
      end

      table.insert(parsed, text)
    end
  end

  return util.stable_dedupe(parsed), nil
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

function M.compile_active_rules(always_hosts, scheduled_hosts, passthrough_rules)
  local active_hosts = util.clone_array(always_hosts or {})
  for _, host in ipairs(scheduled_hosts or {}) do
    table.insert(active_hosts, host)
  end

  active_hosts = util.sorted_unique(active_hosts)

  local compiled = util.stable_dedupe(passthrough_rules or {})
  for _, host in ipairs(active_hosts) do
    table.insert(compiled, M.block_rule_for_host(host))
  end

  return compiled
end

function M.apply_addition(always_hosts, scheduled_lists, destination, raw_value)
  local host, normalize_error = M.normalize_host_input(raw_value)
  if not host then
    return {
      ok = false,
      kind = "error",
      message = normalize_error,
    }
  end

  always_hosts = util.sorted_unique(always_hosts or {})
  scheduled_lists = clone_scheduled_lists(scheduled_lists)

  local in_always = util.contains(always_hosts, host)
  local current_scheduled_destination = find_scheduled_destination(scheduled_lists, host)

  if destination == "always" then
    if in_always then
      return build_result(false, "info", host .. " is already always blocked.", host, always_hosts, scheduled_lists)
    end

    table.insert(always_hosts, host)
    always_hosts = util.sorted_unique(always_hosts)

    if current_scheduled_destination ~= nil then
      scheduled_lists[current_scheduled_destination] = util.remove_value(scheduled_lists[current_scheduled_destination], host)
      scheduled_lists[current_scheduled_destination] = util.sorted_unique(scheduled_lists[current_scheduled_destination])
      return build_result(
        true,
        "success",
        "Moved " .. host .. " from " .. destination_label(current_scheduled_destination) .. " to Always blocked.",
        host,
        always_hosts,
        scheduled_lists
      )
    end

    return build_result(true, "success", "Added " .. host .. " to Always blocked.", host, always_hosts, scheduled_lists)
  end

  if DESTINATION_LABELS[destination] == nil or destination == "always" then
    return {
      ok = false,
      kind = "error",
      message = "Choose Always blocked, Workday blocked, After work blocked, or Password vault blocked.",
    }
  end

  if in_always then
    return build_result(
      false,
      "error",
      host .. " is already always blocked.",
      host,
      always_hosts,
      scheduled_lists
    )
  end

  if current_scheduled_destination == destination then
    return build_result(
      false,
      "info",
      host .. " is already " .. destination_label(destination):lower() .. ".",
      host,
      always_hosts,
      scheduled_lists
    )
  end

  if current_scheduled_destination ~= nil then
    scheduled_lists[current_scheduled_destination] = util.remove_value(scheduled_lists[current_scheduled_destination], host)
    scheduled_lists[current_scheduled_destination] = util.sorted_unique(scheduled_lists[current_scheduled_destination])
  end

  table.insert(scheduled_lists[destination], host)
  scheduled_lists[destination] = util.sorted_unique(scheduled_lists[destination])

  if current_scheduled_destination ~= nil then
    return build_result(
      true,
      "success",
      "Moved " .. host .. " from " .. destination_label(current_scheduled_destination) .. " to "
        .. destination_label(destination) .. ".",
      host,
      always_hosts,
      scheduled_lists
    )
  end

  return build_result(
    true,
    "success",
    "Added " .. host .. " to " .. destination_label(destination) .. ".",
    host,
    always_hosts,
    scheduled_lists
  )
end

return M
