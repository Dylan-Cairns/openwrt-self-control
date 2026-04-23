local archive = require("quietwrt.archive")
local schema = require("quietwrt.schema")
local settings_store = require("quietwrt.settings_store")

local M = {}

local function read_blocklist_files(context)
  local files = {}

  for _, definition in ipairs(schema.HOST_LISTS) do
    local path = context.paths[definition.path_key]
    local content = context.env.read_file(path)

    if content == nil then
      return nil, "QuietWrt blocklist source file is missing: " .. path
    end

    table.insert(files, {
      name = definition.file_name,
      content = content,
    })
  end

  return files, nil
end

function M.download_blocklists_archive(context, format)
  if format ~= "zip" then
    return false, "Only ZIP downloads are supported."
  end

  if not settings_store.detect_installed(context) then
    return false, "QuietWrt is not installed."
  end

  local files, file_error = read_blocklist_files(context)
  if not files then
    return false, file_error
  end

  local content, archive_error = archive.zip(files)
  if not content then
    return false, archive_error
  end

  return true, {
    content_type = "application/zip",
    filename = "quietwrt-blocklists.zip",
    content = content,
  }
end

return M
