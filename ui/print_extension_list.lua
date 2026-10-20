-- Print Extension List (print_extension_list)
-- Logs the game version, the current resolution/UI settings, and the list of enabled
-- DLCs/extensions with their versions to the debug log once, when the UI environment loads.
-- Compatible with X4 8.00+.

local ffi = require("ffi")
local C   = ffi.C
local utf8 = require("utf8")

-- Declared one at a time on purpose: another addon may already have declared any of these,
-- and a duplicate must not take the remaining declarations of a shared block down with it.
for _, declaration in ipairs({
  "float GetUIScale(const bool scalewithresolution);",
  "float GetUIScaleFactor(void);",
  "float GetMenuWidthScale(void);",
}) do
  pcall(ffi.cdef, declaration)
end

-- Engine logger locator, kept identical to lua_log_api so both share the __LUA_LOG_API_ENGINE record.
local P = ffi.typeof("uint8_t*")
local RECORD_VERSION = 2
local CATEGORY, CATEGORY_VERBOSE = "UI", "UI_Verbose"
-- namesAt only accepts a table whose entry 0 is "General"
local CATEGORY_GENERAL = 0
local LEVEL_INFO = 0

-- exports that call the engine error wrapper early in their body; the first three are declared by ui/widget,
-- which loads before any addon. Never cdef'd here: a second declaration breaks whichever file declares later.
local ANCHORS = { "CopyToClipboard", "GetTextWidth", "GetConfigSetting", "ConvertStringTo64Bit" }

-- engine error wrapper, identical in 8.00 and 9.00: core(*logger, fmt, va, category 0, level 2, nested 0);
-- false = masked: rel32 of the logger global at 27, je offset at 35, rel32 of the core at 64
---@type (integer|false)[]
local WRAPPER = { 0x48, 0x89, 0x4c, 0x24, 0x08, 0x48, 0x89, 0x54, 0x24, 0x10, 0x4c, 0x89, 0x44, 0x24, 0x18,
  0x4c, 0x89, 0x4c, 0x24, 0x20, 0x48, 0x83, 0xec, 0x38, 0x48, 0x8b, 0x05, false, false, false, false,
  0x48, 0x85, 0xc0, 0x74, false, 0x48, 0x8b, 0xd1, 0xc6, 0x44, 0x24, 0x28, 0x00, 0x48, 0x8b, 0xc8,
  0xc7, 0x44, 0x24, 0x20, 0x02, 0x00, 0x00, 0x00, 0x4c, 0x8d, 0x44, 0x24, 0x48, 0x45, 0x33, 0xc9,
  0xe8, false, false, false, false }

-- file-log formatter: cmp r8d,N; ja; movsxd rax,r8d; lea rbx,[category names]
---@type (integer|false)[]
local NAMES = { 0x41, 0x83, 0xf8, false, 0x77, false, 0x49, 0x63, 0xc0, 0x48, 0x8d, 0x1d, false, false, false, false }

-- nil: not located yet, false: unavailable, table: located
---@type table|false|nil
local engine
local currentBuild
local va = ffi.new("const char*[1]")

local function u16(p) return ffi.cast("uint16_t*", p)[0] end
local function u32(p) return ffi.cast("uint32_t*", p)[0] end
local function i32(p) return ffi.cast("int32_t*", p)[0] end
local function hex(n) return string.format("0x%x", tonumber(n)) end

local function match(p, bytes)
  for k = 1, #bytes do
    if bytes[k] and p[k - 1] ~= bytes[k] then return false end
  end
  return true
end

local function findAnchor()
  for _, name in ipairs(ANCHORS) do
    local ok, f = pcall(function() return C[name] end)
    if ok and f ~= nil then return ffi.cast("uintptr_t", f) end
  end
  return nil
end

-- The exe image and its sections as RVA ranges: to = the file-backed part, vto = the whole section.
local function mapImage(anchor)
  -- the walk below the image would read unmapped memory in the native Linux build
  if ffi.os ~= "Windows" then return nil, "not the Windows build" end
  local a = anchor - anchor % 0x10000
  local base
  for _ = 1, 4096 do
    local p = ffi.cast(P, a)
    if p[0] == 0x4d and p[1] == 0x5a and u32(p + i32(p + 0x3c)) == 0x4550 then
      base = p
      break
    end
    a = a - 0x10000
  end
  if not base then return nil, "image base not found" end
  local pe = base + i32(base + 0x3c)
  local opt = pe + 24
  local img = { base = base, sec = {} }
  -- timestamp, checksum, image size: what a cached result is tied to
  img.id = string.format("%x-%x-%x", u32(pe + 8), u32(opt + 64), u32(opt + 56))
  -- exception directory: every function's start and end, sorted
  img.pdata, img.pdataCount = u32(opt + 112 + 3 * 8), math.floor(u32(opt + 112 + 3 * 8 + 4) / 12)
  local s = opt + u16(pe + 20)
  for i = 0, u16(pe + 6) - 1 do
    local h = s + i * 40
    local n = {}
    for k = 0, 7 do
      if h[k] ~= 0 then n[#n + 1] = string.char(h[k]) end
    end
    local from, vsize, raw = u32(h + 12), u32(h + 8), u32(h + 16)
    img.sec[table.concat(n)] = { from = from, to = from + math.min(vsize, raw), vto = from + vsize }
  end
  if not (img.sec[".text"] and img.sec[".rdata"] and img.sec[".data"]) then
    return nil, "image sections missing"
  end
  if img.pdataCount == 0 then return nil, "no exception directory" end
  img.anchor = tonumber(anchor - ffi.cast("uintptr_t", base))
  return img
end

local function inSection(sec, rva, len)
  return rva >= sec.from and rva + (len or 8) <= sec.to
end

-- The start of the function containing rva, from .pdata, or nil.
local function functionOf(img, rva)
  local lo, hi = 0, img.pdataCount - 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local entry = img.base + img.pdata + mid * 12
    local from, to = u32(entry), u32(entry + 4)
    if rva < from then
      hi = mid - 1
    elseif rva >= to then
      lo = mid + 1
    else
      return from
    end
  end
end

local function cString(img, rva, max)
  local rd, b = img.sec[".rdata"], img.base
  local n = 0
  while n < max do
    if not inSection(rd, rva + n, 1) then return nil end
    local c = b[rva + n]
    if c == 0 then break end
    if c < 0x20 or c > 0x7e then return nil end
    n = n + 1
  end
  if n == 0 or n == max then return nil end
  return ffi.string(b + rva, n)
end

-- logger global and core function RVAs when rva is the error wrapper, or nil
local function wrapperAt(img, rva)
  if not inSection(img.sec[".text"], rva, #WRAPPER) or functionOf(img, rva) ~= rva then return nil end
  if not match(img.base + rva, WRAPPER) then return nil end
  local logger = rva + 31 + i32(img.base + rva + 27)
  local data = img.sec[".data"]
  if logger < data.from or logger + 8 > data.vto then return nil end
  local core = rva + #WRAPPER + i32(img.base + rva + 64)
  if functionOf(img, core) ~= core then return nil end
  return logger, core
end

-- the category names table at o: its RVA and the indexes of CATEGORY and CATEGORY_VERBOSE (nil if absent), or nil
local function namesAt(img, o)
  if not inSection(img.sec[".text"], o, #NAMES) or not match(img.base + o, NAMES) then return nil end
  local tableRva = o + #NAMES + i32(img.base + o + 12)
  local count = img.base[o + 3] + 1
  if not inSection(img.sec[".rdata"], tableRva, count * 8) then return nil end
  local entries = ffi.cast("uint64_t*", img.base + tableRva)
  local imageBase = ffi.cast("uintptr_t", img.base)
  local index, verbose
  for i = 0, count - 1 do
    local name = cString(img, tonumber(entries[i] - imageBase), 64)
    if not name or (i == 0 and name ~= "General") then return nil end
    if name == CATEGORY then index = i end
    if name == CATEGORY_VERBOSE then verbose = i end
  end
  if index then return tableRva, index, verbose end
end

local function search(img, build)
  local wrapper, logger, core
  for o = img.anchor, img.anchor + 0x200 do
    if img.base[o] == 0xe8 and inSection(img.sec[".text"], o, 5) then
      local t = o + 5 + i32(img.base + o + 1)
      logger, core = wrapperAt(img, t)
      if logger then
        wrapper = t
        break
      end
    end
  end
  if not wrapper then return { build = build, found = false, reason = "engine error wrapper not found from " .. hex(img.anchor) } end
  -- the file-log formatter sits in the same unit as the wrapper
  for o = wrapper, wrapper + 0x1000 do
    if img.base[o] == 0x41 and img.base[o + 1] == 0x83 then
      local tableRva, index, verbose = namesAt(img, o)
      if tableRva then
        return { build = build, found = true, wrapper = wrapper, logger = logger, core = core, names = o, category = index, verbose = verbose }
      end
    end
  end
  return { build = build, found = false, reason = "log category " .. CATEGORY .. " not found" }
end

local function verifyCached(img, c)
  local logger, core = wrapperAt(img, c.wrapper)
  if logger ~= c.logger or core ~= c.core then return false end
  local _, index, verbose = namesAt(img, c.names)
  return index == c.category and verbose == c.verbose
end

local function store(record)
  if record then record.v = RECORD_VERSION end
  ---@diagnostic disable-next-line: global-in-non-module
  __LUA_LOG_API_ENGINE = record
  -- declared by vanilla addons; one that has not loaded yet only delays the write to the next uidata save
  pcall(function() C.SaveUIUserData() end)
end

-- Returns a located engine, nil to retry on the next write (no anchor declared yet), or false and the reason.
---@return table|false|nil, string?
local function detect()
  local anchor = findAnchor()
  if not anchor then return nil end
  local img, why = mapImage(anchor)
  if not img then return false, why end
  local build = GetVersionString() .. " " .. img.id
  currentBuild = build
  local c = __LUA_LOG_API_ENGINE
  if type(c) ~= "table" or c.build ~= build or c.v ~= RECORD_VERSION then c = nil end
  if c and not c.found then return false, "cached: " .. tostring(c.reason) end
  -- a crash while reading leaves this record behind, so the build is not read again
  store({ build = build, found = false, reason = "the game stopped while the engine logger was searched" })
  if not (c and verifyCached(img, c)) then
    c = search(img, build)
  end
  store(c)
  if not c.found then return false, "searched: " .. tostring(c.reason) end
  return {
    logger = ffi.cast("void**", img.base + c.logger),
    core = ffi.cast("void(*)(void*, const char*, void*, int32_t, int32_t, uint8_t)", img.base + c.core),
  }
end

local function locate()
  local ok, result, reason = pcall(detect)
  if not ok then
    reason = "error: " .. tostring(result)
    if currentBuild then pcall(store, { build = currentBuild, found = false, reason = reason }) end
    engine = false
  else
    engine = result
  end
  if engine == false then
    DebugError("PrintExtensionList: engine logger unavailable (" .. tostring(reason) .. "), writing through DebugError instead")
  end
end

-- One "[General] <time> <text>" line; DebugError where the engine logger is not located.
local function logInfo(text)
  text = tostring(text)
  if engine == nil then locate() end
  if engine then
    local logger = engine.logger[0]
    if logger ~= nil then
      va[0] = text
      engine.core(logger, "%s", va, CATEGORY_GENERAL, LEVEL_INFO, 0)
      va[0] = nil
      return
    end
  end
  DebugError(text)
end

-- Splits a pure-digit string into 2-digit groups counted from the right, leftmost group 1-2 digits.
local function splitDigitsIntoGroups(digits)
  local groups = {}
  local i = #digits
  while i > 0 do
    local from = math.max(1, i - 1)
    table.insert(groups, 1, digits:sub(from, i))
    i = from - 1
  end
  return groups
end

-- Extension versions are stored as concatenated major+minor(+patch) digits, e.g. "800.02"
-- meaning major 8, minor 00, patch 02. Reformats each dot-separated segment longer than
-- 2 digits into proper 2-digit groups, e.g. "800.02" -> "8.00.02", "100" -> "1.00".
-- Segments already 2 digits or shorter (e.g. "1.0") are left untouched.
local function formatVersion(raw)
  if raw == nil then
    return ""
  end
  local outParts = {}
  for part in tostring(raw):gmatch("[^.]+") do
    if #part > 2 and part:match("^%d+$") then
      for _, group in ipairs(splitDigitsIntoGroups(part)) do
        outParts[#outParts + 1] = group
      end
    else
      outParts[#outParts + 1] = part
    end
  end
  return table.concat(outParts, ".")
end

-- Character count (not byte count) of a string, so names/authors with accented or
-- non-Latin UTF-8 characters don't get over-counted relative to their on-screen width.
-- Falls back to byte length if the string isn't valid UTF-8.
local function displayLength(str)
  return utf8.len(str) or #str
end

-- Running-max helper: widens `current` to fit `value`, used to size a report column
-- while classifying extensions, without a second pass over the list.
local function trackLength(current, value)
  if value == nil then
    return current
  end
  local len = displayLength(tostring(value))
  if len > current then
    return len
  end
  return current
end

local function boolText(value)
  return tostring(value or false)
end

-- Right-pads by display (character) length, since string.format's "%-Ns" pads by byte
-- length and would under-pad any value containing multi-byte UTF-8 characters.
local function padRight(value, width)
  local str = tostring(value or "")
  local pad = width - displayLength(str)
  if pad > 0 then
    return str .. string.rep(" ", pad)
  end
  return str
end

-- Left-pads by display (character) length - the right-aligned counterpart to padRight().
local function padLeft(value, width)
  local str = tostring(value or "")
  local pad = width - displayLength(str)
  if pad > 0 then
    return string.rep(" ", pad) .. str
  end
  return str
end

local function field(label, value, width)
  return "  " .. label .. ": " .. padRight(value, width)
end

local function fieldRight(label, value, width)
  return "  " .. label .. ": " .. padLeft(value, width)
end

local function fixedField(label, value, width)
  return "  " .. label .. ": " .. string.format("%-" .. width .. "s", tostring(value or ""))
end

local function extensionSource(ext)
  return ext.egosoftextension and "ego" or (ext.isworkshop and "workshop" or (ext.personal and "personal" or "local"))
end

-- Calls an engine binding defensively: a missing global, an FFI symbol the running build
-- doesn't export, or an error inside the call degrades a single report line to "n/a"
-- instead of aborting the whole report.
local function safeCall(func, ...)
  if type(func) ~= "function" then
    return nil
  end
  local ok, result = pcall(func, ...)
  if ok then
    return result
  end
  return nil
end

-- ffi.C raises on an undeclared/unresolvable symbol, so even the lookup has to be guarded.
-- Takes at most one argument - none of the bindings used here need more.
local function safeEngineCall(name, value)
  local ok, result = pcall(function()
    if value == nil then
      return C[name]()
    end
    return C[name](value)
  end)
  if ok then
    return result
  end
  return nil
end

local function numberText(value, digits)
  local number = tonumber(value)
  if number == nil then
    return "n/a"
  end
  return string.format("%." .. (digits or 2) .. "f", number)
end

local function sizeText(width, height)
  if width == nil or height == nil then
    return "n/a"
  end
  return tostring(width) .. " x " .. tostring(height)
end

-- One "label: value" row of the header section, printed later with a shared label width.
local function addSetting(rows, label, value)
  rows[#rows + 1] = { label = label, value = (value == nil) and "n/a" or tostring(value) }
end

-- Game version plus the resolution and UI settings that change how every menu is laid out -
-- the values needed to make sense of a UI bug report (misplaced/clipped widgets, unreadable
-- text) without asking the reporter to dig through the options menus.
local function gameDataRows()
  local rows = {}
  addSetting(rows, "Version", GetVersionString())

  local resolution = safeCall(GetResolutionOption)
  addSetting(rows, "Resolution", resolution and sizeText(resolution.width, resolution.height))

  addSetting(rows, "UI scale (option)", numberText(safeEngineCall("GetUIScaleFactor")))
  addSetting(rows, "Menu width (option)", numberText(safeEngineCall("GetMenuWidthScale")))
  addSetting(rows, "GetUIScale(false)", numberText(safeEngineCall("GetUIScale", false)))
  addSetting(rows, "GetUIScale(true)", numberText(safeEngineCall("GetUIScale", true)))

  -- Helper is loaded before this file (ui.xml depends on ego_detailmonitor), but a stripped
  -- or reordered setup shouldn't turn the report into an error message.
  local helper = Helper
  addSetting(rows, "Helper view size", helper and sizeText(helper.viewWidth, helper.viewHeight))
  addSetting(rows, "Helper uiScale", numberText(helper and helper.uiScale))

  local scaledX = helper and safeCall(helper.scaleX, 100)
  local scaledY = helper and safeCall(helper.scaleY, 100)
  local scaleText = (scaledX and scaledY) and (tostring(scaledX) .. " / " .. tostring(scaledY)) or nil
  addSetting(rows, "Helper scaleX / scaleY (of 100)", scaleText)

  return rows
end

local function printExtensionList()
  local lines = {}
  lines[#lines + 1] = "=== Game Data ==="
  local settingRows = gameDataRows()
  local settingLabelWidth = 0
  for _, row in ipairs(settingRows) do
    settingLabelWidth = trackLength(settingLabelWidth, row.label)
  end
  for _, row in ipairs(settingRows) do
    lines[#lines + 1] = padRight(row.label .. ":", settingLabelWidth + 1) .. " " .. row.value
  end

  local extensions = GetExtensionList()
  local dlcList = {}
  local dlcIdWidth = 0
  local dlcNameWidth = 0
  local dlcVersionWidth = 0
  local dlcLocationWidth = 0
  local modList = {}
  local modIdWidth = 0
  local modNameWidth = 0
  local modAuthorWidth = 0
  local modSourceWidth = 0
  local modVersionWidth = 0
  local modLocationWidth = 0
  for _, ext in ipairs(extensions) do
    if ext.enabled then
      if ext.egosoftextension and ext.enabledbydefault then
        dlcList[#dlcList + 1] = ext
        dlcIdWidth = trackLength(dlcIdWidth, ext.id)
        dlcNameWidth = trackLength(dlcNameWidth, ext.name)
        dlcVersionWidth = trackLength(dlcVersionWidth, formatVersion(ext.version))
        dlcLocationWidth = trackLength(dlcLocationWidth, ext.location)
      else
        modList[#modList + 1] = ext
        modIdWidth = trackLength(modIdWidth, ext.id)
        modNameWidth = trackLength(modNameWidth, ext.name)
        modAuthorWidth = trackLength(modAuthorWidth, ext.author)
        modSourceWidth = trackLength(modSourceWidth, extensionSource(ext))
        modVersionWidth = trackLength(modVersionWidth, formatVersion(ext.version))
        modLocationWidth = trackLength(modLocationWidth, ext.location)
      end
    end
  end

  lines[#lines + 1] = "=== Enabled DLCs (" .. #dlcList .. ") ==="
  for _, dlc in ipairs(dlcList) do
    lines[#lines + 1] =
        field("id", dlc.id, dlcIdWidth) ..
        field("name", dlc.name, dlcNameWidth) ..
        fieldRight("version", formatVersion(dlc.version), dlcVersionWidth) ..
        fixedField("date", dlc.date, 10) ..
        field("location", dlc.location, dlcLocationWidth) ..
        fixedField("personal", boolText(dlc.personal), 5) ..
        fixedField("isworkshop", boolText(dlc.isworkshop), 5) ..
        fixedField("sync", boolText(dlc.sync), 5) ..
        fixedField("syncbydefault", boolText(dlc.syncbydefault), 5)
  end

  lines[#lines + 1] = "=== Enabled Extensions (" .. #modList .. ") ==="
  for _, mod in ipairs(modList) do
    local source = extensionSource(mod)
    lines[#lines + 1] =
        field("id", mod.id, modIdWidth) ..
        field("name", mod.name, modNameWidth) ..
        field("author", mod.author, modAuthorWidth) ..
        field("source", source, modSourceWidth) ..
        fieldRight("version", formatVersion(mod.version), modVersionWidth) ..
        fixedField("date", mod.date, 10) ..
        field("location", mod.location, modLocationWidth) ..
        fixedField("personal", boolText(mod.personal), 5) ..
        fixedField("isworkshop", boolText(mod.isworkshop), 5) ..
        fixedField("sync", boolText(mod.sync), 5) ..
        fixedField("syncbydefault", boolText(mod.syncbydefault), 5)
  end

  for _, line in ipairs(lines) do
    logInfo("PrintExtensionList: " .. line)
  end
end

-- Last path segment of a location: "ws_2042901274\" -> "ws_2042901274".
local function folderName(location)
  local trimmed = tostring(location or ""):gsub("[\\/]+$", "")
  return trimmed:match("[^\\/]*$") or trimmed
end

-- Folder named like a Workshop item that the game does not manage as one: a hand-copied or
-- unsubscribed leftover. A genuine subscription has isworkshop set and is not flagged.
local function isStrayWorkshopFolder(ext)
  return (not ext.isworkshop) and (folderName(ext.location):lower():match("^ws_%d+$") ~= nil)
end

-- "<label>: <value>" from page 1001 only, so the warnings stay localised without own t/ files.
local function vanillaLabel(labelId, value)
  return ReadText(1001, labelId) .. ReadText(1001, 120) .. " " .. tostring(value)
end

-- Warning / Steam Workshop Downloads / Subscribed / Updates / No / Location.
local function strayWorkshopWarning(ext)
  return vanillaLabel(12676, ReadText(1001, 4830))
      .. "\n" .. vanillaLabel(4832, ReadText(1001, 2618))
      .. "\n" .. vanillaLabel(4824, ReadText(1001, 2618))
      .. "\n" .. vanillaLabel(2943, ext.location)
end

-- Warning / ID / Location, with one bullet per folder holding this id.
local function duplicateIdWarning(ext, locations)
  local warning = ReadText(1001, 12676)
      .. "\n" .. vanillaLabel(4823, ext.id)
      .. "\n" .. ReadText(1001, 2943) .. ReadText(1001, 120)
  for _, location in ipairs(locations) do
    warning = warning .. "\n- " .. location
  end
  return warning
end

-- Distinct enabled locations per id; more than one means the same mod is installed twice.
local function locationsById(extensions)
  local byId = {}
  for _, ext in ipairs(extensions) do
    if ext.enabled then
      local key = tostring(ext.id):lower()
      local entry = byId[key]
      if entry == nil then
        entry = { seen = {}, locations = {} }
        byId[key] = entry
      end
      local location = tostring(ext.location or "")
      if not entry.seen[location:lower()] then
        entry.seen[location:lower()] = true
        entry.locations[#entry.locations + 1] = location
      end
    end
  end
  return byId
end

-- Sets warning/warningtext in place, leaving an entry the engine already flagged alone.
local function annotateInstallWarnings(extensions)
  local byId = locationsById(extensions)
  for _, ext in ipairs(extensions) do
    if ext.enabled and (not ext.warning) then
      local locations = byId[tostring(ext.id):lower()].locations
      if #locations > 1 then
        ext.warning = true
        ext.warningtext = duplicateIdWarning(ext, locations)
      elseif isStrayWorkshopFolder(ext) then
        ext.warning = true
        ext.warningtext = strayWorkshopWarning(ext)
      end
    end
  end
end

-- The options menu reads warning/warningtext off each GetExtensionList() result, so annotating
-- it is the whole feature. Sentinel: a re-created menus environment must not stack wrappers.
if (type(GetExtensionList) == "function") and (not __PRINT_EXTENSION_LIST_INSTALL_WARNINGS) then
  __PRINT_EXTENSION_LIST_INSTALL_WARNINGS = true
  local baseGetExtensionList = GetExtensionList
  GetExtensionList = function(...)
    local extensions = baseGetExtensionList(...)
    pcall(annotateInstallWarnings, extensions)
    return extensions
  end
end

printExtensionList()
