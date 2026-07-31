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
    DebugError("PrintExtensionList: " .. line)
  end
end

printExtensionList()
