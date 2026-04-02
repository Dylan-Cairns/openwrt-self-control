#!/usr/bin/lua

local CONFIG_PATH = "/etc/AdGuardHome/config.yaml"
local SCRIPT_NAME = os.getenv("SCRIPT_NAME") or "/cgi-bin/focus"
local RESTART_COMMAND = "/etc/init.d/adguardhome restart >/tmp/focus-adguard-restart.log 2>&1"
local normalize_rules

local function write(...)
  for i = 1, select("#", ...) do
    local part = select(i, ...)
    io.write(part)
  end
end

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function html_escape(value)
  local escaped = tostring(value or "")
  escaped = escaped:gsub("&", "&amp;")
  escaped = escaped:gsub("<", "&lt;")
  escaped = escaped:gsub(">", "&gt;")
  escaped = escaped:gsub('"', "&quot;")
  return escaped
end

local function url_encode(value)
  return (tostring(value or ""):gsub("[^%w%-_%.~]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

local function url_decode(value)
  value = tostring(value or ""):gsub("%+", " ")
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function parse_form_encoded(value)
  local result = {}
  for pair in tostring(value or ""):gmatch("([^&]+)") do
    local key, raw = pair:match("^([^=]*)=(.*)$")
    if key == nil then
      key = pair
      raw = ""
    end
    result[url_decode(key)] = url_decode(raw)
  end
  return result
end

local function send_html(status_code)
  if status_code then
    write("Status: ", status_code, "\r\n")
  end
  write("Content-Type: text/html; charset=UTF-8\r\n")
  write("Cache-Control: no-store\r\n\r\n")
end

local function send_redirect(kind, message)
  local location = string.format(
    "%s?kind=%s&message=%s",
    SCRIPT_NAME,
    url_encode(kind or "info"),
    url_encode(message or "")
  )
  write("Status: 303 See Other\r\n")
  write("Location: ", location, "\r\n")
  write("Cache-Control: no-store\r\n\r\n")
end

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end

  local content = handle:read("*a")
  handle:close()
  return content
end

local function write_file(path, content)
  local handle = io.open(path, "wb")
  if not handle then
    return false
  end

  handle:write(content or "")
  handle:close()
  return true
end

local function command_succeeded(result)
  return result == true or result == 0
end

local function split_lines(content)
  local normalized = tostring(content or ""):gsub("\r\n", "\n")
  if normalized:sub(-1) ~= "\n" then
    normalized = normalized .. "\n"
  end

  local lines = {}
  for line in normalized:gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return lines
end

local function yaml_unquote(value)
  local text = trim(value)
  if text:sub(1, 1) == "'" and text:sub(-1) == "'" then
    local unquoted = text:sub(2, -2):gsub("''", "'")
    return unquoted
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

local function parse_config(content)
  local lines = split_lines(content)
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

local function build_user_rules_block(rules)
  local block = { "user_rules:" }
  for _, rule in ipairs(rules) do
    table.insert(block, "  - " .. yaml_quote(rule))
  end
  return block
end

local function serialize_config(parsed, rules)
  local block = build_user_rules_block(rules)
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

local function load_state()
  local content = read_file(CONFIG_PATH)
  if not content then
    return nil, "Could not read " .. CONFIG_PATH .. "."
  end

  local parsed = parse_config(content)
  parsed.rules = normalize_rules(parsed.rules)
  parsed.content = content
  return parsed, nil
end

local function save_rules(state, rules)
  local original_content = state.content
  local updated_content = serialize_config(state, rules)
  local temp_path = CONFIG_PATH .. ".tmp"

  if not write_file(temp_path, updated_content) then
    return false, "Could not write a temporary AdGuard Home config file."
  end

  if not os.rename(temp_path, CONFIG_PATH) then
    os.remove(temp_path)
    return false, "Could not replace the AdGuard Home config file."
  end

  local restarted = command_succeeded(os.execute(RESTART_COMMAND))
  if restarted then
    return true, nil
  end

  write_file(CONFIG_PATH, original_content)
  os.execute(RESTART_COMMAND)
  return false, "AdGuard Home restart failed. The previous config was restored."
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

local function normalize_host_input(value)
  local candidate = trim(value):lower()
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

local function classify_rule_for_host(rule, host)
  local text = trim(rule)
  if text == "" or text:sub(1, 1) == "#" or text:sub(1, 1) == "!" then
    return nil
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
    return nil
  end

  local normalized = normalize_host_input(extracted)
  if normalized ~= host then
    return nil
  end

  if allow then
    return "allow"
  end

  return "block"
end

normalize_rules = function(rules)
  local seen = {}
  local cleaned = {}

  for _, rule in ipairs(rules or {}) do
    local text = trim(rule)
    if text ~= "" and not seen[text] then
      seen[text] = true
      table.insert(cleaned, text)
    end
  end

  table.sort(cleaned)
  return cleaned
end

local function render_page(state)
  local banner = state.banner
  local rules = state.rules or {}
  local rules_text = table.concat(rules, "\n")
  local count = #rules
  local protection = "unknown"

  if state.protection_enabled == true then
    protection = "enabled"
  elseif state.protection_enabled == false then
    protection = "disabled"
  end

  send_html()
  write("<!doctype html>\n")
  write("<html lang=\"en\">\n")
  write("<head>\n")
  write("<meta charset=\"utf-8\">\n")
  write("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
  write("<title>Focus Blocklist</title>\n")
  write("<style>\n")
  write("body{font-family:sans-serif;max-width:960px;margin:2rem auto;padding:0 1rem;color:#111;background:#f6f3ec;}")
  write("h1{margin:0 0 0.5rem;font-size:1.8rem;}p{line-height:1.5;}")
  write(".panel{background:#fff;border:1px solid #d8d0c2;border-radius:8px;padding:1rem 1.25rem;margin:1rem 0;}")
  write(".meta{color:#5a5348;font-size:0.95rem;margin-top:0.25rem;}")
  write(".banner{padding:0.85rem 1rem;border-radius:8px;margin:1rem 0;font-weight:600;}")
  write(".banner.success{background:#e5f4e8;border:1px solid #9bcca3;}")
  write(".banner.warning{background:#fff6dd;border:1px solid #e4ca70;}")
  write(".banner.error{background:#f9e5e5;border:1px solid #d59b9b;}")
  write(".banner.info{background:#e7f0fb;border:1px solid #9eb6d3;}")
  write("label{display:block;font-weight:600;margin-bottom:0.5rem;}")
  write("input[type=text]{width:100%;padding:0.75rem;border:1px solid #bdb4a6;border-radius:6px;box-sizing:border-box;font-size:1rem;}")
  write("button{margin-top:0.75rem;background:#1f5b48;color:#fff;border:none;border-radius:6px;padding:0.75rem 1rem;font-size:1rem;cursor:pointer;}")
  write("button:hover{background:#174636;}textarea{width:100%;min-height:28rem;padding:0.75rem;border:1px solid #bdb4a6;border-radius:6px;box-sizing:border-box;font-family:monospace;font-size:0.92rem;background:#faf8f3;}")
  write("code{background:#efe9de;padding:0.1rem 0.35rem;border-radius:4px;}")
  write("</style>\n")
  write("</head>\n")
  write("<body>\n")
  write("<h1>Focus Blocklist</h1>\n")
  write("<p>This page reads and appends AdGuard Home custom filtering rules. It only adds new block rules in the form <code>||host^</code>.</p>\n")
  write("<div class=\"panel\">\n")
  write("<div><strong>Protection:</strong> ", protection, "</div>\n")
  write("<div class=\"meta\"><strong>Rule count:</strong> ", tostring(count), "</div>\n")
  write("</div>\n")

  if state.load_error then
    write("<div class=\"banner error\">", html_escape(state.load_error), "</div>\n")
  elseif banner and banner.message and banner.message ~= "" then
    write("<div class=\"banner ", html_escape(banner.kind or "info"), "\">", html_escape(banner.message), "</div>\n")
  end

  write("<div class=\"panel\">\n")
  write("<form method=\"post\" action=\"", html_escape(SCRIPT_NAME), "\">\n")
  write("<label for=\"entry\">Add a domain, hostname, or URL</label>\n")
  write("<input id=\"entry\" name=\"entry\" type=\"text\" placeholder=\"explainxkcd.com\" autocomplete=\"off\">\n")
  write("<button type=\"submit\">Add Block Rule</button>\n")
  write("</form>\n")
  write("</div>\n")

  write("<div class=\"panel\">\n")
  write("<label for=\"rules\">Current custom rules</label>\n")
  write("<textarea id=\"rules\" readonly>", html_escape(rules_text), "</textarea>\n")
  write("</div>\n")
  write("</body>\n")
  write("</html>\n")
end

local function handle_post()
  local length = tonumber(os.getenv("CONTENT_LENGTH") or "0") or 0
  local body = ""
  if length > 0 then
    body = io.read(length) or ""
  end

  local form = parse_form_encoded(body)
  local host, normalize_error = normalize_host_input(form.entry)
  if not host then
    send_redirect("error", normalize_error)
    return
  end

  local state, load_error = load_state()
  if not state then
    send_redirect("error", load_error)
    return
  end

  local new_rule = "||" .. host .. "^"
  local rules = state.rules

  for _, rule in ipairs(rules) do
    local classification = classify_rule_for_host(rule, host)
    if classification == "block" then
      send_redirect("info", "A block rule for " .. host .. " already exists.")
      return
    elseif classification == "allow" then
      send_redirect("error", "A conflicting allow rule already exists for " .. host .. ".")
      return
    end
  end

  table.insert(rules, new_rule)
  rules = normalize_rules(rules)

  local updated, update_error = save_rules(state, rules)
  if not updated then
    send_redirect("error", update_error or "Could not update AdGuard Home rules.")
    return
  end

  send_redirect("success", "Added " .. new_rule .. ".")
end

local method = os.getenv("REQUEST_METHOD") or "GET"

if method == "POST" then
  handle_post()
  return
end

if method ~= "GET" then
  send_html("405 Method Not Allowed")
  write("<!doctype html><title>Method Not Allowed</title><p>Only GET and POST are supported.</p>")
  return
end

local query = parse_form_encoded(os.getenv("QUERY_STRING") or "")
local state, load_error = load_state()

render_page({
  banner = {
    kind = query.kind or "info",
    message = query.message or "",
  },
  load_error = load_error,
  protection_enabled = state and state.protection_enabled or nil,
  rules = state and state.rules or {},
})
