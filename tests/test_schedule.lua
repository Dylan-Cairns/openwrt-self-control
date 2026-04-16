local helper = require("test_helper")
local lu = require("luaunit")
local schedule = require("quietwrt.schedule")

TestSchedule = {}

function TestSchedule:test_rejects_invalid_hhmm()
  local normalized, err = schedule.normalize_hhmm("2460")
  lu.assertNil(normalized)
  lu.assertStrContains(err, "valid 24-hour time")
end

function TestSchedule:test_build_window_formats_same_day_ranges()
  local window = schedule.build_window("workday", "0400", "1630")
  lu.assertEquals(window.display_start, "04:00")
  lu.assertEquals(window.display_end, "16:30")
  lu.assertFalse(window.overnight)
end

function TestSchedule:test_build_window_marks_wraparound_ranges_as_overnight()
  local window = schedule.build_window("overnight", "1900", "0400")
  lu.assertTrue(window.overnight)
  lu.assertEquals(schedule.window_summary(window), "19:00 to 04:00 (overnight)")
end

function TestSchedule:test_default_password_vault_window_is_overnight()
  local defaults = schedule.default_windows()
  local window = schedule.build_window("password_vault", defaults.password_vault.start, defaults.password_vault["end"])
  lu.assertTrue(window.overnight)
  lu.assertEquals(schedule.window_summary(window), "09:45 to 09:30 (overnight)")
end

function TestSchedule:test_rejects_equal_start_and_end_times()
  local window, err = schedule.build_window("workday", "1200", "1200")
  lu.assertNil(window)
  lu.assertStrContains(err, "must be different")
end

function TestSchedule:test_window_contains_same_day_ranges()
  local window = schedule.build_window("workday", "0400", "1630")
  lu.assertTrue(schedule.window_contains(window, { hour = 4, min = 0 }))
  lu.assertTrue(schedule.window_contains(window, { hour = 16, min = 29 }))
  lu.assertFalse(schedule.window_contains(window, { hour = 16, min = 30 }))
end

function TestSchedule:test_window_contains_wraparound_ranges()
  local window = schedule.build_window("overnight", "1900", "0400")
  lu.assertTrue(schedule.window_contains(window, { hour = 20, min = 0 }))
  lu.assertTrue(schedule.window_contains(window, { hour = 3, min = 59 }))
  lu.assertFalse(schedule.window_contains(window, { hour = 4, min = 0 }))
end
