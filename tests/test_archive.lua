local archive = require("quietwrt.archive")
local lu = require("luaunit")

TestArchive = {}

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

local function read_stored_entries(zip)
  local entries = {}
  local offset = 1

  while zip:sub(offset, offset + 3) == "PK\003\004" do
    local method = read_u16(zip, offset + 8)
    local compressed_size = read_u32(zip, offset + 18)
    local uncompressed_size = read_u32(zip, offset + 22)
    local name_length = read_u16(zip, offset + 26)
    local extra_length = read_u16(zip, offset + 28)
    local name = zip:sub(offset + 30, offset + 29 + name_length)
    local content_start = offset + 30 + name_length + extra_length
    local content_end = content_start + compressed_size - 1

    lu.assertEquals(method, 0)
    lu.assertEquals(compressed_size, uncompressed_size)
    entries[name] = zip:sub(content_start, content_end)
    offset = content_end + 1
  end

  return entries, offset
end

function TestArchive:test_zip_writes_valid_stored_file_entries()
  local zip, err = archive.zip({
    {
      name = "always-blocked.txt",
      content = "alpha.example\n",
    },
    {
      name = "workday-blocked.txt",
      content = "",
    },
  })

  lu.assertNil(err)
  lu.assertStrContains(zip, "PK\003\004")
  lu.assertStrContains(zip, "PK\001\002")
  lu.assertStrContains(zip, "PK\005\006")

  local entries, central_offset = read_stored_entries(zip)
  lu.assertEquals(entries["always-blocked.txt"], "alpha.example\n")
  lu.assertEquals(entries["workday-blocked.txt"], "")
  lu.assertEquals(zip:sub(central_offset, central_offset + 3), "PK\001\002")
end

function TestArchive:test_zip_rejects_path_like_filenames()
  local zip, err = archive.zip({
    {
      name = "../always-blocked.txt",
      content = "alpha.example\n",
    },
  })

  lu.assertNil(zip)
  lu.assertStrContains(err, "path separators")
end

function TestArchive:test_unzip_stored_reads_valid_export_entries()
  local zip = assert(archive.zip({
    {
      name = "always-blocked.txt",
      content = "alpha.example\n",
    },
    {
      name = "workday-blocked.txt",
      content = "work.example\n",
    },
  }))

  local entries, err = archive.unzip_stored(zip)

  lu.assertNil(err)
  lu.assertEquals(entries["always-blocked.txt"], "alpha.example\n")
  lu.assertEquals(entries["workday-blocked.txt"], "work.example\n")
end

function TestArchive:test_unzip_stored_rejects_unsupported_compression()
  local zip = assert(archive.zip({
    {
      name = "always-blocked.txt",
      content = "alpha.example\n",
    },
  }))
  zip = zip:sub(1, 8) .. string.char(8, 0) .. zip:sub(11)

  local entries, err = archive.unzip_stored(zip)

  lu.assertNil(entries)
  lu.assertStrContains(err, "unsupported compression")
end
