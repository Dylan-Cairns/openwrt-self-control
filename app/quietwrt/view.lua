local util = require("quietwrt.util")

local M = {}

local function write(...)
  for i = 1, select("#", ...) do
    io.write(select(i, ...))
  end
end

local function render_list_text(items)
  if not items or #items == 0 then
    return ""
  end
  return table.concat(items, "\n")
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
  local protection = "unknown"

  if state.protection_enabled == true then
    protection = "enabled"
  elseif state.protection_enabled == false then
    protection = "disabled"
  end

  local always_text = render_list_text(state.always_hosts or {})
  local workday_text = render_list_text(state.workday_hosts or {})
  local active_text = render_list_text(state.active_rules or {})

  M.send_html()
  write("<!doctype html>\n")
  write("<html lang=\"en\">\n")
  write("<head>\n")
  write("<meta charset=\"utf-8\">\n")
  write("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
  write("<title>QuietWrt Blocklists</title>\n")
  write("<style>\n")
  write(":root{--bg:#f6f3ec;--panel:#ffffff;--ink:#111;--muted:#5a5348;--edge:#d8d0c2;--field:#faf8f3;--brand:#1f5b48;}")
  write("body{font-family:sans-serif;max-width:1120px;margin:2rem auto;padding:0 1rem 2rem;color:var(--ink);background:var(--bg);}")
  write("h1{margin:0 0 0.5rem;font-size:1.9rem;}p{line-height:1.5;margin:0.3rem 0 0.8rem;}")
  write(".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:1rem;}")
  write(".panel{background:var(--panel);border:1px solid var(--edge);border-radius:10px;padding:1rem 1.25rem;margin:1rem 0;}")
  write(".meta{color:var(--muted);font-size:0.95rem;margin-top:0.25rem;}")
  write(".banner{padding:0.85rem 1rem;border-radius:8px;margin:1rem 0;font-weight:600;}")
  write(".banner.success{background:#e5f4e8;border:1px solid #9bcca3;}")
  write(".banner.warning{background:#fff6dd;border:1px solid #e4ca70;}")
  write(".banner.error{background:#f9e5e5;border:1px solid #d59b9b;}")
  write(".banner.info{background:#e7f0fb;border:1px solid #9eb6d3;}")
  write("label{display:block;font-weight:600;margin-bottom:0.5rem;}")
  write("input[type=text],select{width:100%;padding:0.75rem;border:1px solid #bdb4a6;border-radius:6px;box-sizing:border-box;font-size:1rem;background:#fff;}")
  write("button{margin-top:0.85rem;background:var(--brand);color:#fff;border:none;border-radius:6px;padding:0.8rem 1rem;font-size:1rem;cursor:pointer;}")
  write("button:hover{background:#174636;}")
  write("textarea{width:100%;min-height:20rem;padding:0.75rem;border:1px solid #bdb4a6;border-radius:6px;box-sizing:border-box;font-family:monospace;font-size:0.92rem;background:var(--field);}")
  write("code{background:#efe9de;padding:0.1rem 0.35rem;border-radius:4px;}")
  write(".stack > * + *{margin-top:0.85rem;}")
  write("</style>\n")
  write("</head>\n")
  write("<body>\n")
  write("<h1>QuietWrt Blocklists</h1>\n")
  write("<p>Always blocked entries stay active whenever internet is available. Workday blocked entries are active from <code>04:00</code> until <code>16:30</code>. Internet access is fully blocked from <code>18:30</code> until <code>04:00</code>.</p>\n")
  write("<div class=\"panel\">\n")
  write("<div><strong>Mode:</strong> ", util.html_escape(state.current_mode.label), "</div>\n")
  write("<div class=\"meta\">", util.html_escape(state.current_mode.description), "</div>\n")
  write("<div class=\"meta\"><strong>Protection:</strong> ", protection, " | <strong>Always blocked:</strong> ", tostring(#(state.always_hosts or {})), " | <strong>Workday blocked:</strong> ", tostring(#(state.workday_hosts or {})), " | <strong>Active rules:</strong> ", tostring(state.active_rule_count or 0), "</div>\n")
  write("</div>\n")

  if state.load_error then
    write("<div class=\"banner error\">", util.html_escape(state.load_error), "</div>\n")
  elseif banner and banner.message and banner.message ~= "" then
    write("<div class=\"banner ", util.html_escape(banner.kind or "info"), "\">", util.html_escape(banner.message), "</div>\n")
  end

  write("<div class=\"panel stack\">\n")
  write("<form method=\"post\" action=\"", util.html_escape(script_name), "\">\n")
  write("<label for=\"entry\">Add a domain, hostname, or URL</label>\n")
  write("<input id=\"entry\" name=\"entry\" type=\"text\" placeholder=\"explainxkcd.com\" autocomplete=\"off\">\n")
  write("<label for=\"list_kind\">Add to</label>\n")
  write("<select id=\"list_kind\" name=\"list_kind\">\n")
  write("<option value=\"always\">Always blocked</option>\n")
  write("<option value=\"workday\">Workday blocked</option>\n")
  write("</select>\n")
  write("<button type=\"submit\">Add Entry</button>\n")
  write("</form>\n")
  write("</div>\n")

  write("<div class=\"grid\">\n")
  write("<div class=\"panel\">\n")
  write("<label for=\"always_rules\">Always blocked</label>\n")
  write("<textarea id=\"always_rules\" readonly>", util.html_escape(always_text), "</textarea>\n")
  write("</div>\n")
  write("<div class=\"panel\">\n")
  write("<label for=\"workday_rules\">Workday blocked</label>\n")
  write("<textarea id=\"workday_rules\" readonly>", util.html_escape(workday_text), "</textarea>\n")
  write("</div>\n")
  write("</div>\n")

  write("<div class=\"panel\">\n")
  write("<label for=\"active_rules\">Current active AdGuard rules</label>\n")
  write("<textarea id=\"active_rules\" readonly>", util.html_escape(active_text), "</textarea>\n")
  write("</div>\n")
  write("</body>\n")
  write("</html>\n")
end

return M
