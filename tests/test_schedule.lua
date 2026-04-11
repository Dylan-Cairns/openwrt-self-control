local helper = require("test_helper")
local lu = require("luaunit")
local schedule = require("quietwrt.schedule")

TestSchedule = {}

function TestSchedule:test_before_four_am_is_internet_off()
  lu.assertEquals(schedule.mode_at({ hour = 3, min = 59 }).code, "internet_off")
end

function TestSchedule:test_four_am_turns_workday_back_on()
  lu.assertEquals(schedule.mode_at({ hour = 4, min = 0 }).code, "always_and_workday")
end

function TestSchedule:test_four_thirty_pm_switches_to_always_only()
  lu.assertEquals(schedule.mode_at({ hour = 16, min = 30 }).code, "always_only")
end

function TestSchedule:test_six_thirty_pm_shuts_off_internet()
  lu.assertEquals(schedule.mode_at({ hour = 18, min = 30 }).code, "internet_off")
end
