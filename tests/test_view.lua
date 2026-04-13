local lu = require("luaunit")
local view = require("quietwrt.view")

TestView = {}

local function capture_output(render)
  local original_write = io.write
  local chunks = {}

  io.write = function(...)
    for index = 1, select("#", ...) do
      table.insert(chunks, tostring(select(index, ...)))
    end
  end

  local ok, result = xpcall(render, debug.traceback)
  io.write = original_write

  if not ok then
    error(result)
  end

  return table.concat(chunks)
end

local function count_occurrences(haystack, needle)
  local count = 0
  local start = 1

  while true do
    local first = haystack:find(needle, start, true)
    if not first then
      return count
    end

    count = count + 1
    start = first + #needle
  end
end

function TestView:test_render_page_uses_dracula_status_rows_and_non_editable_rule_lists()
  local html = capture_output(function()
    view.render_page("/cgi-bin/quietwrt", {
      banner = {
        kind = "success",
        message = "Added example.com to Always blocked.",
      },
      router_time = "19:42",
      settings = {
        always_enabled = true,
        workday_enabled = true,
        after_work_enabled = true,
        overnight_enabled = false,
      },
      workday_active = false,
      after_work_active = true,
      overnight_active = false,
      schedule = {
        workday = {
          display_start = "04:00",
          display_end = "16:30",
          overnight = false,
        },
        after_work = {
          display_start = "16:30",
          display_end = "19:00",
          overnight = false,
        },
        overnight = {
          display_start = "19:00",
          display_end = "04:00",
          overnight = true,
        },
      },
      always_hosts = {
        "alpha.example",
        "beta.example",
      },
      workday_hosts = {},
      after_work_hosts = {
        "gamma.example",
      },
    })
  end)

  lu.assertStrContains(html, "--bg:#282a36")
  lu.assertStrContains(html, 'form method="post" action="/cgi-bin/quietwrt"')
  lu.assertStrContains(html, "Router time")
  lu.assertStrContains(html, '<span class="status-text">19:42</span>')
  lu.assertStrContains(html, "Always blocklist")
  lu.assertStrContains(html, "Workday blocklist")
  lu.assertStrContains(html, "After work blocklist")
  lu.assertStrContains(html, "Overnight lockout")
  lu.assertStrContains(html, "Active whenever internet is available.")
  lu.assertStrContains(html, "Active from <code>04:00</code> until <code>16:30</code>.")
  lu.assertStrContains(html, "Active from <code>16:30</code> until <code>19:00</code>.")
  lu.assertStrContains(html, "Internet access is fully blocked from <code>19:00</code> until <code>04:00</code> (overnight).")
  lu.assertEquals(count_occurrences(html, "Enabled"), 3)
  lu.assertStrContains(html, '<span class="chip disabled">Disabled</span>')
  lu.assertEquals(count_occurrences(html, "Inactive"), 2)
  lu.assertStrContains(html, 'placeholder="example.com"')
  lu.assertStrContains(html, '<option value="after_work">After work blocked</option>')
  lu.assertStrContains(html, '<div class="rule-line">alpha.example</div>')
  lu.assertStrContains(html, '<div class="rule-line">beta.example</div>')
  lu.assertStrContains(html, '<div class="rule-line">gamma.example</div>')
  lu.assertStrContains(html, "No workday-blocked domains.")
  lu.assertNil(html:find("<textarea", 1, true))
  lu.assertNil(html:find("Current router status", 1, true))
  lu.assertNil(html:find("Protection", 1, true))
  lu.assertNil(html:find("Enforcement", 1, true))
end
