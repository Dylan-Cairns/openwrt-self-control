local M = {}

M.SCHEMA_VERSION = "4"

M.MANAGED_FIREWALL_SECTIONS = {
  "quietwrt_dns_int",
  "quietwrt_dot_fwd",
  "quietwrt_curfew",
}

M.HOST_LISTS = {
  { name = "always", key = "always_hosts", path_key = "always_list_path", file_name = "always-blocked.txt" },
  { name = "workday", key = "workday_hosts", path_key = "workday_list_path", file_name = "workday-blocked.txt" },
  { name = "after_work", key = "after_work_hosts", path_key = "after_work_list_path", file_name = "after-work-blocked.txt" },
  { name = "password_vault", key = "password_vault_hosts", path_key = "password_vault_list_path", file_name = "password-vault-blocked.txt" },
}

M.SCHEDULES = {
  { name = "workday", start_key = "workday_start", end_key = "workday_end" },
  { name = "after_work", start_key = "after_work_start", end_key = "after_work_end" },
  { name = "password_vault", start_key = "password_vault_start", end_key = "password_vault_end" },
  { name = "overnight", start_key = "overnight_start", end_key = "overnight_end" },
}

M.TOGGLES = {
  { name = "always", key = "always_enabled" },
  { name = "workday", key = "workday_enabled" },
  { name = "after_work", key = "after_work_enabled" },
  { name = "password_vault", key = "password_vault_enabled" },
  { name = "overnight", key = "overnight_enabled" },
  { name = "saturday_blockout", key = "saturday_blockout_enabled" },
}

return M
