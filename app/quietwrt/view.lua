local util = require("quietwrt.util")

local M = {}

local function write(...)
  io.write(...)
end

local function render_rule_list(items, empty_message)
  if not items or #items == 0 then
    return '<div class="rule-list empty"><div class="empty-state">' .. util.html_escape(empty_message or "No entries yet.") .. "</div></div>"
  end

  local parts = { '<div class="rule-list">' }
  for _, item in ipairs(items) do
    table.insert(parts, '<div class="rule-line">' .. util.html_escape(item) .. "</div>")
  end
  table.insert(parts, "</div>")
  return table.concat(parts)
end

local function banner_class(kind)
  local allowed = {
    success = true,
    warning = true,
    error = true,
    info = true,
  }

  kind = tostring(kind or "info")
  if allowed[kind] then
    return kind
  end

  return "info"
end

local function render_code(value)
  return "<code>" .. util.html_escape(value) .. "</code>"
end

local function render_chip(label, tone)
  return '<span class="chip ' .. util.html_escape(tone or "unknown") .. '">' .. util.html_escape(label or "Unknown") .. "</span>"
end

local function render_status_text(value)
  return '<span class="status-text">' .. util.html_escape(value or "Unknown") .. "</span>"
end

local function render_status_item(label, values, detail)
  local parts = {
    '<div class="status-item"><div class="status-top"><div class="status-label">',
    util.html_escape(label),
    '</div><div class="status-values">',
  }

  for _, value in ipairs(values or {}) do
    table.insert(parts, value)
  end

  table.insert(parts, "</div></div>")

  if detail and detail ~= "" then
    table.insert(parts, '<div class="status-detail">' .. detail .. "</div>")
  end

  table.insert(parts, "</div>")
  return table.concat(parts)
end

local function render_window_detail(window)
  if not window then
    return util.html_escape("Schedule window is unavailable.")
  end

  local detail = "Active from "
    .. render_code(window.display_start)
    .. " until "
    .. render_code(window.display_end)

  if window.overnight then
    detail = detail .. " (overnight)"
  end

  return detail .. "."
end

local function render_overnight_detail(window)
  if not window then
    return util.html_escape("Overnight lockout window is unavailable.")
  end

  local detail = "Internet access is fully blocked from "
    .. render_code(window.display_start)
    .. " until "
    .. render_code(window.display_end)

  if window.overnight then
    detail = detail .. " (overnight)"
  end

  return detail .. "."
end

local function render_enabled_chip(enabled)
  if enabled == true then
    return render_chip("Enabled", "enabled")
  end

  if enabled == false then
    return render_chip("Disabled", "disabled")
  end

  return render_chip("Unknown", "unknown")
end

local function render_activity_chip(enabled, active)
  if enabled == nil then
    return render_chip("Unknown", "unknown")
  end

  if enabled ~= true then
    return render_chip("Inactive", "inactive")
  end

  if active == true then
    return render_chip("Active", "active")
  end

  return render_chip("Inactive", "inactive")
end

function M.send_html(status_code)
  if status_code then
    write("Status: ", status_code, "\r\n")
  end
  write("Content-Type: text/html; charset=UTF-8\r\n")
  write("Cache-Control: no-store\r\n\r\n")
end

function M.send_redirect(script_name, kind, message)
  local location = string.format(
    "%s?kind=%s&message=%s",
    script_name,
    util.url_encode(kind or "info"),
    util.url_encode(message or "")
  )

  write("Status: 303 See Other\r\n")
  write("Location: ", location, "\r\n")
  write("Cache-Control: no-store\r\n\r\n")
end

function M.render_page(script_name, state)
  local banner = state.banner
  local banner_kind = banner_class(banner and banner.kind)
  local settings = state.settings or {}
  local always_hosts = state.always_hosts or {}
  local workday_hosts = state.workday_hosts or {}
  local after_work_hosts = state.after_work_hosts or {}
  local password_vault_hosts = state.password_vault_hosts or {}
  local schedule_state = state.schedule or {}
  local always_list = render_rule_list(always_hosts, "No always-blocked domains.")
  local workday_list = render_rule_list(workday_hosts, "No workday-blocked domains.")
  local after_work_list = render_rule_list(after_work_hosts, "No after-work-blocked domains.")
  local password_vault_list = render_rule_list(password_vault_hosts, "No password vault blocked domains.")

  M.send_html()
  write("<!doctype html>\n")
  write("<html lang=\"en\">\n")
  write("<head>\n")
  write("<meta charset=\"utf-8\">\n")
  write("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
  write("<title>QuietWrt Blocklists</title>\n")
  write("<style>\n")
  write(":root{color-scheme:dark;--bg:#282a36;--bg-deep:#21222c;--panel:#343746;--panel-soft:#303341;--field:#282a36;--text:#f8f8f2;--muted:#a9add1;--edge:#44475a;--edge-strong:#6272a4;--cyan:#8be9fd;--green:#50fa7b;--orange:#ffb86c;--pink:#ff79c6;--purple:#bd93f9;--red:#ff5555;--yellow:#f1fa8c;--shadow:0 18px 48px rgba(0,0,0,0.32);}")
  write("*{box-sizing:border-box;}")
  write("body{margin:0;color:var(--text);font-family:\"Trebuchet MS\",\"Segoe UI\",sans-serif;background:radial-gradient(circle at top,#373a4b 0%,var(--bg) 30%,var(--bg-deep) 100%);}")
  write(".shell{max-width:1180px;margin:0 auto;padding:2rem 1rem 3rem;}")
  write("h1{margin:0;font-size:2rem;line-height:1.1;}")
  write("p{margin:0;line-height:1.6;color:var(--muted);}")
  write(".panel{margin-top:1rem;padding:1.15rem 1.2rem;border-radius:18px;border:1px solid var(--edge);background:linear-gradient(180deg,rgba(255,255,255,0.02),rgba(255,255,255,0)),var(--panel);box-shadow:var(--shadow);}")
  write(".section-title{display:flex;align-items:center;justify-content:space-between;gap:1rem;flex-wrap:wrap;margin-bottom:0.35rem;}")
  write(".section-title h2,.section-title h3{margin:0;font-size:1.08rem;}")
  write(".banner{padding:0.95rem 1rem;border-radius:14px;margin-top:1rem;font-weight:700;}")
  write(".banner.success{background:rgba(80,250,123,0.12);border:1px solid rgba(80,250,123,0.28);}")
  write(".banner.warning{background:rgba(255,184,108,0.12);border:1px solid rgba(255,184,108,0.28);}")
  write(".banner.error{background:rgba(255,85,85,0.12);border:1px solid rgba(255,85,85,0.28);}")
  write(".banner.info{background:rgba(139,233,253,0.12);border:1px solid rgba(139,233,253,0.28);}")
  write(".status-list{display:grid;gap:0.2rem;}")
  write(".status-item{padding:0.8rem 0;border-top:1px solid rgba(255,255,255,0.06);}")
  write(".status-item:first-child{border-top:none;padding-top:0.2rem;}")
  write(".status-top{display:flex;justify-content:space-between;gap:1rem;align-items:center;flex-wrap:wrap;}")
  write(".status-label{font-weight:700;color:var(--text);}")
  write(".status-values{display:flex;gap:0.55rem;flex-wrap:wrap;align-items:center;}")
  write(".status-text{font-size:1rem;font-weight:700;color:var(--cyan);}")
  write(".status-detail{margin-top:0.45rem;color:var(--muted);}")
  write(".chip{display:inline-flex;align-items:center;justify-content:center;min-height:2.05rem;padding:0.35rem 0.8rem;border-radius:999px;border:1px solid var(--edge-strong);background:rgba(98,114,164,0.12);font-size:0.92rem;font-weight:700;}")
  write(".chip.enabled{background:rgba(80,250,123,0.12);border-color:rgba(80,250,123,0.34);color:var(--green);}")
  write(".chip.disabled{background:rgba(189,147,249,0.12);border-color:rgba(189,147,249,0.34);color:var(--purple);}")
  write(".chip.active{background:rgba(255,184,108,0.14);border-color:rgba(255,184,108,0.34);color:var(--orange);}")
  write(".chip.inactive{background:rgba(98,114,164,0.16);border-color:rgba(98,114,164,0.34);color:#c7cae7;}")
  write(".chip.unknown{background:rgba(255,121,198,0.12);border-color:rgba(255,121,198,0.34);color:var(--pink);}")
  write(".form-panel{background:linear-gradient(180deg,rgba(255,255,255,0.02),rgba(255,255,255,0)),var(--panel-soft);}")
  write(".field-stack > * + *{margin-top:0.95rem;}")
  write(".action-row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:0.8rem;align-items:end;}")
  write(".action-row .button-wrap{display:flex;}")
  write(".field-help{font-size:0.92rem;color:var(--muted);margin-bottom:0.7rem;}")
  write("label{display:block;font-weight:700;margin-bottom:0.45rem;}")
  write("input[type=text],select{width:100%;padding:0.85rem 0.95rem;border:1px solid var(--edge);border-radius:12px;font-size:1rem;color:var(--text);background:var(--field);outline:none;transition:border-color 0.15s ease,box-shadow 0.15s ease;}")
  write("input[type=text]:focus,select:focus{border-color:rgba(139,233,253,0.54);box-shadow:0 0 0 3px rgba(139,233,253,0.16);}")
  write("input[type=text]::placeholder{color:#8f93b8;}")
  write("button{margin-top:0.3rem;background:linear-gradient(180deg,var(--purple),#a77df7);color:#fff;border:none;border-radius:12px;padding:0.85rem 1.1rem;font-size:1rem;font-weight:800;cursor:pointer;box-shadow:0 12px 28px rgba(189,147,249,0.24);white-space:nowrap;}")
  write("button:hover{filter:brightness(1.04);}")
  write(".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:1rem;align-items:start;}")
  write(".count-badge{display:inline-flex;align-items:center;padding:0.3rem 0.65rem;border-radius:999px;background:rgba(139,233,253,0.12);border:1px solid rgba(139,233,253,0.3);color:var(--cyan);font-size:0.82rem;font-weight:700;}")
  write(".list-panel{padding:1rem 1rem 1.1rem;}")
  write(".rule-list{max-height:26rem;overflow:auto;padding:0.35rem;border-radius:14px;border:1px solid var(--edge);background:rgba(40,42,54,0.92);}")
  write(".rule-line{padding:0.55rem 0.7rem;border-radius:10px;color:var(--text);font-family:\"Cascadia Mono\",\"Consolas\",\"SFMono-Regular\",monospace;font-size:0.92rem;line-height:1.35;word-break:break-word;}")
  write(".rule-line + .rule-line{margin-top:0.3rem;border-top:1px solid rgba(255,255,255,0.03);padding-top:0.75rem;}")
  write(".empty-state{padding:1rem 0.8rem;color:var(--muted);font-style:italic;}")
  write("code{background:rgba(255,255,255,0.08);padding:0.12rem 0.38rem;border-radius:6px;color:var(--yellow);}")
  write("@media (max-width:760px){.shell{padding-top:1.3rem;}.status-top{align-items:flex-start;}.action-row{grid-template-columns:1fr;}.action-row .button-wrap{display:block;}.rule-list{max-height:20rem;}}")
  write("</style>\n")
  write("</head>\n")
  write("<body>\n")
  write("<div class=\"shell\">\n")
  write("<h1>QuietWrt Blocklists</h1>\n")
  write("<section class=\"panel\">\n")
  write("<div class=\"status-list\">\n")
  write(render_status_item("Router time", {
    render_status_text(state.router_time or "Unknown"),
  }), "\n")
  write(render_status_item("Always blocklist", {
    render_enabled_chip(settings.always_enabled),
  }, "Active whenever internet is available."), "\n")
  write(render_status_item("Workday blocklist", {
    render_enabled_chip(settings.workday_enabled),
    render_activity_chip(settings.workday_enabled, state.workday_active),
  }, render_window_detail(schedule_state.workday)), "\n")
  write(render_status_item("After work blocklist", {
    render_enabled_chip(settings.after_work_enabled),
    render_activity_chip(settings.after_work_enabled, state.after_work_active),
  }, render_window_detail(schedule_state.after_work)), "\n")
  write(render_status_item("Password vault blocklist", {
    render_enabled_chip(settings.password_vault_enabled),
    render_activity_chip(settings.password_vault_enabled, state.password_vault_active),
  }, render_window_detail(schedule_state.password_vault)), "\n")
  write(render_status_item("Overnight lockout", {
    render_enabled_chip(settings.overnight_enabled),
    render_activity_chip(settings.overnight_enabled, state.overnight_active),
  }, render_overnight_detail(schedule_state.overnight)), "\n")
  write("</div>\n")
  write("</section>\n")

  if state.load_error then
    write("<div class=\"banner error\">", util.html_escape(state.load_error), "</div>\n")
  elseif banner and banner.message and banner.message ~= "" then
    write("<div class=\"banner ", banner_kind, "\">", util.html_escape(banner.message), "</div>\n")
  end

  write("<section class=\"panel form-panel field-stack\">\n")
  write("<div class=\"section-title\"><h2>Add a domain, hostname, or URL</h2></div>\n")
  write("<p class=\"field-help\">New entries are normalized to a canonical hostname and stored in exactly one blocklist.</p>\n")
  write("<form method=\"post\" action=\"", util.html_escape(script_name), "\">\n")
  write("<div class=\"field-stack\">\n")
  write("<div>\n")
  write("<label for=\"entry\">Entry</label>\n")
  write("<input id=\"entry\" name=\"entry\" type=\"text\" placeholder=\"example.com\" autocomplete=\"off\">\n")
  write("</div>\n")
  write("<div>\n")
  write("<label for=\"list_kind\">Add to</label>\n")
  write("<div class=\"action-row\">\n")
  write("<div>\n")
  write("<select id=\"list_kind\" name=\"list_kind\">\n")
  write("<option value=\"always\">Always blocked</option>\n")
  write("<option value=\"workday\">Workday blocked</option>\n")
  write("<option value=\"after_work\">After work blocked</option>\n")
  write("<option value=\"password_vault\">Password vault blocked</option>\n")
  write("</select>\n")
  write("</div>\n")
  write("<div class=\"button-wrap\"><button type=\"submit\">Add Entry</button></div>\n")
  write("</div>\n")
  write("</div>\n")
  write("</form>\n")
  write("</section>\n")

  write("<section class=\"grid\">\n")
  write("<div class=\"panel list-panel\">\n")
  write("<div class=\"section-title\"><h3>Always blocked</h3><span class=\"count-badge\">", tostring(#always_hosts), " entries</span></div>\n")
  write("<p class=\"field-help\">These domains stay blocked whenever internet access is available.</p>\n")
  write(always_list, "\n")
  write("</div>\n")
  write("<div class=\"panel list-panel\">\n")
  write("<div class=\"section-title\"><h3>Workday blocked</h3><span class=\"count-badge\">", tostring(#workday_hosts), " entries</span></div>\n")
  write("<p class=\"field-help\">These domains are added during the workday schedule window only.</p>\n")
  write(workday_list, "\n")
  write("</div>\n")
  write("<div class=\"panel list-panel\">\n")
  write("<div class=\"section-title\"><h3>After work blocked</h3><span class=\"count-badge\">", tostring(#after_work_hosts), " entries</span></div>\n")
  write("<p class=\"field-help\">These domains are added during the after-work schedule window only.</p>\n")
  write(after_work_list, "\n")
  write("</div>\n")
  write("<div class=\"panel list-panel\">\n")
  write("<div class=\"section-title\"><h3>Password vault blocked</h3><span class=\"count-badge\">", tostring(#password_vault_hosts), " entries</span></div>\n")
  write("<p class=\"field-help\">These domains are added during the password vault schedule window only.</p>\n")
  write(password_vault_list, "\n")
  write("</div>\n")
  write("</section>\n")
  write("</div>\n")
  write("</body>\n")
  write("</html>\n")
end

return M
