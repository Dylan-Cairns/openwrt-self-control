local cron = require("quietwrt.cron")
local enforcement = require("quietwrt.enforcement")
local firewall = require("quietwrt.firewall")
local lists_store = require("quietwrt.lists_store")
local rules = require("quietwrt.rules")
local runtime = require("quietwrt.runtime")
local schedule = require("quietwrt.schedule")
local settings_store = require("quietwrt.settings_store")
local status_render = require("quietwrt.status_render")

local M = {}

local function restore_previous_lists(context, previous_lists)
  local rollback_errors = {}

  local saved, save_error = lists_store.persist(context, previous_lists)
  if not saved then
    table.insert(rollback_errors, save_error)
    return rollback_errors
  end

  local restored, restore_error = M.apply_current_mode(context)
  if not restored then
    table.insert(rollback_errors, restore_error)
  end

  return rollback_errors
end

local function append_rollback_errors(message, rollback_errors)
  if rollback_errors == nil or #rollback_errors == 0 then
    return message
  end

  return message .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
end

local function rollback_install(context, rollback_state)
  local rollback_errors = {}

  if rollback_state.applied then
    local restore_ok, restore_error = enforcement.restore_config(
      context,
      rollback_state.original_adguard_config
    )
    if not restore_ok then
      table.insert(rollback_errors, restore_error)
    end

    local firewall_ok, firewall_error = firewall.commit_snapshot(
      context,
      rollback_state.original_firewall
    )
    if not firewall_ok then
      table.insert(rollback_errors, firewall_error)
    end
  end

  if rollback_state.schedule_changed then
    local schedule_ok, schedule_error = cron.restore_schedule(
      context,
      rollback_state.original_crontab
    )
    if not schedule_ok then
      table.insert(rollback_errors, schedule_error)
    end
  end

  if rollback_state.boot_service_changed then
    local boot_service_ok, boot_service_error = cron.restore_boot_sync_service(
      context,
      rollback_state.boot_service_enabled
    )
    if not boot_service_ok then
      table.insert(rollback_errors, boot_service_error)
    end
  end

  if rollback_state.bootstrapped_lists then
    local cleanup_ok, cleanup_error = lists_store.remove_bootstrapped_files(context)
    if not cleanup_ok then
      table.insert(rollback_errors, cleanup_error)
    end
  end

  if rollback_state.original_settings ~= nil then
    local settings_ok, settings_error = settings_store.persist_settings(context, rollback_state.original_settings)
    if not settings_ok then
      table.insert(rollback_errors, settings_error)
    end
  end

  return rollback_errors
end

local function status_snapshot(context)
  local install_state = settings_store.read_install_state(context)
  local now_table = context.env.now()

  if not install_state.installed then
    return runtime.uninstalled_snapshot(now_table), nil
  end

  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return nil, config_error
  end

  local settings, settings_error = settings_store.read_settings(context, true)
  if not settings then
    return nil, settings_error
  end

  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return nil, list_error
  end

  local activity, activity_error = runtime.build_runtime_activity(settings, now_table)
  if not activity then
    return nil, activity_error
  end

  local warnings = {}
  local enforcement_ready = enforcement.is_ready(context, parsed_config)
  local enforcement_warning = enforcement.enforcement_error(context, parsed_config)
  if enforcement_warning then
    table.insert(warnings, enforcement_warning)
  end

  local hardening = firewall.hardening_status(context)
  local snapshot = runtime.build_view_state(
    parsed_config,
    lists,
    settings,
    activity,
    hardening,
    true,
    enforcement_ready
  )
  snapshot.router_time = runtime.format_router_time(now_table)
  snapshot.install_state = install_state
  snapshot.warnings = warnings
  return snapshot, nil
end

local function apply_mode(context, options)
  options = options or {}

  if options.require_installed ~= false and not settings_store.detect_installed(context) then
    return false, "QuietWrt is not installed."
  end

  local parsed_config = options.parsed_config
  if not parsed_config then
    local config_error
    parsed_config, config_error = enforcement.read_state(context)
    if not parsed_config then
      return false, config_error
    end
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local lists = options.lists
  if not lists then
    local installed = options.installed
    if installed == nil then
      installed = true
    end

    local allow_bootstrap = options.allow_bootstrap == true
    local list_error
    lists, list_error = lists_store.load(context, parsed_config, {
      installed = installed,
      allow_bootstrap = allow_bootstrap,
    })
    if not lists then
      return false, list_error
    end
  end

  local settings = options.settings
  if settings == nil then
    local settings_error
    settings, settings_error = settings_store.read_settings(context, true)
    if not settings then
      return false, settings_error
    end
  end

  local activity, activity_error = runtime.build_runtime_activity(settings, context.env.now())
  if not activity then
    return false, activity_error
  end

  local active_always_hosts, active_scheduled_hosts = runtime.build_active_hosts(lists, settings, activity)
  local compiled_rules = rules.compile_active_rules(
    active_always_hosts,
    active_scheduled_hosts,
    lists.passthrough_rules
  )

  local adguard_ok, adguard_error, adguard_changed = enforcement.apply_rules(context, parsed_config, compiled_rules)
  if not adguard_ok then
    return false, adguard_error
  end

  local curfew_enabled = activity.overnight_active
  local previous_firewall = firewall.capture_snapshot(context)
  local desired_firewall = firewall.desired_snapshot(curfew_enabled)
  if not firewall.snapshots_equal(previous_firewall, desired_firewall) then
    local firewall_ok, firewall_error = firewall.commit_snapshot(context, desired_firewall)
    if not firewall_ok then
      local rollback_errors = {}

      if adguard_changed then
        local restore_ok, restore_error = enforcement.restore_config(context, parsed_config.content)
        if not restore_ok then
          table.insert(rollback_errors, restore_error)
        end
      end

      local firewall_restore_ok, firewall_restore_error = firewall.commit_snapshot(context, previous_firewall)
      if not firewall_restore_ok then
        table.insert(rollback_errors, firewall_restore_error)
      end

      if #rollback_errors == 0 then
        return false, firewall_error .. " Previous state was restored."
      end

      return false, firewall_error .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
    end
  end

  return true, {
    settings = settings,
    activity = activity,
    active_rule_count = #compiled_rules,
    bootstrapped = lists.bootstrapped,
  }
end

local function apply_settings_change(context, next_settings)
  if not settings_store.detect_installed(context) then
    return false, "QuietWrt is not installed."
  end

  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return false, config_error
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local current_settings, current_settings_error = settings_store.read_settings(context, true)
  if not current_settings then
    return false, current_settings_error
  end

  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return false, list_error
  end

  local original_crontab = context.env.read_file(context.paths.crontab_path)
  next_settings = settings_store.copy_settings(next_settings)

  local schedule_ok, schedule_error = cron.install_schedule(context, next_settings)
  if not schedule_ok then
    return false, schedule_error
  end

  local applied, apply_result = apply_mode(context, {
    parsed_config = parsed_config,
    lists = lists,
    settings = next_settings,
  })
  if not applied then
    local rollback_errors = {}
    local restored_schedule, restored_schedule_error = cron.restore_schedule(context, original_crontab)
    if not restored_schedule then
      table.insert(rollback_errors, restored_schedule_error)
    end
    return false, append_rollback_errors(apply_result, rollback_errors)
  end

  local settings_ok, settings_result = settings_store.persist_settings(context, next_settings)
  if not settings_ok then
    local rollback_errors = {}

    local restored_schedule, restored_schedule_error = cron.restore_schedule(context, original_crontab)
    if not restored_schedule then
      table.insert(rollback_errors, restored_schedule_error)
    end

    local restored_settings_ok, restored_settings_error = settings_store.persist_settings(context, current_settings)
    if not restored_settings_ok then
      table.insert(rollback_errors, restored_settings_error)
    end

    local restored, restore_error = apply_mode(context, {
      parsed_config = parsed_config,
      lists = lists,
      settings = current_settings,
    })
    if not restored then
      table.insert(rollback_errors, restore_error)
    end

    return false, append_rollback_errors(settings_result, rollback_errors)
  end

  return true, {
    settings = settings_result,
    active_rule_count = apply_result.active_rule_count,
  }
end

function M.load_view_state(context)
  local snapshot, err = status_snapshot(context)
  if not snapshot then
    return nil, err
  end

  if not snapshot.installed then
    return nil, "QuietWrt is not installed."
  end

  if #snapshot.warnings > 0 then
    return nil, snapshot.warnings[1]
  end

  return snapshot, nil
end

function M.apply_current_mode(context)
  return apply_mode(context, {
    require_installed = true,
  })
end

function M.add_entry(context, destination, raw_value)
  if not settings_store.detect_installed(context) then
    return {
      ok = false,
      kind = "error",
      message = "QuietWrt is not installed.",
    }
  end

  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return {
      ok = false,
      kind = "error",
      message = config_error,
    }
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return {
      ok = false,
      kind = "error",
      message = enforcement_check_error,
    }
  end

  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return {
      ok = false,
      kind = "error",
      message = list_error,
    }
  end

  local previous_lists = lists_store.clone(lists)
  local result = rules.apply_addition(
    lists.always_hosts,
    {
      workday = lists.workday_hosts,
      after_work = lists.after_work_hosts,
      password_vault = lists.password_vault_hosts,
    },
    destination,
    raw_value
  )

  if not result.ok then
    return result
  end

  local saved, save_error = lists_store.persist(context, {
    always_hosts = result.always_hosts,
    workday_hosts = result.workday_hosts,
    after_work_hosts = result.after_work_hosts,
    password_vault_hosts = result.password_vault_hosts,
    passthrough_rules = lists.passthrough_rules,
  })
  if not saved then
    return {
      ok = false,
      kind = "error",
      message = save_error,
    }
  end

  local applied, apply_result = M.apply_current_mode(context)
  if not applied then
    local rollback_errors = restore_previous_lists(context, previous_lists)
    local message = apply_result
    if #rollback_errors > 0 then
      message = message .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
    end

    return {
      ok = false,
      kind = "error",
      message = message,
    }
  end

  result.active_rule_count = apply_result.active_rule_count
  return result
end

function M.install(context)
  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return false, config_error
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local install_state = settings_store.read_install_state(context)
  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = install_state.installed,
    allow_bootstrap = not install_state.installed,
  })
  if not lists then
    return false, list_error
  end

  local staged_settings
  if install_state.installed then
    local settings_error
    staged_settings, settings_error = settings_store.read_settings(context, true)
    if not staged_settings then
      return false, settings_error
    end
  else
    staged_settings = settings_store.seed_install_settings(context)
  end

  local original_settings = nil
  if install_state.installed then
    original_settings = settings_store.copy_settings(staged_settings)
  end

  local rollback_state = {
    original_crontab = context.env.read_file(context.paths.crontab_path),
    boot_service_enabled = context.env.file_exists(context.paths.init_service_enabled_path),
    bootstrapped_lists = lists.bootstrapped == true,
    original_adguard_config = parsed_config.content,
    original_firewall = firewall.capture_snapshot(context),
    original_settings = original_settings,
    schedule_changed = true,
    boot_service_changed = false,
    applied = false,
  }

  local schedule_ok, schedule_error = cron.install_schedule(context, staged_settings)
  if not schedule_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(schedule_error, rollback_errors)
  end

  local boot_service_ok, boot_service_error = cron.enable_boot_sync_service(context)
  if not boot_service_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(boot_service_error, rollback_errors)
  end
  rollback_state.boot_service_changed = true

  local applied, apply_result = apply_mode(context, {
    require_installed = false,
    parsed_config = parsed_config,
    lists = lists,
    settings = staged_settings,
  })
  if not applied then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(apply_result, rollback_errors)
  end
  rollback_state.applied = true

  local settings_ok, settings_result = settings_store.persist_settings(context, staged_settings)
  if not settings_ok then
    local rollback_errors = rollback_install(context, rollback_state)
    return false, append_rollback_errors(settings_result, rollback_errors)
  end

  return true, {
    settings = settings_result,
    active_rule_count = apply_result.active_rule_count,
    bootstrapped = lists.bootstrapped,
  }
end

function M.set_toggle(context, toggle_name, enabled)
  local settings, err = settings_store.read_settings(context, settings_store.detect_installed(context))
  if not settings then
    return false, err
  end

  if toggle_name == "always" then
    settings.always_enabled = enabled
  elseif toggle_name == "workday" then
    settings.workday_enabled = enabled
  elseif toggle_name == "after_work" then
    settings.after_work_enabled = enabled
  elseif toggle_name == "password_vault" then
    settings.password_vault_enabled = enabled
  elseif toggle_name == "overnight" then
    settings.overnight_enabled = enabled
  else
    return false, "Unknown toggle: " .. tostring(toggle_name)
  end

  return apply_settings_change(context, settings)
end

function M.set_schedule(context, schedule_name, start_value, end_value)
  local settings, err = settings_store.read_settings(context, settings_store.detect_installed(context))
  if not settings then
    return false, err
  end

  local updated_window, window_error = schedule.build_window(schedule_name, start_value, end_value)
  if not updated_window then
    return false, window_error
  end

  if schedule_name == "workday" then
    settings.workday_start = updated_window.start
    settings.workday_end = updated_window["end"]
  elseif schedule_name == "after_work" then
    settings.after_work_start = updated_window.start
    settings.after_work_end = updated_window["end"]
  elseif schedule_name == "password_vault" then
    settings.password_vault_start = updated_window.start
    settings.password_vault_end = updated_window["end"]
  elseif schedule_name == "overnight" then
    settings.overnight_start = updated_window.start
    settings.overnight_end = updated_window["end"]
  else
    return false, "Unknown schedule: " .. tostring(schedule_name)
  end

  return apply_settings_change(context, settings)
end

function M.restore_lists(context, restore_paths)
  if not settings_store.detect_installed(context) then
    return false, "QuietWrt is not installed."
  end

  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return false, config_error
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return false, enforcement_check_error
  end

  local current_lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not current_lists then
    return false, list_error
  end

  local replacements = {}
  local selected_count = 0

  if restore_paths.always_path then
    local always_content = context.env.read_file(restore_paths.always_path)
    if always_content == nil then
      return false, "Could not read " .. restore_paths.always_path .. "."
    end

    local always_hosts, always_error = rules.load_hosts_file(always_content, restore_paths.always_path)
    if not always_hosts then
      return false, always_error
    end

    replacements.always_hosts = always_hosts
    selected_count = selected_count + 1
  end

  if restore_paths.workday_path then
    local workday_content = context.env.read_file(restore_paths.workday_path)
    if workday_content == nil then
      return false, "Could not read " .. restore_paths.workday_path .. "."
    end

    local workday_hosts, workday_error = rules.load_hosts_file(workday_content, restore_paths.workday_path)
    if not workday_hosts then
      return false, workday_error
    end

    replacements.workday_hosts = workday_hosts
    selected_count = selected_count + 1
  end

  if restore_paths.after_work_path then
    local after_work_content = context.env.read_file(restore_paths.after_work_path)
    if after_work_content == nil then
      return false, "Could not read " .. restore_paths.after_work_path .. "."
    end

    local after_work_hosts, after_work_error = rules.load_hosts_file(after_work_content, restore_paths.after_work_path)
    if not after_work_hosts then
      return false, after_work_error
    end

    replacements.after_work_hosts = after_work_hosts
    selected_count = selected_count + 1
  end

  if restore_paths.password_vault_path then
    local password_vault_content = context.env.read_file(restore_paths.password_vault_path)
    if password_vault_content == nil then
      return false, "Could not read " .. restore_paths.password_vault_path .. "."
    end

    local password_vault_hosts, password_vault_error = rules.load_hosts_file(
      password_vault_content,
      restore_paths.password_vault_path
    )
    if not password_vault_hosts then
      return false, password_vault_error
    end

    replacements.password_vault_hosts = password_vault_hosts
    selected_count = selected_count + 1
  end

  if selected_count == 0 then
    return false, "Provide at least one restore file."
  end

  local previous_lists = lists_store.clone(current_lists)
  local saved, save_error = lists_store.persist_selected(context, replacements)
  if not saved then
    return false, save_error
  end

  local applied, apply_result = M.apply_current_mode(context)
  if not applied then
    local rollback_errors = restore_previous_lists(context, previous_lists)
    if #rollback_errors == 0 then
      return false, apply_result
    end
    return false, apply_result .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
  end

  return true, {
    active_rule_count = apply_result.active_rule_count,
  }
end

function M.status(context, options)
  local snapshot, err = status_snapshot(context)
  if not snapshot then
    return false, err
  end

  if options and options.json then
    return true, status_render.render_json(snapshot)
  end

  return true, status_render.render_text(snapshot)
end

return M
