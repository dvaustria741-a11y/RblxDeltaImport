local CONFIG = {
    ImportServices = {Workspace = true},
    SkipClasses = {Terrain = true, Camera = true},
    MaxInstances = 1000000,
    MaxChunkBytes = 268435456,
    YieldEvery = 300,
    FileExtensions = {".rbxl", ".rbxm"},
    FolderName = "StudioLiteImport",
    PlaceInOriginalLocations = true,
    ImportScripts = true,
    ExportScripts = true,
    PlaceableServices = {
        Workspace = true,
        Lighting = true,
        ReplicatedStorage = true,
        ReplicatedFirst = true,
        StarterGui = true,
        StarterPack = true,
        StarterPlayer = true,
        SoundService = true,
        ServerScriptService = true,
        ServerStorage = true,
    },
    FolderModeServices = {Workspace = true},
    MeshSettleSeconds = 8,
    VerifySeconds = 1,
    ApplyServiceProperties = {Lighting = true},
}

local PROPERTY_ALIASES = {
    size = "Size",
    Color3uint8 = "Color",
    shape = "Shape",
}

local ROTATIONS = {
    [0x02] = {1, 0, 0, 0, 1, 0, 0, 0, 1},
    [0x03] = {1, 0, 0, 0, 0, -1, 0, 1, 0},
    [0x05] = {1, 0, 0, 0, -1, 0, 0, 0, -1},
    [0x06] = {1, 0, 0, 0, 0, 1, 0, -1, 0},
    [0x07] = {0, 1, 0, 1, 0, 0, 0, 0, -1},
    [0x09] = {0, 0, 1, 1, 0, 0, 0, 1, 0},
    [0x0a] = {0, -1, 0, 1, 0, 0, 0, 0, 1},
    [0x0c] = {0, 0, -1, 1, 0, 0, 0, -1, 0},
    [0x0d] = {0, 1, 0, 0, 0, 1, 1, 0, 0},
    [0x0e] = {0, 0, -1, 0, 1, 0, 1, 0, 0},
    [0x10] = {0, -1, 0, 0, 0, -1, 1, 0, 0},
    [0x11] = {0, 0, 1, 0, -1, 0, 1, 0, 0},
    [0x14] = {-1, 0, 0, 0, 1, 0, 0, 0, -1},
    [0x15] = {-1, 0, 0, 0, 0, 1, 0, 1, 0},
    [0x17] = {-1, 0, 0, 0, -1, 0, 0, 0, 1},
    [0x18] = {-1, 0, 0, 0, 0, -1, 0, -1, 0},
    [0x19] = {0, 1, 0, -1, 0, 0, 0, 0, 1},
    [0x1b] = {0, 0, -1, -1, 0, 0, 0, 1, 0},
    [0x1c] = {0, -1, 0, -1, 0, 0, 0, 0, -1},
    [0x1e] = {0, 0, 1, -1, 0, 0, 0, -1, 0},
    [0x1f] = {0, 1, 0, 0, 0, -1, -1, 0, 0},
    [0x20] = {0, 0, 1, 0, 1, 0, -1, 0, 0},
    [0x22] = {0, -1, 0, 0, 0, 1, -1, 0, 0},
    [0x23] = {0, 0, -1, 0, -1, 0, -1, 0, 0},
}

local scratch = buffer.create(8)

local function finite(x)
    return x == x and x > -1e12 and x < 1e12
end

local function unzigzag(v)
    local half = v // 2
    if v % 2 == 1 then
        return -half - 1
    end
    return half
end

local function rolledToFloat(v)
    buffer.writeu32(scratch, 0, bit32.rrotate(v, 1))
    return buffer.readf32(scratch, 0)
end

local Reader = {}
Reader.__index = Reader

function Reader.new(buf)
    return setmetatable({buf = buf, pos = 0, limit = buffer.len(buf)}, Reader)
end

function Reader:need(n)
    if n < 0 or self.pos + n > self.limit then
        error("read past end of chunk")
    end
end

function Reader:u8()
    self:need(1)
    local v = buffer.readu8(self.buf, self.pos)
    self.pos += 1
    return v
end

function Reader:u32()
    self:need(4)
    local v = buffer.readu32(self.buf, self.pos)
    self.pos += 4
    return v
end

function Reader:f32()
    self:need(4)
    local v = buffer.readf32(self.buf, self.pos)
    self.pos += 4
    return v
end

function Reader:f64()
    self:need(8)
    local v = buffer.readf64(self.buf, self.pos)
    self.pos += 8
    return v
end

function Reader:str()
    local n = self:u32()
    self:need(n)
    local s = buffer.readstring(self.buf, self.pos, n)
    self.pos += n
    return s
end

function Reader:interleaved(count)
    self:need(count * 4)
    local buf = self.buf
    local base = self.pos
    local out = table.create(count)
    for i = 0, count - 1 do
        out[i + 1] = buffer.readu8(buf, base + i) * 16777216
            + buffer.readu8(buf, base + count + i) * 65536
            + buffer.readu8(buf, base + 2 * count + i) * 256
            + buffer.readu8(buf, base + 3 * count + i)
    end
    self.pos = base + count * 4
    return out
end

function Reader:ints(count)
    local raw = self:interleaved(count)
    for i = 1, count do
        raw[i] = unzigzag(raw[i])
    end
    return raw
end

function Reader:floats(count)
    local raw = self:interleaved(count)
    for i = 1, count do
        raw[i] = rolledToFloat(raw[i])
    end
    return raw
end

function Reader:referents(count)
    local raw = self:ints(count)
    local acc = 0
    for i = 1, count do
        acc += raw[i]
        raw[i] = acc
    end
    return raw
end

function Reader:bytes(count)
    self:need(count)
    local out = table.create(count)
    for i = 1, count do
        out[i] = buffer.readu8(self.buf, self.pos + i - 1)
    end
    self.pos += count
    return out
end

local function lz4Decompress(src, srcPos, srcLen, outLen)
    local out = buffer.create(outLen)
    local si = srcPos
    local srcEnd = srcPos + srcLen
    local di = 0
    while si < srcEnd do
        local token = buffer.readu8(src, si)
        si += 1
        local litLen = bit32.rshift(token, 4)
        if litLen == 15 then
            local b
            repeat
                b = buffer.readu8(src, si)
                si += 1
                litLen += b
            until b ~= 255
        end
        if di + litLen > outLen or si + litLen > srcEnd then
            error("lz4 literal overrun")
        end
        buffer.copy(out, di, src, si, litLen)
        si += litLen
        di += litLen
        if si >= srcEnd then
            break
        end
        local offset = buffer.readu8(src, si) + buffer.readu8(src, si + 1) * 256
        si += 2
        if offset == 0 or offset > di then
            error("lz4 bad match offset")
        end
        local matchLen = bit32.band(token, 15)
        if matchLen == 15 then
            local b
            repeat
                b = buffer.readu8(src, si)
                si += 1
                matchLen += b
            until b ~= 255
        end
        matchLen += 4
        if di + matchLen > outLen then
            error("lz4 match overrun")
        end
        local from = di - offset
        if offset >= matchLen then
            buffer.copy(out, di, out, from, matchLen)
        else
            for k = 0, matchLen - 1 do
                buffer.writeu8(out, di + k, buffer.readu8(out, from + k))
            end
        end
        di += matchLen
    end
    if di ~= outLen then
        error("lz4 output size mismatch")
    end
    return out
end

local Parser = {}

function Parser.readChunks(buf)
    local len = buffer.len(buf)
    if len < 32 then
        error("file too small to be a Roblox binary file")
    end
    local magic = buffer.readstring(buf, 0, 14)
    if magic ~= "<roblox!\137\255\r\n\26\n" then
        if buffer.readstring(buf, 0, 7) == "<roblox" then
            error("XML format (.rbxlx/.rbxmx) is not supported; save as binary .rbxl/.rbxm")
        end
        error("not a Roblox binary file (bad magic)")
    end
    local header = {
        version = buffer.readu16(buf, 14),
        classCount = buffer.readu32(buf, 16),
        instanceCount = buffer.readu32(buf, 20),
    }
    if header.instanceCount > CONFIG.MaxInstances then
        error("instance count " .. header.instanceCount .. " exceeds MaxInstances")
    end
    local chunks = {}
    local pos = 32
    while pos + 16 <= len do
        local name = buffer.readstring(buf, pos, 4)
        local compLen = buffer.readu32(buf, pos + 4)
        local rawLen = buffer.readu32(buf, pos + 8)
        pos += 16
        if rawLen > CONFIG.MaxChunkBytes then
            error("chunk " .. name .. " too large")
        end
        local data
        if compLen == 0 then
            if pos + rawLen > len then
                error("chunk " .. name .. " truncated")
            end
            data = buffer.create(rawLen)
            buffer.copy(data, 0, buf, pos, rawLen)
            pos += rawLen
        else
            if pos + compLen > len then
                error("chunk " .. name .. " truncated")
            end
            data = lz4Decompress(buf, pos, compLen, rawLen)
            pos += compLen
        end
        local clean = name:gsub("%z", "")
        chunks[#chunks + 1] = {name = clean, data = data}
        if clean == "END" then
            break
        end
    end
    return header, chunks
end

local function readColumn(r, typeId, n)
    local out = table.create(n)
    if typeId == 1 then
        for i = 1, n do
            out[i] = r:str()
        end
    elseif typeId == 2 then
        for i = 1, n do
            out[i] = r:u8() ~= 0
        end
    elseif typeId == 3 then
        out = r:ints(n)
    elseif typeId == 4 then
        out = r:floats(n)
        for i = 1, n do
            if not finite(out[i]) then
                out[i] = nil
            end
        end
    elseif typeId == 5 then
        for i = 1, n do
            local v = r:f64()
            out[i] = finite(v) and v or nil
        end
    elseif typeId == 6 then
        local s, o = r:floats(n), r:ints(n)
        for i = 1, n do
            out[i] = {s = s[i], o = o[i]}
        end
    elseif typeId == 7 then
        local sx, sy, ox, oy = r:floats(n), r:floats(n), r:ints(n), r:ints(n)
        for i = 1, n do
            out[i] = {sx = sx[i], sy = sy[i], ox = ox[i], oy = oy[i]}
        end
    elseif typeId == 11 then
        out = r:interleaved(n)
    elseif typeId == 12 then
        local rr, gg, bb = r:floats(n), r:floats(n), r:floats(n)
        for i = 1, n do
            out[i] = {r = rr[i], g = gg[i], b = bb[i]}
        end
    elseif typeId == 13 then
        local x, y = r:floats(n), r:floats(n)
        for i = 1, n do
            if finite(x[i]) and finite(y[i]) then
                out[i] = {x = x[i], y = y[i]}
            end
        end
    elseif typeId == 14 then
        local x, y, z = r:floats(n), r:floats(n), r:floats(n)
        for i = 1, n do
            if finite(x[i]) and finite(y[i]) and finite(z[i]) then
                out[i] = {x = x[i], y = y[i], z = z[i]}
            end
        end
    elseif typeId == 16 then
        local rots = table.create(n)
        for i = 1, n do
            local id = r:u8()
            if id == 0 then
                local m = table.create(9)
                for k = 1, 9 do
                    m[k] = r:f32()
                end
                rots[i] = m
            else
                local m = ROTATIONS[id]
                if not m then
                    error(string.format("unknown CFrame rotation id 0x%02x", id))
                end
                rots[i] = m
            end
        end
        local px, py, pz = r:floats(n), r:floats(n), r:floats(n)
        for i = 1, n do
            local ok = finite(px[i]) and finite(py[i]) and finite(pz[i])
            local m = rots[i]
            for k = 1, 9 do
                ok = ok and finite(m[k])
            end
            if ok then
                out[i] = {x = px[i], y = py[i], z = pz[i], m = m}
            end
        end
    elseif typeId == 18 then
        out = r:interleaved(n)
    elseif typeId == 19 then
        out = r:referents(n)
    elseif typeId == 26 then
        local rr, gg, bb = r:bytes(n), r:bytes(n), r:bytes(n)
        for i = 1, n do
            out[i] = {r = rr[i], g = gg[i], b = bb[i]}
        end
    else
        return nil
    end
    return out
end

function Parser.parse(buf)
    local header, chunks = Parser.readChunks(buf)
    local model = {
        header = header,
        classes = {},
        instances = {},
        parents = {},
        errors = {},
        unsupported = {},
        order = {},
    }
    for index, chunk in ipairs(chunks) do
        local ok, err = pcall(function()
            local r = Reader.new(chunk.data)
            if chunk.name == "INST" then
                local classId = r:u32()
                local className = r:str()
                local hasService = r:u8()
                local count = r:u32()
                if count > CONFIG.MaxInstances then
                    error("INST count too large")
                end
                local refs = r:referents(count)
                local services
                if hasService == 1 then
                    services = r:bytes(count)
                end
                model.classes[classId] = {name = className, refs = refs}
                for i = 1, count do
                    model.instances[refs[i]] = {
                        class = className,
                        service = services ~= nil and services[i] == 1,
                        props = {},
                    }
                    model.order[#model.order + 1] = refs[i]
                end
            elseif chunk.name == "PROP" then
                local classId = r:u32()
                local propName = r:str()
                local typeId = r:u8()
                local cls = model.classes[classId]
                if not cls then
                    error("PROP references unknown class id " .. classId)
                end
                local values = readColumn(r, typeId, #cls.refs)
                if not values then
                    local key = cls.name .. "." .. propName .. " (type " .. typeId .. ")"
                    model.unsupported[key] = true
                    return
                end
                for i, ref in ipairs(cls.refs) do
                    if values[i] ~= nil then
                        model.instances[ref].props[propName] = {t = typeId, v = values[i]}
                    end
                end
            elseif chunk.name == "PRNT" then
                r:u8()
                local count = r:u32()
                local children = r:referents(count)
                local parents = r:referents(count)
                for i = 1, count do
                    model.parents[children[i]] = parents[i]
                end
            end
        end)
        if not ok then
            model.errors[#model.errors + 1] = string.format("chunk #%d %s: %s", index, chunk.name, tostring(err))
        end
    end
    return model
end

function Parser.summarize(model)
    local classCounts = {}
    local total = 0
    for _, inst in pairs(model.instances) do
        classCounts[inst.class] = (classCounts[inst.class] or 0) + 1
        total += 1
    end
    return total, classCounts
end

local XML_ENTITIES = {lt = "<", gt = ">", amp = "&", quot = '"', apos = "'"}

local function xmlDecode(s)
    if not s:find("&", 1, true) then
        return s
    end
    return (s:gsub("&(#?%w+);", function(e)
        if XML_ENTITIES[e] then
            return XML_ENTITIES[e]
        end
        local n
        if e:sub(1, 2) == "#x" then
            n = tonumber(e:sub(3), 16)
        elseif e:sub(1, 1) == "#" then
            n = tonumber(e:sub(2))
        end
        if n and n > 0 and n < 1114112 then
            local ok, ch = pcall(utf8.char, n)
            if ok then
                return ch
            end
        end
        return nil
    end))
end

local function xmlParse(text)
    local root = {tag = "#root", attrs = {}, children = {}, text = ""}
    local stack = {root}
    local pos = 1
    local len = #text
    while pos <= len do
        local lt = text:find("<", pos, true)
        if not lt then
            break
        end
        local top = stack[#stack]
        if lt > pos then
            top.text ..= xmlDecode(text:sub(pos, lt - 1))
        end
        local two = text:sub(lt, lt + 1)
        if text:sub(lt, lt + 3) == "<!--" then
            local e = text:find("-->", lt + 4, true)
            if not e then
                error("unterminated XML comment")
            end
            pos = e + 3
        elseif text:sub(lt, lt + 8) == "<![CDATA[" then
            local e = text:find("]]>", lt + 9, true)
            if not e then
                error("unterminated CDATA section")
            end
            top.text ..= text:sub(lt + 9, e - 1)
            pos = e + 3
        elseif two == "<?" or two == "<!" then
            local e = text:find(">", lt, true)
            if not e then
                error("unterminated XML declaration")
            end
            pos = e + 1
        elseif two == "</" then
            local e = text:find(">", lt, true)
            if not e then
                error("unterminated closing tag")
            end
            local name = text:sub(lt + 2, e - 1):match("^%s*([^%s>]+)")
            if #stack < 2 or stack[#stack].tag ~= name then
                error("mismatched closing tag " .. tostring(name))
            end
            table.remove(stack)
            pos = e + 1
        else
            local e = text:find(">", lt, true)
            if not e then
                error("unterminated tag")
            end
            local inner = text:sub(lt + 1, e - 1)
            local selfClose = inner:sub(-1) == "/"
            if selfClose then
                inner = inner:sub(1, -2)
            end
            local name, rest = inner:match("^([^%s]+)%s*(.*)$")
            if not name then
                error("empty tag name")
            end
            local attrs = {}
            for k, _, v in rest:gmatch("([%w_:%-%.]+)%s*=%s*([\"'])(.-)%2") do
                attrs[k] = xmlDecode(v)
            end
            local node = {tag = name, attrs = attrs, children = {}, text = ""}
            top.children[#top.children + 1] = node
            if not selfClose then
                if #stack > 400 then
                    error("XML nesting too deep")
                end
                stack[#stack + 1] = node
            end
            pos = e + 1
        end
    end
    if #stack ~= 1 then
        error("unclosed XML tags")
    end
    return root
end

local function xmlChild(node, tag)
    for _, c in ipairs(node.children) do
        if c.tag == tag then
            return c
        end
    end
    return nil
end

local function xmlNumber(node, tag)
    local source = node
    if tag then
        source = xmlChild(node, tag)
    end
    if not source then
        return nil
    end
    local v = tonumber((source.text:match("^%s*(.-)%s*$")))
    if v and finite(v) then
        return v
    end
    return nil
end

local function xmlProperty(node)
    local tag = node.tag
    local name = node.attrs.name
    if tag == "string" then
        return 1, node.text
    elseif tag == "ProtectedString" then
        return 1, node.text
    elseif tag == "Content" then
        local url = xmlChild(node, "url")
        if url and url.text ~= "" then
            return 1, url.text
        end
        return nil
    elseif tag == "bool" then
        return 2, node.text:match("^%s*(.-)%s*$"):lower() == "true"
    elseif tag == "int" then
        local v = xmlNumber(node)
        if v == nil then
            return nil
        end
        if name == "BrickColor" then
            return 11, v
        end
        return 3, v
    elseif tag == "float" then
        local v = xmlNumber(node)
        return v ~= nil and 4 or nil, v
    elseif tag == "double" then
        local v = xmlNumber(node)
        return v ~= nil and 5 or nil, v
    elseif tag == "token" then
        local v = xmlNumber(node)
        return v ~= nil and 18 or nil, v
    elseif tag == "BrickColor" then
        local v = xmlNumber(node)
        return v ~= nil and 11 or nil, v
    elseif tag == "Color3uint8" then
        local n = xmlNumber(node)
        if n == nil then
            return nil
        end
        return 26, {r = bit32.band(bit32.rshift(n, 16), 255), g = bit32.band(bit32.rshift(n, 8), 255), b = bit32.band(n, 255)}
    elseif tag == "Color3" then
        local r, g, b = xmlNumber(node, "R"), xmlNumber(node, "G"), xmlNumber(node, "B")
        if r and g and b then
            return 12, {r = r, g = g, b = b}
        end
        local n = xmlNumber(node)
        if n then
            return 12, {r = bit32.band(bit32.rshift(n, 16), 255) / 255, g = bit32.band(bit32.rshift(n, 8), 255) / 255, b = bit32.band(n, 255) / 255}
        end
        return nil
    elseif tag == "Vector3" then
        local x, y, z = xmlNumber(node, "X"), xmlNumber(node, "Y"), xmlNumber(node, "Z")
        if x and y and z then
            return 14, {x = x, y = y, z = z}
        end
        return nil
    elseif tag == "Vector2" then
        local x, y = xmlNumber(node, "X"), xmlNumber(node, "Y")
        if x and y then
            return 13, {x = x, y = y}
        end
        return nil
    elseif tag == "CoordinateFrame" or tag == "CFrame" then
        local x, y, z = xmlNumber(node, "X"), xmlNumber(node, "Y"), xmlNumber(node, "Z")
        if not (x and y and z) then
            return nil
        end
        local m = {}
        local keys = {"R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22"}
        for i, key in ipairs(keys) do
            m[i] = xmlNumber(node, key)
            if m[i] == nil then
                return nil
            end
        end
        return 16, {x = x, y = y, z = z, m = m}
    elseif tag == "UDim" then
        local s, o = xmlNumber(node, "S"), xmlNumber(node, "O")
        if s and o then
            return 6, {s = s, o = o}
        end
        return nil
    elseif tag == "Ref" then
        return nil
    elseif tag == "UDim2" then
        local xs, xo, ys, yo = xmlNumber(node, "XS"), xmlNumber(node, "XO"), xmlNumber(node, "YS"), xmlNumber(node, "YO")
        if xs and xo and ys and yo then
            return 7, {sx = xs, ox = xo, sy = ys, oy = yo}
        end
        return nil
    end
    return false
end

local XML_SERVICE_CLASSES = {
    Workspace = true, Lighting = true, ReplicatedStorage = true, ReplicatedFirst = true,
    ServerStorage = true, ServerScriptService = true, StarterGui = true, StarterPack = true,
    StarterPlayer = true, SoundService = true, Players = true, Teams = true, Chat = true,
    TextChatService = true, MaterialService = true,
}

function Parser.parseXml(text)
    if text:sub(1, 3) == "\239\187\191" then
        text = text:sub(4)
    end
    local doc = xmlParse(text)
    local rootNode = xmlChild(doc, "roblox")
    if not rootNode then
        error("not a Roblox XML file (no roblox root element)")
    end
    local model = {
        header = {version = 0, classCount = 0, instanceCount = 0, format = "xml"},
        classes = {},
        instances = {},
        parents = {},
        errors = {},
        unsupported = {},
        order = {},
    }
    local ids = {}
    local nextId = 0
    local function refId(name)
        local id = ids[name]
        if id == nil then
            id = nextId
            nextId += 1
            ids[name] = id
        end
        return id
    end
    local work = {}
    for i = #rootNode.children, 1, -1 do
        if rootNode.children[i].tag == "Item" then
            work[#work + 1] = {rootNode.children[i], -1, nil}
        end
    end
    local anonymous = 0
    while #work > 0 do
        local entry = table.remove(work)
        local node, parentRef, parentClass = entry[1], entry[2], entry[3]
        local className = node.attrs.class or "Instance"
        local key = node.attrs.referent
        if not key then
            anonymous += 1
            key = "anonymous#" .. anonymous
        end
        local ref = refId(key)
        if #model.order >= CONFIG.MaxInstances then
            error("instance count exceeds MaxInstances")
        end
        local info = {class = className, service = parentClass == "DataModel" or (parentRef == -1 and XML_SERVICE_CLASSES[className] == true), props = {}}
        model.instances[ref] = info
        model.order[#model.order + 1] = ref
        model.parents[ref] = parentRef
        local propsNode = xmlChild(node, "Properties")
        if propsNode then
            for _, p in ipairs(propsNode.children) do
                local propName = p.attrs.name
                if propName then
                    local typeId, value = xmlProperty(p)
                    if typeId == false then
                        if p.tag ~= "ProtectedString" and p.tag ~= "BinaryString" and p.tag ~= "SharedString" then
                            model.unsupported[className .. "." .. propName .. " (xml " .. p.tag .. ")"] = true
                        end
                    elseif typeId ~= nil then
                        info.props[propName] = {t = typeId, v = value}
                    end
                end
            end
            for _, p in ipairs(propsNode.children) do
                if p.tag == "Ref" and p.attrs.name then
                    local text = p.text:match("^%s*(.-)%s*$")
                    if text ~= "" and text ~= "null" and text ~= "nil" then
                        info.props[p.attrs.name] = {t = 19, v = refId(text)}
                    end
                end
            end
        end
        for i = #node.children, 1, -1 do
            if node.children[i].tag == "Item" then
                work[#work + 1] = {node.children[i], ref, className}
            end
        end
    end
    model.header.instanceCount = #model.order
    return model
end

function Parser.parseString(data)
    if data:sub(1, 14) == "<roblox!\137\255\r\n\26\n" then
        return Parser.parse(buffer.fromstring(data))
    end
    local head = data:sub(1, 200)
    if head:find("<roblox", 1, true) or head:find("<?xml", 1, true) then
        return Parser.parseXml(data)
    end
    error("unrecognized file format (not a Roblox binary or XML file)")
end



local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")
local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local player = Players.LocalPlayer

local STATE = {
    original = CONFIG.PlaceInOriginalLocations,
    scripts = {},
}

local SCRIPT_CLASSES = {Script = true, LocalScript = true, ModuleScript = true}
local VERIFY_PROPS = {
    Anchored = true, CanCollide = true, CanTouch = true, CanQuery = true, Massless = true,
    CastShadow = true, Locked = true, Transparency = true, Size = true, size = true, CFrame = true,
}
local EARLY_PROPS = {BrickColor = true, MeshId = true, MeshID = true, TextureID = true, TextureId = true}

local enumCache = {}

local function enumItem(enumType, value)
    local map = enumCache[enumType]
    if not map then
        map = {}
        for _, item in ipairs(enumType:GetEnumItems()) do
            map[item.Value] = item
        end
        enumCache[enumType] = map
    end
    return map[value]
end

local function toRobloxValue(typeId, v)
    if typeId == 6 then
        return UDim.new(v.s, v.o)
    elseif typeId == 7 then
        return UDim2.new(v.sx, v.ox, v.sy, v.oy)
    elseif typeId == 11 then
        return BrickColor.new(v)
    elseif typeId == 12 then
        return Color3.new(v.r, v.g, v.b)
    elseif typeId == 13 then
        return Vector2.new(v.x, v.y)
    elseif typeId == 14 then
        return Vector3.new(v.x, v.y, v.z)
    elseif typeId == 16 then
        local m = v.m
        return CFrame.new(v.x, v.y, v.z, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
    elseif typeId == 26 then
        return Color3.fromRGB(v.r, v.g, v.b)
    end
    return v
end

local function candidateNames(propName)
    local alias = PROPERTY_ALIASES[propName]
    if alias then
        return {alias}
    end
    local first = propName:sub(1, 1)
    if first ~= first:upper() then
        return {propName, first:upper() .. propName:sub(2)}
    end
    return {propName}
end

local function sameValue(a, b)
    local ta = typeof(a)
    if ta ~= typeof(b) then
        return false
    end
    if ta == "number" then
        return math.abs(a - b) <= 1e-3 * math.max(1, math.abs(a))
    elseif ta == "Vector3" or ta == "Vector2" then
        return (a - b).Magnitude <= 1e-3 * math.max(1, a.Magnitude)
    elseif ta == "CFrame" then
        local dp = (a.Position - b.Position).Magnitude
        return dp <= 1e-3 * math.max(1, a.Position.Magnitude) and a.LookVector:Dot(b.LookVector) > 0.9999 and a.UpVector:Dot(b.UpVector) > 0.9999
    elseif ta == "Color3" then
        return math.abs(a.R - b.R) <= 0.01 and math.abs(a.G - b.G) <= 0.01 and math.abs(a.B - b.B) <= 0.01
    end
    return a == b
end

local function setProperty(inst, resolvedNames, classPropKey, propName, typeId, value)
    local names = resolvedNames[classPropKey]
    if names == nil then
        names = candidateNames(propName)
    end
    for _, name in ipairs(names) do
        local okRead, current = pcall(function()
            return inst[name]
        end)
        if okRead then
            local candidate
            if typeId == 18 then
                if typeof(current) == "EnumItem" then
                    candidate = enumItem(current.EnumType, value)
                end
            else
                candidate = toRobloxValue(typeId, value)
            end
            if candidate ~= nil then
                local okSet = pcall(function()
                    inst[name] = candidate
                end)
                if okSet then
                    resolvedNames[classPropKey] = {name}
                    local okBack, back = pcall(function()
                        return inst[name]
                    end)
                    if okBack and sameValue(candidate, back) then
                        return "ok"
                    end
                    return "mismatch"
                end
            end
        end
    end
    return "fail"
end

local function pathOf(model, ref)
    local parts = {}
    local cur = ref
    local guard = 0
    while cur ~= nil and cur >= 0 and guard < 64 do
        local info = model.instances[cur]
        if not info or info.class == "DataModel" then
            break
        end
        local nameProp = info.props.Name
        parts[#parts + 1] = nameProp and tostring(nameProp.v) or info.class
        cur = model.parents[cur]
        guard += 1
    end
    local out = {}
    for i = #parts, 1, -1 do
        out[#out + 1] = parts[i]
    end
    return table.concat(out, "/")
end

local function build(model, container, status, tag, original)
    local created = {}
    local existing = {}
    local mergeable = {}
    local failedClasses = {}
    local failedProps = {}
    local mismatchProps = {}
    local resolvedNames = {}
    local scriptRecords = {}
    local placedRoots = {}
    local pendingRefs = {}
    local stats = {applied = 0, verified = 0, mismatched = 0, sourceApplied = 0, sourceFailed = 0, merged = 0, placed = 0, parented = 0, dropped = 0}
    local count = 0

    for _, ref in ipairs(model.order) do
        local info = model.instances[ref]
        local className = info.class
        if className == "DataModel" then
            created[ref] = nil
        elseif info.service then
            local ok, service = pcall(game.GetService, game, className)
            if ok and service then
                created[ref] = service
            end
        elseif CONFIG.SkipClasses[className] or (SCRIPT_CLASSES[className] and not CONFIG.ImportScripts) then
            created[ref] = nil
        else
            local ok, inst = pcall(Instance.new, className)
            if ok and inst then
                created[ref] = inst
            else
                mergeable[ref] = true
            end
        end
        count += 1
        if count % CONFIG.YieldEvery == 0 then
            status("Creating instances " .. count .. "/" .. #model.order)
            task.wait()
        end
    end

    local function resolveExisting(ref, depth)
        if created[ref] then
            return created[ref]
        end
        if not mergeable[ref] or depth > 64 then
            return nil
        end
        local parentRef = model.parents[ref]
        local parentInst = parentRef and parentRef >= 0 and resolveExisting(parentRef, depth + 1) or nil
        if not parentInst then
            return nil
        end
        local found = parentInst:FindFirstChildOfClass(model.instances[ref].class)
        if found then
            created[ref] = found
            existing[ref] = true
            stats.merged += 1
        end
        return found
    end

    for _, ref in ipairs(model.order) do
        if mergeable[ref] then
            if not original or not resolveExisting(ref, 0) then
                local className = model.instances[ref].class
                failedClasses[className] = (failedClasses[className] or 0) + 1
            end
        end
    end

    local meshParts = {}
    local verifyList = {}
    local function applyProp(inst, info, propName, entry)
        local key = info.class .. "." .. propName
        local result = setProperty(inst, resolvedNames, key, propName, entry.t, entry.v)
        if result == "ok" then
            stats.applied += 1
            stats.verified += 1
        elseif result == "mismatch" then
            stats.applied += 1
            stats.mismatched += 1
            mismatchProps[key] = (mismatchProps[key] or 0) + 1
        else
            failedProps[key] = (failedProps[key] or 0) + 1
        end
        if result ~= "fail" and VERIFY_PROPS[propName] and not info.service then
            local names = resolvedNames[key]
            if names and names[1] then
                verifyList[#verifyList + 1] = {inst = inst, name = names[1], key = key, expected = toRobloxValue(entry.t, entry.v)}
            end
        end
    end

    count = 0
    for _, ref in ipairs(model.order) do
        local inst = created[ref]
        local info = model.instances[ref]
        local isService = info.service
        local applyService = isService and original and CONFIG.ApplyServiceProperties[info.class] == true
        if inst and not existing[ref] and (not isService or applyService) then
            if SCRIPT_CLASSES[info.class] and info.props.Source == nil then
                scriptRecords[#scriptRecords + 1] = {
                    inst = inst,
                    class = info.class,
                    source = "",
                    path = pathOf(model, ref),
                    disabled = (info.props.Disabled ~= nil and info.props.Disabled.v == true) or (info.props.Enabled ~= nil and info.props.Enabled.v == false),
                }
            end
            if not isService then
                for earlyName in pairs(EARLY_PROPS) do
                    local early = info.props[earlyName]
                    if early and early.t ~= 19 then
                        applyProp(inst, info, earlyName, early)
                    end
                end
            end
            local isMesh = info.class == "MeshPart"
            for propName, entry in pairs(info.props) do
                if not isService and EARLY_PROPS[propName] then
                    stats.applied += 0
                elseif isMesh and (propName == "Size" or propName == "size") then
                    stats.applied += 0
                elseif propName == "Source" and SCRIPT_CLASSES[info.class] then
                    local okSrc = pcall(function()
                        inst.Source = entry.v
                    end)
                    if not okSrc and setscriptsource then
                        okSrc = pcall(setscriptsource, inst, entry.v)
                    end
                    if okSrc then
                        stats.sourceApplied += 1
                    else
                        stats.sourceFailed += 1
                    end
                    scriptRecords[#scriptRecords + 1] = {
                        inst = inst,
                        class = info.class,
                        source = entry.v,
                        path = pathOf(model, ref),
                        disabled = (info.props.Disabled ~= nil and info.props.Disabled.v == true) or (info.props.Enabled ~= nil and info.props.Enabled.v == false),
                    }
                elseif isService and (propName == "Name" or entry.t == 19) then
                    stats.applied += 0
                elseif entry.t == 19 then
                    pendingRefs[#pendingRefs + 1] = {inst, propName, entry.v}
                else
                    applyProp(inst, info, propName, entry)
                end
            end
        end
        if inst and not existing[ref] and not isService and info.class == "MeshPart" then
            local sizeName = info.props.Size and "Size" or (info.props.size and "size" or nil)
            if sizeName then
                local sizeEntry = info.props[sizeName]
                applyProp(inst, info, sizeName, sizeEntry)
                meshParts[#meshParts + 1] = {inst = inst, size = toRobloxValue(sizeEntry.t, sizeEntry.v)}
            end
        end
        count += 1
        if count % CONFIG.YieldEvery == 0 then
            status("Setting properties " .. count .. "/" .. #model.order)
            task.wait()
        end
    end

    count = 0
    for _, ref in ipairs(model.order) do
        local inst = created[ref]
        local info = model.instances[ref]
        if inst and not info.service and not existing[ref] then
            local parentRef = model.parents[ref]
            local parentInfo = parentRef and parentRef >= 0 and model.instances[parentRef] or nil
            local parentInst = parentInfo and created[parentRef] or nil
            if parentInst and parentInfo.service then
                if original and CONFIG.PlaceableServices[parentInfo.class] then
                    inst.Parent = parentInst
                    placedRoots[#placedRoots + 1] = inst
                    stats.placed += 1
                elseif not original and CONFIG.FolderModeServices[parentInfo.class] then
                    inst.Parent = container
                    placedRoots[#placedRoots + 1] = inst
                    stats.placed += 1
                else
                    inst:Destroy()
                    created[ref] = nil
                    stats.dropped += 1
                end
            elseif parentInst then
                inst.Parent = parentInst
                stats.parented += 1
            elseif parentRef == nil or parentRef < 0 then
                inst.Parent = container
                placedRoots[#placedRoots + 1] = inst
                stats.placed += 1
            else
                inst:Destroy()
                created[ref] = nil
                stats.dropped += 1
            end
        end
        count += 1
        if count % CONFIG.YieldEvery == 0 then
            status("Parenting " .. count .. "/" .. #model.order)
            task.wait()
        end
    end

    for _, root in ipairs(placedRoots) do
        pcall(CollectionService.AddTag, CollectionService, root, tag)
    end

    local liveScripts = {}
    for _, rec in ipairs(scriptRecords) do
        if rec.inst.Parent ~= nil then
            liveScripts[#liveScripts + 1] = rec
        end
    end

    local refFailures = 0
    for _, item in ipairs(pendingRefs) do
        local inst, propName, targetRef = item[1], item[2], item[3]
        local target = targetRef >= 0 and created[targetRef] or nil
        local ok = false
        for _, name in ipairs(candidateNames(propName)) do
            ok = pcall(function()
                inst[name] = target
            end)
            if ok then
                break
            end
        end
        if not ok then
            refFailures += 1
        end
    end

    return {
        stats = stats,
        failedClasses = failedClasses,
        failedProps = failedProps,
        mismatchProps = mismatchProps,
        refFailures = refFailures,
        scripts = scriptRecords,
        liveScripts = liveScripts,
        meshParts = meshParts,
        verifyList = verifyList,
    }
end

local function exportScripts(records, baseName)
    if not (writefile and makefolder and isfolder) or #records == 0 then
        return 0, nil
    end
    local dir = CONFIG.FolderName .. "/" .. baseName .. "_scripts"
    if not isfolder(dir) then
        pcall(makefolder, dir)
    end
    local used = {}
    local written = 0
    for _, rec in ipairs(records) do
        local base = rec.path:gsub("[^%w_%-%.]", "_")
        used[base] = (used[base] or 0) + 1
        local fileName = used[base] == 1 and base or (base .. "_" .. used[base])
        local content = string.format("-- %s | %s\n", rec.class, rec.path) .. rec.source
        if pcall(writefile, dir .. "/" .. fileName .. ".lua", content) then
            written += 1
        end
    end
    return written, dir
end

local function runLocalScripts(records)
    if not (loadstring and setfenv and getfenv) then
        return "cannot run scripts: loadstring, setfenv or getfenv is missing in this executor"
    end
    local byInst = {}
    local cache = {}
    local errors = {}
    local baseEnv = getfenv()
    local runChunk

    local function makeEnv(rec)
        local env = {script = rec.inst}
        env.require = function(target)
            local mod = typeof(target) == "Instance" and byInst[target] or nil
            if mod and mod.class == "ModuleScript" then
                if cache[mod] == nil then
                    cache[mod] = {}
                    cache[mod].value = runChunk(mod)
                end
                return cache[mod].value
            end
            return baseEnv.require(target)
        end
        return setmetatable(env, {__index = baseEnv})
    end

    runChunk = function(rec)
        local fn, err = loadstring(rec.source, "=" .. rec.path)
        if not fn then
            local head = rec.source:sub(1, 160):gsub("\r", "")
            head = head:gsub("\n", " / ")
            error(tostring(err) .. " | source starts: " .. head)
        end
        setfenv(fn, makeEnv(rec))
        return fn()
    end

    for _, rec in ipairs(records) do
        byInst[rec.inst] = rec
    end
    local started = 0
    local serverSkipped = 0
    local disabledSkipped = 0
    for _, rec in ipairs(records) do
        if rec.class == "LocalScript" then
            if rec.disabled then
                disabledSkipped += 1
            else
                started += 1
                task.spawn(function()
                    local ok, err = pcall(runChunk, rec)
                    if not ok then
                        errors[#errors + 1] = rec.path .. ": " .. tostring(err)
                    end
                end)
            end
        elseif rec.class == "Script" then
            serverSkipped += 1
        end
    end
    task.wait(1)
    local lines = {"started " .. started .. " LocalScripts, skipped " .. disabledSkipped .. " disabled and " .. serverSkipped .. " server Scripts (server code cannot run on the client)"}
    for _, e in ipairs(errors) do
        lines[#lines + 1] = "script error: " .. e:sub(1, 300)
    end
    return table.concat(lines, "\n")
end

local function sortedPairsByCount(map, limit)
    local list = {}
    for k, v in pairs(map) do
        list[#list + 1] = {k, v}
    end
    table.sort(list, function(a, b)
        return a[2] > b[2]
    end)
    local out = {}
    for i = 1, math.min(limit, #list) do
        out[i] = list[i][1] .. " x" .. list[i][2]
    end
    return out
end

local function ensureFolder()
    if not (makefolder and isfolder) then
        return false
    end
    if isfolder(CONFIG.FolderName) then
        return true
    end
    return pcall(makefolder, CONFIG.FolderName)
end

local function resolvePath(name)
    if isfile and not name:find("/", 1, true) then
        local inFolder = CONFIG.FolderName .. "/" .. name
        if isfile(inFolder) then
            return inFolder
        end
    end
    return name
end

local function settleMeshSizes(parts, status)
    if #parts == 0 then
        return 0, true
    end
    status("Waiting for " .. #parts .. " meshes to load")
    local finished = false
    task.spawn(function()
        for i = 1, #parts, 50 do
            local batch = {}
            for j = i, math.min(i + 49, #parts) do
                batch[#batch + 1] = parts[j].inst
            end
            pcall(ContentProvider.PreloadAsync, ContentProvider, batch)
        end
        finished = true
    end)
    local started = os.clock()
    while not finished and os.clock() - started < CONFIG.MeshSettleSeconds do
        task.wait(0.1)
    end
    local corrected = 0
    for _, part in ipairs(parts) do
        local inst = part.inst
        if inst.Parent ~= nil then
            local okRead, current = pcall(function()
                return inst.Size
            end)
            if okRead and not sameValue(current, part.size) then
                if pcall(function()
                    inst.Size = part.size
                end) then
                    corrected += 1
                end
            end
        end
    end
    return corrected, finished
end

local function verifyPass(list, status)
    local summary = {}
    local reapplied = {}
    local stillWrong = {}
    local function check(final)
        for _, item in ipairs(list) do
            local inst = item.inst
            if inst:IsDescendantOf(game) then
                local okRead, current = pcall(function()
                    return inst[item.name]
                end)
                if okRead and not sameValue(current, item.expected) then
                    if final then
                        stillWrong[item.key] = (stillWrong[item.key] or 0) + 1
                    else
                        reapplied[item.key] = (reapplied[item.key] or 0) + 1
                        pcall(function()
                            inst[item.name] = item.expected
                        end)
                    end
                end
            end
        end
    end
    status("Verifying properties after import")
    task.wait(CONFIG.VerifySeconds)
    check(false)
    task.wait(CONFIG.VerifySeconds)
    check(true)
    for _, item in ipairs(list) do
        if typeof(item.expected) == "boolean" and item.inst:IsDescendantOf(game) then
            local row = summary[item.key]
            if not row then
                row = {fileTrue = 0, gameTrue = 0, total = 0}
                summary[item.key] = row
            end
            row.total += 1
            if item.expected then
                row.fileTrue += 1
            end
            local okRead, current = pcall(function()
                return item.inst[item.name]
            end)
            if okRead and current == true then
                row.gameTrue += 1
            end
        end
    end
    return summary, reapplied, stillWrong
end

local function importFile(rawPath, status)
    local path = resolvePath(rawPath)
    if not (readfile and isfile) then
        return false, "readfile/isfile not available in this executor"
    end
    if not isfile(path) then
        return false, "file not found in executor workspace: " .. path
    end
    local okRead, content = pcall(readfile, path)
    local data = tostring(content)
    if not okRead or #data == 0 then
        return false, "could not read file: " .. data
    end
    status("Parsing " .. path .. " (" .. #data .. " bytes)")
    local okParse, model = pcall(Parser.parseString, data)
    if not okParse then
        return false, tostring(model)
    end
    local total, classCounts = Parser.summarize(model)

    local tag = "StudioLiteImport:" .. path
    local replaced = 0
    for _, old in ipairs(CollectionService:GetTagged(tag)) do
        pcall(old.Destroy, old)
        replaced += 1
    end

    local original = STATE.original
    local container = Instance.new("Folder")
    container.Name = "Imported_" .. path:gsub("[^%w_]", "_")
    local result = build(model, container, status, tag, original)
    if #container:GetChildren() > 0 then
        container.Parent = Workspace
        pcall(CollectionService.AddTag, CollectionService, container, tag)
    else
        container:Destroy()
    end
    local stats = result.stats
    STATE.scripts = result.liveScripts
    local meshCorrected, meshFinished = settleMeshSizes(result.meshParts, status)
    local boolSummary, reapplied, stillWrong = verifyPass(result.verifyList, status)

    local baseName = ((path:match("([^/]+)$") or path):gsub("%.%w+$", "")):gsub("[^%w_%-]", "_")
    local written, dir = 0, nil
    if CONFIG.ExportScripts then
        written, dir = exportScripts(result.scripts, baseName)
    end

    local lines = {}
    lines[#lines + 1] = "Imported " .. path .. " (" .. (model.header.format or "binary") .. ") using " .. (original and "original locations" or "a folder in Workspace")
    lines[#lines + 1] = "instances in file: " .. total .. ", placed at top level: " .. stats.placed .. ", nested: " .. stats.parented .. ", dropped: " .. stats.dropped .. ", merged into existing: " .. stats.merged
    if replaced > 0 then
        lines[#lines + 1] = "replaced " .. replaced .. " objects from the previous import of this file"
    end
    if stats.placed == 0 then
        lines[#lines + 1] = "nothing was placed: the file has no importable instances in the chosen locations"
    end
    lines[#lines + 1] = "properties applied: " .. stats.applied .. ", verified by read-back: " .. stats.verified .. ", read back different: " .. stats.mismatched
    if next(result.mismatchProps) then
        lines[#lines + 1] = "read back different: " .. table.concat(sortedPairsByCount(result.mismatchProps, 10), ", ")
    end
    if next(result.failedProps) then
        lines[#lines + 1] = "properties that did not apply: " .. table.concat(sortedPairsByCount(result.failedProps, 12), ", ")
    end
    if result.refFailures > 0 then
        lines[#lines + 1] = "object-reference properties that did not apply: " .. result.refFailures
    end
    if next(result.failedClasses) then
        lines[#lines + 1] = "classes that could not be created: " .. table.concat(sortedPairsByCount(result.failedClasses, 8), ", ")
    end
    local boolKeys = {}
    for key in pairs(boolSummary) do
        boolKeys[#boolKeys + 1] = key
    end
    table.sort(boolKeys)
    for _, key in ipairs(boolKeys) do
        local row = boolSummary[key]
        lines[#lines + 1] = key .. ": parts " .. row.total .. ", true in file " .. row.fileTrue .. ", true in game now " .. row.gameTrue
    end
    if next(reapplied) then
        lines[#lines + 1] = "changed after being set, re-applied: " .. table.concat(sortedPairsByCount(reapplied, 10), ", ")
    end
    if next(stillWrong) then
        lines[#lines + 1] = "still different after re-apply (something in this game keeps changing them): " .. table.concat(sortedPairsByCount(stillWrong, 10), ", ")
    end
    if #result.meshParts > 0 then
        lines[#lines + 1] = "mesh parts: " .. #result.meshParts .. ", size re-applied after the mesh loaded: " .. meshCorrected .. (meshFinished and "" or " (mesh loading did not finish in time)")
    end
    local scriptCount = (classCounts.Script or 0) + (classCounts.LocalScript or 0) + (classCounts.ModuleScript or 0)
    if scriptCount > 0 then
        lines[#lines + 1] = "scripts in file: " .. scriptCount .. ", placed in the game: " .. #result.liveScripts .. ", not placed (location unavailable): " .. (#result.scripts - #result.liveScripts)
        lines[#lines + 1] = "source written into the instance: " .. stats.sourceApplied .. ", refused by the executor: " .. stats.sourceFailed
        if dir then
            lines[#lines + 1] = "script sources saved as " .. written .. " .lua files in Workspace/" .. dir
        end
    end
    lines[#lines + 1] = "top classes: " .. table.concat(sortedPairsByCount(classCounts, 8), ", ")
    local unsupported = {}
    for k in pairs(model.unsupported) do
        unsupported[#unsupported + 1] = k
    end
    table.sort(unsupported)
    if #unsupported > 0 then
        lines[#lines + 1] = "unsupported property types (skipped): " .. table.concat(unsupported, ", "):sub(1, 600)
    end
    for _, e in ipairs(model.errors) do
        lines[#lines + 1] = "chunk error: " .. e
    end
    lines[#lines + 1] = "objects exist on this client only; the server and other players do not see them"
    return true, table.concat(lines, "\n")
end

local function listImportable()
    local out = {}
    if not listfiles then
        return out
    end
    for _, dir in ipairs({CONFIG.FolderName, ""}) do
        local ok, files = pcall(listfiles, dir)
        if ok and type(files) == "table" then
            for _, f in ipairs(files) do
                local lower = f:lower()
                for _, ext in ipairs(CONFIG.FileExtensions) do
                    if lower:sub(-#ext) == ext then
                        out[#out + 1] = f
                    end
                end
            end
        end
    end
    return out
end

local function buildUi()
    local gui = Instance.new("ScreenGui")
    gui.Name = "StudioLiteImport"
    gui.ResetOnSpawn = false
    local okParent = pcall(function()
        gui.Parent = (gethui and gethui()) or CoreGui
    end)
    if not okParent then
        gui.Parent = player:WaitForChild("PlayerGui")
    end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 300, 0, 372)
    frame.Position = UDim2.new(0.5, -150, 0.5, -186)
    frame.BackgroundColor3 = Color3.fromRGB(37, 37, 38)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = gui

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -40, 0, 30)
    title.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    title.BorderSizePixel = 0
    title.Text = "  Import .rbxl / .rbxm"
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Font = Enum.Font.SourceSansBold
    title.TextSize = 16
    title.Parent = frame

    local close = Instance.new("TextButton")
    close.Size = UDim2.new(0, 40, 0, 30)
    close.Position = UDim2.new(1, -40, 0, 0)
    close.BackgroundColor3 = Color3.fromRGB(150, 40, 40)
    close.BorderSizePixel = 0
    close.Text = "X"
    close.TextColor3 = Color3.new(1, 1, 1)
    close.Parent = frame
    close.MouseButton1Click:Connect(function()
        gui:Destroy()
    end)

    local input = Instance.new("TextBox")
    input.Size = UDim2.new(1, -90, 0, 32)
    input.Position = UDim2.new(0, 8, 0, 38)
    input.BackgroundColor3 = Color3.fromRGB(51, 51, 51)
    input.BorderSizePixel = 0
    input.PlaceholderText = "file name, e.g. map.rbxl"
    input.Text = ""
    input.ClearTextOnFocus = false
    input.TextColor3 = Color3.new(1, 1, 1)
    input.PlaceholderColor3 = Color3.fromRGB(150, 150, 150)
    input.Parent = frame

    local go = Instance.new("TextButton")
    go.Size = UDim2.new(0, 70, 0, 32)
    go.Position = UDim2.new(1, -78, 0, 38)
    go.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
    go.BorderSizePixel = 0
    go.Text = "Import"
    go.TextColor3 = Color3.new(1, 1, 1)
    go.Parent = frame

    local list = Instance.new("ScrollingFrame")
    list.Size = UDim2.new(1, -16, 0, 80)
    list.Position = UDim2.new(0, 8, 0, 78)
    list.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 4
    list.CanvasSize = UDim2.new(0, 0, 0, 0)
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.Parent = frame
    local listLayout = Instance.new("UIListLayout")
    listLayout.Parent = list

    local mode = Instance.new("TextButton")
    mode.Size = UDim2.new(1, -16, 0, 28)
    mode.Position = UDim2.new(0, 8, 0, 164)
    mode.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    mode.BorderSizePixel = 0
    mode.TextColor3 = Color3.new(1, 1, 1)
    mode.Parent = frame
    local function refreshMode()
        mode.Text = STATE.original and "Placement: original locations" or "Placement: inside a folder"
    end
    refreshMode()
    mode.MouseButton1Click:Connect(function()
        STATE.original = not STATE.original
        refreshMode()
    end)

    local output = Instance.new("ScrollingFrame")
    output.Size = UDim2.new(1, -16, 0, 132)
    output.Position = UDim2.new(0, 8, 0, 198)
    output.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    output.BorderSizePixel = 0
    output.ScrollBarThickness = 4
    output.CanvasSize = UDim2.new(0, 0, 0, 0)
    output.AutomaticCanvasSize = Enum.AutomaticSize.Y
    output.Parent = frame
    local outputText = Instance.new("TextLabel")
    outputText.Size = UDim2.new(1, -8, 0, 0)
    outputText.AutomaticSize = Enum.AutomaticSize.Y
    outputText.BackgroundTransparency = 1
    outputText.TextWrapped = true
    outputText.TextXAlignment = Enum.TextXAlignment.Left
    outputText.TextYAlignment = Enum.TextYAlignment.Top
    outputText.TextColor3 = Color3.fromRGB(220, 220, 220)
    outputText.TextSize = 13
    outputText.Text = "Put an .rbxl or .rbxm file in Workspace/" .. CONFIG.FolderName .. ", then pick it above or type its name."
    outputText.Parent = output

    local copy = Instance.new("TextButton")
    copy.Size = UDim2.new(0.5, -12, 0, 30)
    copy.Position = UDim2.new(0, 8, 1, -38)
    copy.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    copy.BorderSizePixel = 0
    copy.Text = "Copy report"
    copy.TextColor3 = Color3.new(1, 1, 1)
    copy.Parent = frame
    copy.MouseButton1Click:Connect(function()
        if setclipboard then
            setclipboard(outputText.Text)
        end
    end)

    local run = Instance.new("TextButton")
    run.Size = UDim2.new(0.5, -12, 0, 30)
    run.Position = UDim2.new(0.5, 4, 1, -38)
    run.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
    run.BorderSizePixel = 0
    run.Text = "Run LocalScripts"
    run.TextColor3 = Color3.new(1, 1, 1)
    run.Parent = frame
    run.MouseButton1Click:Connect(function()
        if #STATE.scripts == 0 then
            outputText.Text = "No scripts from the last import to run."
            return
        end
        task.spawn(function()
            local ok, message = pcall(runLocalScripts, STATE.scripts)
            outputText.Text = ok and message or ("Run failed: " .. tostring(message))
        end)
    end)

    local function refreshList()
        for _, c in ipairs(list:GetChildren()) do
            if c:IsA("TextButton") then
                c:Destroy()
            end
        end
        for _, f in ipairs(listImportable()) do
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 26)
            b.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
            b.BorderSizePixel = 0
            b.Text = f
            b.TextColor3 = Color3.new(1, 1, 1)
            b.Parent = list
            b.MouseButton1Click:Connect(function()
                input.Text = f
            end)
        end
    end
    refreshList()

    local busy = false
    go.MouseButton1Click:Connect(function()
        if busy or input.Text == "" then
            return
        end
        busy = true
        go.Text = "..."
        task.spawn(function()
            local ok, success, report = pcall(importFile, input.Text, function(s)
                outputText.Text = s
            end)
            if not ok then
                outputText.Text = "Import failed: " .. tostring(success)
            elseif not success then
                outputText.Text = "Import failed: " .. tostring(report)
            else
                outputText.Text = tostring(report)
            end
            go.Text = "Import"
            busy = false
            refreshList()
        end)
    end)
end

ensureFolder()
buildUi()
