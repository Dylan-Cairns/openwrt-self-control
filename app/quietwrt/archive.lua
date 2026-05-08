local M = {}

local UINT32_MAX = 4294967295
local CRC32_XOR = 3988292384
local DOS_TIME = string.char(0, 0)
local DOS_DATE = string.char(33, 0)

local crc32_table = nil

local function bit_xor(left, right)
  local result = 0
  local bit = 1

  while left > 0 or right > 0 do
    local left_bit = left % 2
    local right_bit = right % 2

    if left_bit ~= right_bit then
      result = result + bit
    end

    left = (left - left_bit) / 2
    right = (right - right_bit) / 2
    bit = bit * 2
  end

  return result
end

local function build_crc32_table()
  local table_values = {}

  for index = 0, 255 do
    local crc = index
    for _ = 1, 8 do
      if crc % 2 == 1 then
        crc = bit_xor((crc - 1) / 2, CRC32_XOR)
      else
        crc = crc / 2
      end
    end

    table_values[index + 1] = crc
  end

  return table_values
end

local function crc32(content)
  if crc32_table == nil then
    crc32_table = build_crc32_table()
  end

  local crc = UINT32_MAX
  for index = 1, #content do
    local byte = content:byte(index)
    local table_index = bit_xor(crc % 256, byte)
    crc = bit_xor((crc - (crc % 256)) / 256, crc32_table[table_index + 1])
  end

  return bit_xor(crc, UINT32_MAX)
end

local function le16(value)
  value = math.floor(value or 0)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function le32(value)
  value = math.floor(value or 0)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function read_u16(content, offset)
  local first = content:byte(offset) or 0
  local second = content:byte(offset + 1) or 0
  return first + (second * 256)
end

local function read_u32(content, offset)
  local first = content:byte(offset) or 0
  local second = content:byte(offset + 1) or 0
  local third = content:byte(offset + 2) or 0
  local fourth = content:byte(offset + 3) or 0
  return first + (second * 256) + (third * 65536) + (fourth * 16777216)
end

local function validate_file(file)
  if type(file) ~= "table" then
    return nil, "Archive file entries must be tables."
  end

  local name = tostring(file.name or "")
  if name == "" then
    return nil, "Archive file entries require a filename."
  end

  if name:find("/", 1, true) or name:find("\\", 1, true) or name:find("%z") then
    return nil, "Archive filenames must not contain path separators."
  end

  local content = tostring(file.content or "")
  if #name > 65535 then
    return nil, "Archive filename is too long: " .. name
  end

  if #content > UINT32_MAX then
    return nil, "Archive file is too large: " .. name
  end

  return {
    name = name,
    content = content,
    size = #content,
    crc32 = crc32(content),
  }, nil
end

function M.zip(files)
  local local_parts = {}
  local central_parts = {}
  local offset = 0
  local file_count = 0

  for _, raw_file in ipairs(files or {}) do
    local file, err = validate_file(raw_file)
    if not file then
      return nil, err
    end

    file_count = file_count + 1
    if file_count > 65535 then
      return nil, "ZIP archives support at most 65535 files."
    end

    local local_header = table.concat({
      "PK\003\004",
      le16(10),
      le16(0),
      le16(0),
      DOS_TIME,
      DOS_DATE,
      le32(file.crc32),
      le32(file.size),
      le32(file.size),
      le16(#file.name),
      le16(0),
      file.name,
    })

    local central_header = table.concat({
      "PK\001\002",
      le16(20),
      le16(10),
      le16(0),
      le16(0),
      DOS_TIME,
      DOS_DATE,
      le32(file.crc32),
      le32(file.size),
      le32(file.size),
      le16(#file.name),
      le16(0),
      le16(0),
      le16(0),
      le16(0),
      le32(0),
      le32(offset),
      file.name,
    })

    table.insert(local_parts, local_header)
    table.insert(local_parts, file.content)
    table.insert(central_parts, central_header)
    offset = offset + #local_header + #file.content
  end

  local central_directory = table.concat(central_parts)
  if offset > UINT32_MAX or #central_directory > UINT32_MAX then
    return nil, "ZIP archive is too large."
  end

  local end_record = table.concat({
    "PK\005\006",
    le16(0),
    le16(0),
    le16(file_count),
    le16(file_count),
    le32(#central_directory),
    le32(offset),
    le16(0),
  })

  table.insert(local_parts, central_directory)
  table.insert(local_parts, end_record)
  return table.concat(local_parts), nil
end

function M.unzip_stored(content)
  content = tostring(content or "")
  if #content == 0 then
    return nil, "ZIP archive is empty."
  end

  local entries = {}
  local offset = 1
  local file_count = 0

  while offset <= #content do
    local signature = content:sub(offset, offset + 3)
    if signature == "PK\001\002" or signature == "PK\005\006" then
      break
    end

    if signature ~= "PK\003\004" then
      return nil, "ZIP archive contains an invalid local file header."
    end

    local flags = read_u16(content, offset + 6)
    local method = read_u16(content, offset + 8)
    local expected_crc32 = read_u32(content, offset + 14)
    local compressed_size = read_u32(content, offset + 18)
    local uncompressed_size = read_u32(content, offset + 22)
    local name_length = read_u16(content, offset + 26)
    local extra_length = read_u16(content, offset + 28)
    local name_start = offset + 30
    local name_end = name_start + name_length - 1
    local data_start = name_end + extra_length + 1
    local data_end = data_start + compressed_size - 1

    if flags ~= 0 then
      return nil, "ZIP archive uses unsupported file flags."
    end

    if method ~= 0 then
      return nil, "ZIP archive uses unsupported compression."
    end

    if compressed_size ~= uncompressed_size then
      return nil, "ZIP archive contains a compressed-size mismatch."
    end

    if name_length == 0 or data_end > #content then
      return nil, "ZIP archive is truncated."
    end

    local name = content:sub(name_start, name_end)
    local file, validate_error = validate_file({
      name = name,
      content = content:sub(data_start, data_end),
    })
    if not file then
      return nil, validate_error
    end

    if file.crc32 ~= expected_crc32 then
      return nil, "ZIP archive CRC mismatch for " .. name .. "."
    end

    if entries[name] ~= nil then
      return nil, "ZIP archive contains duplicate file: " .. name
    end

    entries[name] = file.content
    file_count = file_count + 1
    offset = data_end + 1
  end

  if file_count == 0 then
    return nil, "ZIP archive contains no files."
  end

  return entries, nil
end

return M
