local service = require("quietwrt.service")
local util = require("quietwrt.util")
local view = require("quietwrt.view")

local M = {}

local function read_stdin(length)
  if length <= 0 then
    return ""
  end
  return io.read(length) or ""
end

function M.run_cgi(options)
  local context = service.new_context(options)
  local script_name = os.getenv("SCRIPT_NAME") or "/cgi-bin/quietwrt"
  local method = os.getenv("REQUEST_METHOD") or "GET"

  if method == "POST" then
    local length = tonumber(os.getenv("CONTENT_LENGTH") or "0") or 0
    local form = util.parse_form_encoded(read_stdin(length))
    local result = service.add_entry(context, form.list_kind or "always", form.entry)
    view.send_redirect(script_name, result.kind or "info", result.message or "")
    return
  end

  if method ~= "GET" then
    view.send_html("405 Method Not Allowed")
    io.write("<!doctype html><title>Method Not Allowed</title><p>Only GET and POST are supported.</p>")
    return
  end

  local query = util.parse_form_encoded(os.getenv("QUERY_STRING") or "")
  local state, load_error = service.load_view_state(context)

  view.render_page(script_name, {
    banner = {
      kind = query.kind or "info",
      message = query.message or "",
    },
    load_error = load_error,
    protection_enabled = state and state.protection_enabled or nil,
    current_mode = state and state.current_mode or {
      label = "Unknown",
      description = "Could not load the current QuietWrt mode.",
    },
    always_hosts = state and state.always_hosts or {},
    workday_hosts = state and state.workday_hosts or {},
    active_rules = state and state.active_rules or {},
    active_rule_count = state and state.active_rule_count or 0,
  })
end

local function print_usage()
  io.write([[
Usage: quietwrtctl <command>

Commands:
  install   Bootstrap list files, install cron sync, and apply the current mode.
  sync      Rebuild AdGuard rules for the current time and update curfew firewall state.
  apply     Alias for sync.
  status    Show current list counts and active mode.
]])
end

function M.run_cli(argv, options)
  local context = service.new_context(options)
  local command = argv and argv[1] or nil

  if command == "install" then
    local ok, result = service.install(context)
    if not ok then
      io.stderr:write(result, "\n")
      return 1
    end
    io.write("Installed QuietWrt schedule. Current mode: ", result.mode.label, "\n")
    return 0
  end

  if command == "sync" or command == "apply" then
    local ok, result = service.apply_current_mode(context)
    if not ok then
      io.stderr:write(result, "\n")
      return 1
    end
    io.write("Applied ", result.mode.label, " with ", tostring(result.active_rule_count), " active rules.\n")
    return 0
  end

  if command == "status" then
    local ok, output = service.status(context)
    if not ok then
      io.stderr:write(output, "\n")
      return 1
    end
    io.write(output, "\n")
    return 0
  end

  print_usage()
  return command and 1 or 0
end

return M
