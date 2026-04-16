local util = require("quietwrt.util")

local M = {}

local function window_summary(window)
  if window == nil then
    return "unknown"
  end

  if window.summary ~= nil and window.summary ~= "" then
    return window.summary
  end

  return window.display_start .. " to "
    .. window.display_end
    .. (window.overnight and " (overnight)" or "")
end

function M.render_text(snapshot)
  local schedule_snapshot = snapshot.schedule or {}
  local lines = {
    "Installed: " .. (snapshot.installed and "yes" or "no"),
    "Router time: " .. (snapshot.router_time or "Unknown"),
    "Protection: " .. (
      snapshot.protection_enabled == true and "enabled"
      or snapshot.protection_enabled == false and "disabled"
      or "unknown"
    ),
    "Enforcement ready: " .. (snapshot.enforcement_ready and "yes" or "no"),
    "Always enabled: " .. (snapshot.settings.always_enabled and "yes" or "no"),
    "Workday enabled: " .. (snapshot.settings.workday_enabled and "yes" or "no"),
    "Workday active now: " .. (snapshot.workday_active and "yes" or "no"),
    "Workday window: " .. window_summary(schedule_snapshot.workday),
    "After work enabled: " .. (snapshot.settings.after_work_enabled and "yes" or "no"),
    "After work active now: " .. (snapshot.after_work_active and "yes" or "no"),
    "After work window: " .. window_summary(schedule_snapshot.after_work),
    "Password vault enabled: " .. (snapshot.settings.password_vault_enabled and "yes" or "no"),
    "Password vault active now: " .. (snapshot.password_vault_active and "yes" or "no"),
    "Password vault window: " .. window_summary(schedule_snapshot.password_vault),
    "Overnight enabled: " .. (snapshot.settings.overnight_enabled and "yes" or "no"),
    "Overnight active now: " .. (snapshot.overnight_active and "yes" or "no"),
    "Overnight window: " .. window_summary(schedule_snapshot.overnight),
    "Always blocked: " .. tostring(#snapshot.always_hosts),
    "Workday blocked: " .. tostring(#snapshot.workday_hosts),
    "After work blocked: " .. tostring(#snapshot.after_work_hosts),
    "Password vault blocked: " .. tostring(#snapshot.password_vault_hosts),
    "Active rules: " .. tostring(snapshot.active_rule_count),
    "DNS intercept hardening: " .. (snapshot.hardening.dns_intercept and "yes" or "no"),
    "DoT block hardening: " .. (snapshot.hardening.dot_block and "yes" or "no"),
    "Overnight rule present: " .. (snapshot.hardening.overnight_rule and "yes" or "no"),
  }

  if #snapshot.warnings > 0 then
    table.insert(lines, "Warnings: " .. table.concat(snapshot.warnings, " | "))
  end

  return table.concat(lines, "\n")
end

function M.render_json(snapshot)
  return util.json_encode({
    schema_version = snapshot.schema_version,
    installed = snapshot.installed,
    router_time = snapshot.router_time,
    protection_enabled = snapshot.protection_enabled,
    enforcement_ready = snapshot.enforcement_ready,
    always_enabled = snapshot.settings.always_enabled,
    workday_enabled = snapshot.settings.workday_enabled,
    after_work_enabled = snapshot.settings.after_work_enabled,
    password_vault_enabled = snapshot.settings.password_vault_enabled,
    overnight_enabled = snapshot.settings.overnight_enabled,
    workday_window_active = snapshot.workday_window_active,
    after_work_window_active = snapshot.after_work_window_active,
    password_vault_window_active = snapshot.password_vault_window_active,
    overnight_window_active = snapshot.overnight_window_active,
    workday_active = snapshot.workday_active,
    after_work_active = snapshot.after_work_active,
    password_vault_active = snapshot.password_vault_active,
    overnight_active = snapshot.overnight_active,
    schedule = snapshot.schedule,
    always_count = #snapshot.always_hosts,
    workday_count = #snapshot.workday_hosts,
    after_work_count = #snapshot.after_work_hosts,
    password_vault_count = #snapshot.password_vault_hosts,
    active_rule_count = snapshot.active_rule_count,
    hardening = snapshot.hardening,
    warnings = snapshot.warnings,
  })
end

return M
