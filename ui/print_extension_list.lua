-- Print Extension List (print_extension_list)
-- Logs the game version, the current resolution/UI settings, and the list of enabled
-- DLCs/extensions with their versions to the debug log once, when the UI environment loads.
-- Compatible with X4 8.00+, Windows and native Linux.

---@diagnostic disable-next-line: unresolved-require
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

local ENGINE_ACCESS = "1.01"
-- ui/engine_access.lua, listed before this file in ui.xml
local EA = __ENGINE_ACCESS and __ENGINE_ACCESS[ENGINE_ACCESS]

-- Engine logger locator, kept identical to lua_log_api so both share the __LUA_LOG_API_ENGINE record.
local RECORD_VERSION = 2
local CATEGORY, CATEGORY_VERBOSE = "UI", "UI_Verbose"
-- namesAt only accepts a table whose entry 0 is "General"
local CATEGORY_GENERAL = 0
local LEVEL_INFO = 0

-- exports that call the engine error wrapper early in their body; the first three are declared by ui/widget,
-- which loads before any addon. Never cdef'd here: a second declaration breaks whichever file declares later.
local ANCHORS = { "CopyToClipboard", "GetTextWidth", "GetConfigSetting", "ConvertStringTo64Bit" }

-- Per executable format: the engine error wrapper core(*logger, fmt, va, category 0, level 2, nested 0) and the code
-- holding the category names; false = masked byte. A reference is { rel32 offset, end of its instruction }.
local FORMATS = {
  pe = {
    -- identical in 8.00 and 9.00
    ---@type (integer|false)[]
    wrapper = { 0x48, 0x89, 0x4c, 0x24, 0x08, 0x48, 0x89, 0x54, 0x24, 0x10, 0x4c, 0x89, 0x44, 0x24, 0x18,
      0x4c, 0x89, 0x4c, 0x24, 0x20, 0x48, 0x83, 0xec, 0x38, 0x48, 0x8b, 0x05, false, false, false, false,
      0x48, 0x85, 0xc0, 0x74, false, 0x48, 0x8b, 0xd1, 0xc6, 0x44, 0x24, 0x28, 0x00, 0x48, 0x8b, 0xc8,
      0xc7, 0x44, 0x24, 0x20, 0x02, 0x00, 0x00, 0x00, 0x4c, 0x8d, 0x44, 0x24, 0x48, 0x45, 0x33, 0xc9,
      0xe8, false, false, false, false },
    loggerRefs = { { 27, 31 } },
    coreRef = { 64, 68 },
    -- file-log formatter: cmp r8d,N; ja; movsxd rax,r8d; lea rbx,[category names]
    ---@type (integer|false)[]
    names = { 0x41, 0x83, 0xf8, false, 0x77, false, 0x49, 0x63, 0xc0, 0x48, 0x8d, 0x1d, false, false, false, false },
    namesRef = { 12, 16 },
    namesCount = function(p) return p[3] + 1 end,
    ---@return integer, integer
    namesRange = function(wrapper) return wrapper, wrapper + 0x1000 end,
  },
  elf = {
    -- SysV: register save area, then va_list { gp_offset 8, fp_offset 0x30, overflow area, save area }
    ---@type (integer|false)[]
    wrapper = { 0x48, 0x81, 0xec, 0xd8, 0x00, 0x00, 0x00, 0x48, 0x89, 0x74, 0x24, 0x28, 0x48, 0x89, 0x54, 0x24, 0x30,
      0x48, 0x89, 0x4c, 0x24, 0x38, 0x4c, 0x89, 0x44, 0x24, 0x40, 0x4c, 0x89, 0x4c, 0x24, 0x48, 0x84, 0xc0, 0x74, false,
      0x0f, 0x29, 0x44, 0x24, 0x50, 0x0f, 0x29, 0x4c, 0x24, 0x60, 0x0f, 0x29, 0x54, 0x24, 0x70,
      0x0f, 0x29, 0x9c, 0x24, 0x80, 0x00, 0x00, 0x00, 0x0f, 0x29, 0xa4, 0x24, 0x90, 0x00, 0x00, 0x00,
      0x0f, 0x29, 0xac, 0x24, 0xa0, 0x00, 0x00, 0x00, 0x0f, 0x29, 0xb4, 0x24, 0xb0, 0x00, 0x00, 0x00,
      0x0f, 0x29, 0xbc, 0x24, 0xc0, 0x00, 0x00, 0x00,
      0x48, 0x83, 0x3d, false, false, false, false, 0x00, 0x74, false,
      0x48, 0x8d, 0x84, 0x24, 0xe0, 0x00, 0x00, 0x00, 0x48, 0x89, 0xfe, 0x48, 0x89, 0xe2, 0x31, 0xc9,
      0x48, 0x8b, 0x3d, false, false, false, false, 0x48, 0x89, 0x44, 0x24, 0x08, 0x45, 0x31, 0xc9,
      0x48, 0x8d, 0x44, 0x24, 0x20, 0x41, 0xb8, 0x02, 0x00, 0x00, 0x00, 0xc7, 0x04, 0x24, 0x08, 0x00, 0x00, 0x00,
      0xc7, 0x44, 0x24, 0x04, 0x30, 0x00, 0x00, 0x00, 0x48, 0x89, 0x44, 0x24, 0x10,
      0xe8, false, false, false, false },
    loggerRefs = { { 0x5e, 0x63 }, { 0x78, 0x7c } },
    coreRef = { 0xa4, 0xa8 },
    -- category lookup by name: push r15; lea r15,[category names]; push r14; push r13; push r12; xor r12d,r12d
    ---@type (integer|false)[]
    names = { 0x41, 0x57, 0x4c, 0x8d, 0x3d, false, false, false, false, 0x41, 0x56, 0x41, 0x55, 0x41, 0x54, 0x45, 0x31, 0xe4 },
    namesRef = { 5, 9 },
    -- its loop bound: cmp r12,N
    namesCount = function(p)
      for k = 18, 0x60 do
        if p[k] == 0x49 and p[k + 1] == 0x83 and p[k + 2] == 0xfc then return p[k + 3] end
      end
    end,
    ---@return integer, integer
    namesRange = function(_, core) return core - 0x1000, core end,
  },
}

-- nil: not located yet, false: unavailable, table: located
---@type table|false|nil
local engine
local va = ffi.new("const char*[1]")
-- SysV va_list with every variadic argument in the overflow area
local sysv = ffi.new("struct { uint32_t gp, fp; const char** overflow; void* save; }[1]")

-- logger global and core function RVAs when rva is the error wrapper, or nil
local function wrapperAt(img, rva)
  local f = FORMATS[img.format]
  if not EA.inRange(img.text, rva, #f.wrapper) or not img.isStart(rva) then return nil end
  if not EA.match(img.base + rva, f.wrapper) then return nil end
  local logger
  for _, ref in ipairs(f.loggerRefs) do
    local l = EA.rel(img, rva, ref)
    if logger and l ~= logger then return nil end
    logger = l
  end
  if not EA.rangeOf(img.data, logger, 8) then return nil end
  local core = EA.rel(img, rva, f.coreRef)
  if not EA.inRange(img.text, core, 1) or not img.isStart(core) then return nil end
  return logger, core
end

-- the category names table at o: its RVA and the indexes of CATEGORY and CATEGORY_VERBOSE (nil if absent), or nil
local function namesAt(img, o)
  local f = FORMATS[img.format]
  if not EA.inRange(img.text, o, 0x80) or not EA.match(img.base + o, f.names) then return nil end
  local count = f.namesCount(img.base + o)
  if not count or count == 0 then return nil end
  local tableRva = EA.rel(img, o, f.namesRef)
  if not EA.rangeOf(img.rdata, tableRva, count * 8) then return nil end
  local entries = ffi.cast("uint64_t*", img.base + tableRva)
  local imageBase = ffi.cast("uintptr_t", img.base)
  local index, verbose
  for i = 0, count - 1 do
    local name = EA.cString(img, tonumber(entries[i] - imageBase), 64)
    if not name or (i == 0 and name ~= "General") then return nil end
    if name == CATEGORY then index = i end
    if name == CATEGORY_VERBOSE then verbose = i end
  end
  if index then return tableRva, index, verbose end
end

local function search(img)
  local f, b = FORMATS[img.format], img.base
  local wrapper, logger, core
  for o = img.anchor, img.anchor + 0x200 do
    if EA.inRange(img.text, o, 5) and b[o] == 0xe8 then
      local t = o + 5 + EA.i32(b + o + 1)
      logger, core = wrapperAt(img, t)
      if logger then
        wrapper = t
        break
      end
    end
  end
  if not wrapper then return { found = false, reason = "engine error wrapper not found from " .. EA.hex(img.anchor) } end
  local lo, hi = f.namesRange(wrapper, core)
  local from, to = math.max(lo, img.text.from), math.min(hi, img.text.to - 0x80)
  local n1, n2 = f.names[1], f.names[2]
  for o = from, to do
    if b[o] == n1 and b[o + 1] == n2 then
      local tableRva, index, verbose = namesAt(img, o)
      if tableRva then
        return { found = true, wrapper = wrapper, logger = logger, core = core, names = o, category = index, verbose = verbose }
      end
    end
  end
  return { found = false, reason = "log category " .. CATEGORY .. " not found" }
end

local function verifyCached(img, c)
  local logger, core = wrapperAt(img, c.wrapper)
  if logger ~= c.logger or core ~= c.core then return false end
  local _, index, verbose = namesAt(img, c.names)
  return index == c.category and verbose == c.verbose
end

-- Returns a located engine, nil to retry on the next write (no anchor declared yet), or false and the reason.
---@return table|false|nil, string?
local function detect()
  if not EA then return false, "engine_access " .. ENGINE_ACCESS .. " not loaded" end
  local img, c = EA.locate({
    anchors = ANCHORS,
    version = RECORD_VERSION,
    what = "the engine logger",
    ---@diagnostic disable-next-line: undefined-global
    read = function() return __LUA_LOG_API_ENGINE end,
    ---@diagnostic disable-next-line: global-in-non-module
    write = function(record) __LUA_LOG_API_ENGINE = record end,
    verify = verifyCached,
    search = search,
  })
  if img == nil then return nil end
  if not img then return false, c end
  return {
    logger = ffi.cast("void**", img.base + c.logger),
    core = ffi.cast("void(*)(void*, const char*, void*, int32_t, int32_t, uint8_t)", img.base + c.core),
    sysv = img.format == "elf",
    image = img.id,
  }
end

local function locate()
  local ok, result, reason = pcall(detect)
  if not ok then
    reason = "error: " .. tostring(result)
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
      local args = va
      if engine.sysv then
        sysv[0].gp, sysv[0].fp, sysv[0].overflow = 48, 176, va
        args = sysv
      end
      engine.core(logger, "%s", args, CATEGORY_GENERAL, LEVEL_INFO, 0)
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
  addSetting(rows, "Platform", EA and EA.platform() or (tostring(ffi.os) .. "/" .. tostring(ffi.arch)))
  -- the exact executable: tells the Steam, GOG and Linux builds of one version apart
  if engine == nil then locate() end
  addSetting(rows, "Executable", engine and engine.image or nil)

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
