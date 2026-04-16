local enforcement = require("quietwrt.enforcement")
local firewall = require("quietwrt.firewall")
local lists_store = require("quietwrt.lists_store")
local runtime = require("quietwrt.runtime")
local settings_store = require("quietwrt.settings_store")
local status_render = require("quietwrt.status_render")

local M = {}

local function status_snapshot(context)
  local install_state = settings_store.read_install_state(context)
  local now_table = context.env.now()

  if not install_state.installed then
    local snapshot = runtime.uninstalled_snapshot(now_table)
    snapshot.schema_version = install_state.schema_version
    return snapshot, nil
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
  snapshot.schema_version = install_state.schema_version or snapshot.schema_version
  snapshot.install_state = install_state
  snapshot.warnings = warnings
  return snapshot, nil
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
