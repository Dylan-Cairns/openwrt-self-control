local util = require("quietwrt.util")

local M = {}

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
    "Workday window: " .. (
      schedule_snapshot.workday and (schedule_snapshot.workday.display_start .. " to "
        .. schedule_snapshot.workday.display_end
        .. (schedule_snapshot.workday.overnight and " (overnight)" or ""))
      or "unknown"
    ),
    "After work enabled: " .. (snapshot.settings.after_work_enabled and "yes" or "no"),
    "After work active now: " .. (snapshot.after_work_active and "yes" or "no"),
    "After work window: " .. (
      schedule_snapshot.after_work and (schedule_snapshot.after_work.display_start .. " to "
        .. schedule_snapshot.after_work.display_end
        .. (schedule_snapshot.after_work.overnight and " (overnight)" or ""))
      or "unknown"
    ),
    "Password vault enabled: " .. (snapshot.settings.password_vault_enabled and "yes" or "no"),
    "Password vault active now: " .. (snapshot.password_vault_active and "yes" or "no"),
    "Password vault window: " .. (
      schedule_snapshot.password_vault and (schedule_snapshot.password_vault.display_start .. " to "
        .. schedule_snapshot.password_vault.display_end
        .. (schedule_snapshot.password_vault.overnight and " (overnight)" or ""))
      or "unknown"
    ),
    "Overnight enabled: " .. (snapshot.settings.overnight_enabled and "yes" or "no"),
    "Overnight active now: " .. (snapshot.overnight_active and "yes" or "no"),
    "Overnight window: " .. (
      schedule_snapshot.overnight and (schedule_snapshot.overnight.display_start .. " to "
        .. schedule_snapshot.overnight.display_end
        .. (schedule_snapshot.overnight.overnight and " (overnight)" or ""))
      or "unknown"
    ),
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
