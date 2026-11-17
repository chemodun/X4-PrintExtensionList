-- engine_access: reads the running X4 executable (Windows PE, native Linux ELF) for mods that locate engine code.
-- Copied verbatim into each mod (master: the X4-EngineAccess repository) and listed in its ui.xml before the files
-- using it. A mod takes its copy from __ENGINE_ACCESS[<version>].

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C = ffi.C

local VERSION = "1.01"
-- whole number for the record: uidata returns a numeric string as a number
local VERSION_NUMBER = math.floor(tonumber(VERSION) * 100 + 0.5)
local P = ffi.typeof("uint8_t*")
-- the x86-64 default link address; ffi.C refuses libc, so the ELF image is read there, never searched for
local ELF_BASE = 0x400000

local M = { VERSION = VERSION }

function M.u16(p) return ffi.cast("uint16_t*", p)[0] end
function M.u32(p) return ffi.cast("uint32_t*", p)[0] end
function M.u64(p) return tonumber(ffi.cast("uint64_t*", p)[0]) end
function M.i32(p) return ffi.cast("int32_t*", p)[0] end
function M.hex(n) return string.format("0x%x", tonumber(n)) end
local u16, u32, u64, i32 = M.u16, M.u32, M.u64, M.i32

local function hexBytes(p, n, separator)
  local out = {}
  for k = 0, n - 1 do out[#out + 1] = string.format("%02x", p[k]) end
  return table.concat(out, separator or " ")
end

local TWO32 = ffi.new("uint64_t", 4294967296)

-- a pointer as text, exact over the whole 64 bits
local function address(p)
  local v = ffi.cast("uint64_t", ffi.cast("uintptr_t", p))
  return string.format("0x%08x%08x", tonumber(v / TWO32), tonumber(v % TWO32))
end

-- bytes: integers, false = any byte
function M.match(p, bytes)
  for k = 1, #bytes do
    if bytes[k] and p[k - 1] ~= bytes[k] then return false end
  end
  return true
end

function M.inRange(r, rva, len)
  return rva >= r.from and rva + (len or 8) <= r.to
end

function M.rangeOf(list, rva, len)
  for _, r in ipairs(list) do
    if M.inRange(r, rva, len) then return r end
  end
end

-- target of a rip-relative reference in the code at rva; ref = { rel32 offset, end of its instruction }
function M.rel(img, rva, ref)
  return rva + ref[2] + i32(img.base + rva + ref[1])
end

-- printable ASCII string in constant data, or nil
function M.cString(img, rva, max)
  local r, b = M.rangeOf(img.rdata, rva, 1), img.base
  if not r then return nil end
  local n = 0
  while n < max do
    if rva + n >= r.to then return nil end
    local c = b[rva + n]
    if c == 0 then break end
    if c < 0x20 or c > 0x7e then return nil end
    n = n + 1
  end
  if n == 0 or n == max then return nil end
  return ffi.string(b + rva, n)
end

-- the first of the named exports the Lua state has declared; never cdef'd here
function M.findAnchor(names)
  for _, name in ipairs(names) do
    local ok, f = pcall(function() return C[name] end)
    if ok and f ~= nil then return ffi.cast("uintptr_t", f) end
  end
  return nil
end

-- the PE header of an image at p, or nil
local function peHeader(p)
  if p[0] ~= 0x4d or p[1] ~= 0x5a then return nil end
  local e = i32(p + 0x3c)
  -- kept inside the page just read: a chance "MZ" in code must not send the next read anywhere
  if e < 0x40 or e > 0xff8 or u32(p + e) ~= 0x4550 then return nil end
  return p + e
end

local function mapPe(anchor)
  local a = anchor - anchor % 0x10000
  local base, pe
  for _ = 1, 4096 do
    local p = ffi.cast(P, a)
    pe = peHeader(p)
    if pe then
      base = p
      break
    end
    a = a - 0x10000
  end
  if not base then return nil, "image base not found" end
  local opt = pe + 24
  -- x86-64, PE32+
  if u16(pe + 4) ~= 0x8664 or u16(opt) ~= 0x20b then
    return nil, string.format("unsupported image (machine 0x%x, magic 0x%x)", u16(pe + 4), u16(opt))
  end
  local size = u32(opt + 56)
  local sec = {}
  for i = 0, u16(pe + 6) - 1 do
    local h = opt + u16(pe + 20) + i * 40
    local n = {}
    for k = 0, 7 do
      if h[k] ~= 0 then n[#n + 1] = string.char(h[k]) end
    end
    local from, vsize, raw = u32(h + 12), u32(h + 8), u32(h + 16)
    sec[table.concat(n)] = { from = from, to = from + math.min(vsize, raw), vto = from + vsize }
  end
  if not (sec[".text"] and sec[".rdata"] and sec[".data"]) then return nil, "image sections missing" end
  -- exception directory: every function's start and end, sorted
  if u32(opt + 108) < 4 then return nil, "no exception directory" end
  local pdata, count = u32(opt + 112 + 3 * 8), math.floor(u32(opt + 112 + 3 * 8 + 4) / 12)
  if count == 0 or pdata + count * 12 > size then return nil, "no exception directory" end
  local img = {
    base = base,
    format = "pe",
    -- timestamp, checksum, image size
    id = string.format("%x-%x-%x", u32(pe + 8), u32(opt + 64), size),
    text = sec[".text"],
    rdata = { sec[".rdata"] },
    data = { { from = sec[".data"].from, to = sec[".data"].vto } },
    anchor = tonumber(anchor - ffi.cast("uintptr_t", base)),
  }
  if not M.inRange(img.text, img.anchor, 1) then return nil, "anchor outside the code" end
  img.isStart = function(rva)
    local lo, hi = 0, count - 1
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local entry = base + pdata + mid * 12
      local from, to = u32(entry), u32(entry + 4)
      if rva < from then
        hi = mid - 1
      elseif rva >= to then
        lo = mid + 1
      else
        return rva == from
      end
    end
    return false
  end
  return img
end

local function buildId(p, size)
  local n = 0
  while n + 16 <= size do
    local nsz, dsz, kind = u32(p + n), u32(p + n + 4), u32(p + n + 8)
    local desc = n + 12 + math.ceil(nsz / 4) * 4
    if desc + dsz > size then return nil end
    if kind == 3 and nsz == 4 and dsz > 0 and ffi.string(p + n + 12, 3) == "GNU" then
      return hexBytes(p + desc, dsz, "")
    end
    n = desc + math.ceil(dsz / 4) * 4
  end
end

local function mapElf(anchor)
  local a = tonumber(anchor)
  if a < ELF_BASE or a >= 0x100000000 then return nil, "position-independent build" end
  local base = ffi.cast(P, ELF_BASE)
  -- ELF64, little endian, executable, x86-64
  if u32(base) ~= 0x464c457f or base[4] ~= 2 or base[5] ~= 1 or u16(base + 16) ~= 2 or u16(base + 18) ~= 0x3e then
    return nil, "ELF header not found (" .. hexBytes(base, 20) .. ")"
  end
  local phoff, phsize, phnum = u64(base + 32), u16(base + 54), u16(base + 56)
  -- the table has to sit in the header's own page
  if phsize ~= 56 or phoff + phnum * 56 > 0x1000 then
    return nil, "program headers not found (offset " .. phoff .. ", size " .. phsize .. ", count " .. phnum .. ")"
  end
  local loads, notes, eh, headerVa = {}, {}, nil, nil
  for i = 0, phnum - 1 do
    local h = base + phoff + i * 56
    local kind = u32(h)
    local s = { flags = u32(h + 4), offset = u64(h + 8), va = u64(h + 16), fsize = u64(h + 32), msize = u64(h + 40) }
    if kind == 1 then
      loads[#loads + 1] = s
      if s.offset == 0 then headerVa = s.va end
    elseif kind == 4 then
      notes[#notes + 1] = s
    elseif kind == 0x6474e550 then
      eh = s
    end
  end
  if headerVa ~= ELF_BASE then return nil, "ELF header not loaded" end
  -- inside the file-backed part of a loaded segment
  local function loaded(s)
    for _, l in ipairs(loads) do
      if s.va >= l.va and s.va + s.fsize <= l.va + l.fsize then return true end
    end
    return false
  end
  local id
  for _, n in ipairs(notes) do
    if not id and loaded(n) then id = buildId(base + (n.va - ELF_BASE), n.fsize) end
  end
  if not id then return nil, "no build id" end
  if not eh or eh.fsize < 12 or not loaded(eh) then return nil, "no unwind table" end
  local hdr = base + (eh.va - ELF_BASE)
  -- version 1, pcrel eh_frame pointer, udata4 count, datarel sdata4 table
  if hdr[0] ~= 1 or hdr[1] ~= 0x1b or hdr[2] ~= 0x03 or hdr[3] ~= 0x3b then
    return nil, "unsupported unwind table (" .. hexBytes(hdr, 4) .. ")"
  end
  local img = { base = base, format = "elf", id = "elf-" .. id, rdata = {}, data = {}, anchor = a - ELF_BASE }
  for _, s in ipairs(loads) do
    local from = s.va - ELF_BASE
    if s.flags % 2 == 1 then
      if img.anchor >= from and img.anchor < from + s.fsize then img.text = { from = from, to = from + s.fsize } end
    else
      img.rdata[#img.rdata + 1] = { from = from, to = from + s.fsize }
      if math.floor(s.flags / 2) % 2 == 1 then img.data[#img.data + 1] = { from = from, to = from + s.msize } end
    end
  end
  if not img.text then return nil, "anchor outside the executable" end
  local hdrRva, count, starts = eh.va - ELF_BASE, u32(hdr + 8), ffi.cast("int32_t*", hdr + 12)
  if count == 0 or 12 + count * 8 > eh.fsize then return nil, "no unwind table" end
  img.isStart = function(rva)
    local lo, hi = 0, count - 1
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local from = hdrRva + starts[mid * 2]
      if rva < from then
        hi = mid - 1
      elseif rva > from then
        lo = mid + 1
      else
        return true
      end
    end
    return false
  end
  return img
end

-- The executable around anchor: base, format "pe" / "elf", id (what a cached result is tied to), RVA ranges text,
-- rdata (constant data), data (writable, uninitialised part included), anchor RVA, isStart(rva). Or nil, reason.
function M.mapImage(anchor)
  local why = M.unsupported()
  if why then return nil, why end
  if ffi.os == "Windows" then return mapPe(anchor) end
  return mapElf(anchor)
end

-- why this platform is not read at all, or nil
function M.unsupported()
  if ffi.arch ~= "x64" then return "unsupported architecture " .. tostring(ffi.arch) end
  if ffi.os ~= "Windows" and ffi.os ~= "Linux" then return "unsupported OS " .. tostring(ffi.os) end
  return nil
end

local ABI = { "32bit", "64bit", "le", "be", "fpu", "softfp", "hardfp", "eabi", "win", "gc64" }

-- OS / architecture and the LuaJIT ABI flags, e.g. "Linux/x64, abi 64bit le fpu hardfp gc64"
function M.platform()
  local abi = {}
  for _, name in ipairs(ABI) do
    local ok, yes = pcall(ffi.abi, name)
    if ok and yes then abi[#abi + 1] = name end
  end
  return tostring(ffi.os) .. "/" .. tostring(ffi.arch) .. ", abi " .. table.concat(abi, " ")
end

-- One line for the log, what a port to another platform or build starts from: library version, platform, game
-- version, image id when mapped, the address of every declared anchor. Reads no memory.
function M.describe(anchors, img)
  local okVersion, version = pcall(GetVersionString)
  local out = {
    "engine_access " .. VERSION,
    M.platform(),
    "game " .. (okVersion and tostring(version) or "?"),
  }
  if img then out[#out + 1] = "image " .. tostring(img.id) end
  for _, name in ipairs(anchors or {}) do
    local ok, f = pcall(function() return C[name] end)
    if ok and f ~= nil then out[#out + 1] = name .. " " .. address(f) end
  end
  return table.concat(out, ", ")
end

-- Maps the image from opts.anchors and runs opts.verify / opts.search under a per-build record. The record is marked
-- pending before the first memory read, so a crash while mapping or searching is not repeated. opts: anchors,
-- version (record version), what (for the crash reason), read() -> record, write(record),
-- verify(img, record) -> bool, search(img) -> record with found / reason.
-- Returns img, record; nil when no anchor is declared yet; false, reason when unavailable (the reason ends with
-- the M.describe line, so the mod's own log line carries it).
function M.locate(opts)
  local anchor = M.findAnchor(opts.anchors)
  if not anchor then return nil end
  local img
  local function fail(reason)
    return false, tostring(reason) .. " [" .. M.describe(opts.anchors, img) .. "]"
  end
  local why = M.unsupported()
  if why then return fail(why) end
  local function save(record)
    opts.write(record)
    -- declared by vanilla addons; one not loaded yet only delays the write to the next uidata save
    pcall(function() C.SaveUIUserData() end)
  end
  local c = opts.read()
  if type(c) ~= "table" then c = {} end
  local key = GetVersionString() .. " " .. ffi.os .. "/" .. ffi.arch
  -- a newer library retries once what an older one stopped on
  if c.pending == key and (tonumber(c.pendingBy) or math.huge) >= VERSION_NUMBER then
    return fail("the game stopped while " .. opts.what .. " was located")
  end
  c.pending, c.pendingBy = key, VERSION_NUMBER
  save(c)
  local ok
  ok, img, why = pcall(M.mapImage, anchor)
  if not ok then img, why = nil, "error: " .. tostring(img) end
  if not img then
    c.pending, c.pendingBy = nil, nil
    save(c)
    return fail(why)
  end
  local build = GetVersionString() .. " " .. img.id
  local cached = c.build == build and c.v == opts.version
  local result, how = c, "cached: "
  if not (cached and not c.found) then
    how = "searched: "
    local okSearch, r = pcall(function()
      if cached then
        local okVerify, valid = pcall(opts.verify, img, c)
        if okVerify and valid then return c end
      end
      return opts.search(img)
    end)
    if okSearch and type(r) == "table" then
      result = r
    else
      result = { found = false, reason = "error: " .. tostring(r) }
    end
  end
  result.pending, result.pendingBy = nil, nil
  result.build, result.v = build, opts.version
  save(result)
  if not result.found then return fail(how .. tostring(result.reason)) end
  return img, result
end

---@diagnostic disable-next-line: global-in-non-module
__ENGINE_ACCESS = __ENGINE_ACCESS or {}
__ENGINE_ACCESS[VERSION] = M
