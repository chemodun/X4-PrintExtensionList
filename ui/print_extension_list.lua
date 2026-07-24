-- Print Extension List (print_extension_list)
-- Logs the game version, build, and the list of enabled DLCs/extensions with their versions
-- to the debug log once, when the UI environment loads.
-- Compatible with X4 8.00+.

local ffi = require("ffi")
local C   = ffi.C
local utf8 = require("utf8")

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

local function printExtensionList()
  local lines = {}
  lines[#lines + 1] = "=== Game Data ==="
  lines[#lines + 1] = "Version: " .. GetVersionString()

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
