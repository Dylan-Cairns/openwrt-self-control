local context_helpers = require("quietwrt.context")
local schema = require("quietwrt.schema")
local util = require("quietwrt.util")

local M = {}

local function uci_unquote(value)
  local text = util.trim(value)
  if text:sub(1, 1) == "'" and text:sub(-1) == "'" then
    return (text:sub(2, -2):gsub("'\\''", "'"))
  end

  return text
end

local function capture_section(context, section_name)
  local output = context.env.capture("uci -q show firewall." .. section_name)
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

local function build_commands(snapshot, paths)
  local commands = {}

  for _, section_name in ipairs(schema.MANAGED_FIREWALL_SECTIONS) do
    table.insert(commands, "uci -q delete firewall." .. section_name .. " >/dev/null 2>&1 || true")
  end

  for _, section_name in ipairs(schema.MANAGED_FIREWALL_SECTIONS) do
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

function M.hardening_status(context)
  local dns_name = context.env.capture("uci -q get firewall.quietwrt_dns_int.name")
  local dot_name = context.env.capture("uci -q get firewall.quietwrt_dot_fwd.name")
  local overnight_name = context.env.capture("uci -q get firewall.quietwrt_curfew.name")

  return {
    dns_intercept = dns_name ~= nil and dns_name ~= "",
    dot_block = dot_name ~= nil and dot_name ~= "",
    overnight_rule = overnight_name ~= nil and overnight_name ~= "",
  }
end

function M.capture_snapshot(context)
  local snapshot = {}

  for _, section_name in ipairs(schema.MANAGED_FIREWALL_SECTIONS) do
    snapshot[section_name] = capture_section(context, section_name)
  end

  return snapshot
end

function M.desired_snapshot(curfew_enabled)
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

function M.snapshots_equal(left, right)
  return util.json_encode(left or {}) == util.json_encode(right or {})
end

function M.commit_snapshot(context, snapshot)
  local ok, failed_command = context_helpers.run_commands(context.env, build_commands(snapshot, context.paths))
  if ok then
    return true, nil
  end

  return false, "Firewall update failed while running: " .. failed_command
end

return M
