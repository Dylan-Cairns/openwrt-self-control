local service = require("quietwrt.service")
local schedule = require("quietwrt.schedule")
local util = require("quietwrt.util")
local view = require("quietwrt.view")

local M = {}

local function read_stdin(length)
  if length <= 0 then
    return ""
  end
  return io.read(length) or ""
end

local function import_message(result)
  return "Imported "
    .. tostring(result.added_count or 0)
    .. " new domains from ZIP. Active rules: "
    .. tostring(result.active_rule_count or 0)
    .. "."
end

local function toggle_label(toggle_name)
  local labels = {
    always = "Always blocklist",
    workday = "Workday blocklist",
    after_work = "After work blocklist",
    password_vault = "Password vault blocklist",
    overnight = "Overnight lockout",
    saturday_blockout = "Saturday lockout",
  }

  return labels[toggle_name] or tostring(toggle_name or "restriction")
end

local function enable_toggle_message(toggle_name, result)
  if result and result.already_enabled then
    return toggle_label(toggle_name) .. " is already enabled."
  end

  return "Enabled "
    .. toggle_label(toggle_name)
    .. ". Active rules: "
    .. tostring(result and result.active_rule_count or 0)
    .. "."
end

function M.run_cgi(options)
  local context = service.new_context(options)
  local script_name = os.getenv("SCRIPT_NAME") or "/cgi-bin/quietwrt"
  local method = os.getenv("REQUEST_METHOD") or "GET"

  if method == "POST" then
    local length = tonumber(os.getenv("CONTENT_LENGTH") or "0") or 0
    local content_type = os.getenv("CONTENT_TYPE") or ""
    local body = read_stdin(length)

    if content_type:find("multipart/form-data", 1, true) then
      if length > 2097152 then
        view.send_redirect(script_name, "error", "Uploaded ZIP is too large.")
        return
      end

      local form, form_error = util.parse_multipart_form_data(body, content_type)
      if not form then
        view.send_redirect(script_name, "error", form_error)
        return
      end

      if form.action and form.action.content == "import_zip" then
        local upload = form.blocklists_zip
        if not upload or upload.content == "" then
          view.send_redirect(script_name, "error", "Choose a QuietWrt ZIP file to import.")
          return
        end

        local ok, result = service.import_blocklists_archive(context, upload.content)
        if not ok then
          view.send_redirect(script_name, "error", result)
          return
        end

        view.send_redirect(script_name, "success", import_message(result))
        return
      end

      view.send_redirect(script_name, "error", "Unsupported upload action.")
      return
    end

    local form = util.parse_form_encoded(body)
    if form.action == "enable_toggle" then
      local ok, result = service.enable_toggle(context, form.toggle_name)
      if not ok then
        view.send_redirect(script_name, "error", result)
        return
      end

      view.send_redirect(script_name, result.already_enabled and "info" or "success", enable_toggle_message(form.toggle_name, result))
      return
    end

    if form.action ~= nil and form.action ~= "" then
      view.send_redirect(script_name, "error", "Unsupported form action.")
      return
    end

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
  if query.download ~= nil then
    if query.download ~= "zip" then
      view.send_error_page("400 Bad Request", "Download Unavailable", "Only ZIP downloads are supported.")
      return
    end

    local ok, download = service.download_blocklists_archive(context, query.download)
    if not ok then
      view.send_error_page("409 Conflict", "Download Unavailable", download)
      return
    end

    view.send_download(download.content_type, download.filename, download.content)
    return
  end

  local state, load_error = service.load_view_state(context)
  local protection_enabled = nil
  local enforcement_ready = nil

  if state ~= nil then
    protection_enabled = state.protection_enabled
    enforcement_ready = state.enforcement_ready
  end

  view.render_page(script_name, {
    banner = {
      kind = query.kind or "info",
      message = query.message or "",
    },
    load_error = load_error,
    protection_enabled = protection_enabled,
    enforcement_ready = enforcement_ready,
    router_time = state and state.router_time or os.date("%H:%M"),
    settings = state and state.settings or {},
    workday_active = state and state.workday_active,
    after_work_active = state and state.after_work_active,
    password_vault_active = state and state.password_vault_active,
    overnight_active = state and state.overnight_active,
    saturday_blockout_active = state and state.saturday_blockout_active,
    schedule = state and state.schedule or {},
    warnings = state and state.warnings or {},
    failsafe = state and state.failsafe or { active = false },
    always_hosts = state and state.always_hosts or {},
    workday_hosts = state and state.workday_hosts or {},
    after_work_hosts = state and state.after_work_hosts or {},
    password_vault_hosts = state and state.password_vault_hosts or {},
    active_rules = state and state.active_rules or {},
    active_rule_count = state and state.active_rule_count or 0,
  })
end

local function print_usage()
  io.write([[
Usage: quietwrtctl <command>

Commands:
  install   Bootstrap list files, install cron sync, and apply the current schedule state.
  boot-check Validate QuietWrt state at boot; enter failsafe-open if state is corrupt.
  sync      Rebuild AdGuard rules for the current time and update curfew firewall state.
  apply     Alias for sync.
  status    Show current list counts and schedule state. Use --json for machine-readable output.
  set       Toggle always, workday, after_work, password_vault, overnight, or saturday_blockout on or off.
  schedule  Set workday, after_work, password_vault, or overnight start/end times.
  restore   Restore always/workday/after-work/password-vault list files from uploaded backup files and apply them.
]])
end

local function parse_restore_args(argv)
  local parsed = {}
  local index = 2

  while index <= #argv do
    local flag = argv[index]
    local value = argv[index + 1]

    if (flag ~= "--always" and flag ~= "--workday" and flag ~= "--after-work" and flag ~= "--password-vault") or value == nil or value == "" then
      return nil, "Usage: quietwrtctl restore [--always <path>] [--workday <path>] [--after-work <path>] [--password-vault <path>]"
    end

    if flag == "--always" then
      parsed.always_path = value
    elseif flag == "--workday" then
      parsed.workday_path = value
    elseif flag == "--after-work" then
      parsed.after_work_path = value
    else
      parsed.password_vault_path = value
    end

    index = index + 2
  end

  if not parsed.always_path and not parsed.workday_path and not parsed.after_work_path and not parsed.password_vault_path then
    return nil, "Usage: quietwrtctl restore [--always <path>] [--workday <path>] [--after-work <path>] [--password-vault <path>]"
  end

  return parsed, nil
end

local function schedule_summary(schedule_name, start_value, end_value)
  local window, err = schedule.build_window(schedule_name, start_value, end_value)
  if not window then
    return nil, err
  end
  return schedule.window_summary(window), nil
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
    io.write("Installed QuietWrt. Active rules: ", tostring(result.active_rule_count), "\n")
    return 0
  end

  if command == "boot-check" then
    local ok, result = service.boot_check(context)
    if not ok then
      io.stderr:write(result, "\n")
      return 1
    end

    if result.failsafe_open then
      io.stderr:write("QuietWrt entered failsafe-open mode: ", tostring(result.reason), "\n")
      return 2
    end

    io.write("QuietWrt boot check passed.\n")
    return 0
  end

  if command == "sync" or command == "apply" then
    local ok, result = service.apply_current_mode(context)
    if not ok then
      io.stderr:write(result, "\n")
      return 1
    end
    io.write("Applied QuietWrt state with ", tostring(result.active_rule_count), " active rules.\n")
    return 0
  end

  if command == "status" then
    local as_json = argv[2] == "--json"
    local ok, output = service.status(context, {
      json = as_json,
    })
    if not ok then
      io.stderr:write(output, "\n")
      return 1
    end
    io.write(output, "\n")
    return 0
  end

  if command == "set" then
    local toggle_name = argv[2]
    local raw_state = argv[3]
    local enabled

    if raw_state == "on" then
      enabled = true
    elseif raw_state == "off" then
      enabled = false
    else
      io.stderr:write("Usage: quietwrtctl set <always|workday|after_work|password_vault|overnight|saturday_blockout> <on|off>\n")
      return 1
    end

    local ok, result = service.set_toggle(context, toggle_name, enabled)
    if not ok then
      io.stderr:write(result, "\n")
      return 1
    end

    io.write(
      "Set ",
      toggle_name,
      " ",
      raw_state,
      ". Active rules: ",
      tostring(result.active_rule_count),
      ".\n"
    )
    return 0
  end

  if command == "schedule" then
    local schedule_name = argv[2]
    local start_value = argv[3]
    local end_value = argv[4]

    if schedule_name == nil or start_value == nil or end_value == nil then
      io.stderr:write("Usage: quietwrtctl schedule <workday|after_work|password_vault|overnight> <start_hhmm> <end_hhmm>\n")
      return 1
    end

    local ok, result = service.set_schedule(context, schedule_name, start_value, end_value)
    if not ok then
      io.stderr:write(result, "\n")
      return 1
    end

    local summary, summary_error = schedule_summary(schedule_name, start_value, end_value)
    if not summary then
      io.stderr:write(summary_error, "\n")
      return 1
    end

    io.write(
      "Set ",
      schedule_name,
      " window to ",
      summary,
      ". Active rules: ",
      tostring(result.active_rule_count),
      ".\n"
    )
    return 0
  end

  if command == "restore" then
    local restore_args, restore_error = parse_restore_args(argv)
    if not restore_args then
      io.stderr:write(restore_error, "\n")
      return 1
    end

    local ok, result = service.restore_lists(context, restore_args)
    if not ok then
      io.stderr:write(result, "\n")
      return 1
    end

    io.write("Restored backup lists. Active rules: ", tostring(result.active_rule_count), ".\n")
    return 0
  end

  print_usage()
  return command and 1 or 0
end

return M
