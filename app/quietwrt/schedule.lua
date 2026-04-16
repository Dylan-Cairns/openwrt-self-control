local M = {}

M.DEFAULT_WINDOWS = {
  workday = {
    start = "0400",
    ["end"] = "1630",
  },
  after_work = {
    start = "1630",
    ["end"] = "1900",
  },
  password_vault = {
    start = "0945",
    ["end"] = "0930",
  },
  overnight = {
    start = "1900",
    ["end"] = "0400",
  },
}

local WINDOW_LABELS = {
  workday = "Workday",
  after_work = "After work",
  password_vault = "Password vault",
  overnight = "Overnight",
}

local function minutes_of_day(time_table)
  return (time_table.hour * 60) + time_table.min
end

local function copy_window(definition)
  return {
    start = definition.start,
    ["end"] = definition["end"],
  }
end

function M.default_windows()
  return {
    workday = copy_window(M.DEFAULT_WINDOWS.workday),
    after_work = copy_window(M.DEFAULT_WINDOWS.after_work),
    password_vault = copy_window(M.DEFAULT_WINDOWS.password_vault),
    overnight = copy_window(M.DEFAULT_WINDOWS.overnight),
  }
end

function M.window_label(name)
  return WINDOW_LABELS[name] or tostring(name or "Window")
end

function M.normalize_hhmm(value)
  local text = tostring(value or ""):match("^%s*(.-)%s*$")
  if not text:match("^%d%d%d%d$") then
    return nil, "Use a 4-digit time in HHMM format."
  end

  local hour = tonumber(text:sub(1, 2))
  local min = tonumber(text:sub(3, 4))
  if hour == nil or min == nil or hour > 23 or min > 59 then
    return nil, "Use a valid 24-hour time in HHMM format."
  end

  return string.format("%02d%02d", hour, min)
end

function M.minutes_of_hhmm(value)
  local normalized, err = M.normalize_hhmm(value)
  if not normalized then
    return nil, err
  end

  local hour = tonumber(normalized:sub(1, 2))
  local min = tonumber(normalized:sub(3, 4))
  return (hour * 60) + min, nil, normalized
end

function M.format_hhmm(value)
  local normalized, err = M.normalize_hhmm(value)
  if not normalized then
    return nil, err
  end

  return normalized:sub(1, 2) .. ":" .. normalized:sub(3, 4), nil, normalized
end

function M.cron_spec(value)
  local normalized, err = M.normalize_hhmm(value)
  if not normalized then
    return nil, err
  end

  local hour = tonumber(normalized:sub(1, 2))
  local min = tonumber(normalized:sub(3, 4))
  return string.format("%d %d * * *", min, hour), nil, normalized
end

function M.build_window(name, start_value, end_value)
  local label = M.window_label(name)
  local start_minutes, start_error, start_normalized = M.minutes_of_hhmm(start_value)
  if start_minutes == nil then
    return nil, label .. " start time: " .. start_error
  end

  local end_minutes, end_error, end_normalized = M.minutes_of_hhmm(end_value)
  if end_minutes == nil then
    return nil, label .. " end time: " .. end_error
  end

  if start_normalized == end_normalized then
    return nil, label .. " start and end times must be different."
  end

  return {
    name = name,
    label = label,
    start = start_normalized,
    ["end"] = end_normalized,
    start_minutes = start_minutes,
    end_minutes = end_minutes,
    display_start = M.format_hhmm(start_normalized),
    display_end = M.format_hhmm(end_normalized),
    overnight = start_minutes > end_minutes,
  }
end

function M.window_contains(window, time_table)
  local minutes = minutes_of_day(time_table)
  if window.start_minutes < window.end_minutes then
    return minutes >= window.start_minutes and minutes < window.end_minutes
  end

  return minutes >= window.start_minutes or minutes < window.end_minutes
end

function M.window_summary(window)
  local summary = window.display_start .. " to " .. window.display_end
  if window.overnight then
    return summary .. " (overnight)"
  end
  return summary
end

return M
