local M = {}

local function minutes_of_day(time_table)
  return (time_table.hour * 60) + time_table.min
end

function M.mode_at(time_table)
  local minutes = minutes_of_day(time_table)

  if minutes >= (18 * 60 + 30) or minutes < (4 * 60) then
    return {
      code = "internet_off",
      label = "Internet off",
      description = "LAN to WAN internet access is blocked until 04:00.",
    }
  end

  if minutes >= (16 * 60 + 30) then
    return {
      code = "always_only",
      label = "Always only",
      description = "Only the Always blocked list is active until 18:30.",
    }
  end

  return {
    code = "always_and_workday",
    label = "Always + Workday",
    description = "Both Always blocked and Workday blocked are active.",
  }
end

return M
