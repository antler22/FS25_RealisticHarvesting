-- Test helper: a small stand-in for the engine's legacy XML API (loadXMLFile, hasXMLProperty,
-- getXMLString/Float/Bool, delete, fileExists), backed by the REAL file on disk so tests exercise
-- the same XML the game reads. Understands the key syntax the mod uses:
--     cropThroughput.moistureSettings.crop(3)#target
-- i.e. dotted element names, (0-based index) for repeated elements, and #attribute.
--
-- Usage:  local xml = dofile("tests/xmlstub.lua"); xml.install()
local M = {}

local function parseAttrs(s)
    local attrs = {}
    for k, v in s:gmatch('([%w_:%-]+)%s*=%s*"([^"]*)"') do attrs[k] = v end
    return attrs
end

-- Returns the root element: { name, attrs, children = { ... } }.
function M.parse(text)
    text = text:gsub("<%?.-%?>", ""):gsub("<!%-%-.-%-%->", "")
    local root = { name = "#document", attrs = {}, children = {} }
    local stack = { root }
    for closing, name, body, selfClose in text:gmatch("<(/?)([%w_:%-]+)([^>]-)(/?)>") do
        if closing == "/" then
            table.remove(stack)
        else
            local node = { name = name, attrs = parseAttrs(body), children = {} }
            local parent = stack[#stack]
            parent.children[#parent.children + 1] = node
            if selfClose ~= "/" then stack[#stack + 1] = node end
        end
    end
    return root.children[1]
end

-- Resolve "a.b(2).c#attr" against a root element. Returns node, attrName.
local function resolve(root, key)
    local path, attr = key:match("^([^#]*)#?(.*)$")
    if attr == "" then attr = nil end
    local node
    local first = true
    for seg in path:gmatch("[^.]+") do
        local name, idx = seg:match("^([%w_:%-]+)%((%d+)%)$")
        if not name then name = seg end
        if first then
            if root.name ~= name then return nil end
            node = root
            first = false
        else
            local found, count = nil, -1
            for _, ch in ipairs(node.children) do
                if ch.name == name then
                    count = count + 1
                    if count == (tonumber(idx) or 0) then found = ch; break end
                end
            end
            if not found then return nil end
            node = found
        end
    end
    return node, attr
end

function M.install(defaultPath)
    local handles, nextId = {}, 0
    function fileExists(p) local f = io.open(p, "rb"); if f then f:close(); return true end; return false end
    function loadXMLFile(_, path)
        local f = io.open(path or defaultPath, "rb")
        if not f then return 0 end
        local text = f:read("*a"); f:close()
        nextId = nextId + 1
        handles[nextId] = M.parse(text)
        return nextId
    end
    function delete(h) handles[h] = nil end
    function hasXMLProperty(h, key)
        local node, attr = resolve(handles[h], key)
        if not node then return false end
        if attr then return node.attrs[attr] ~= nil end
        return true
    end
    function getXMLString(h, key)
        local node, attr = resolve(handles[h], key)
        return node and attr and node.attrs[attr] or nil
    end
    function getXMLFloat(h, key)
        local v = getXMLString(h, key)
        return v and tonumber(v) or nil
    end
    function getXMLBool(h, key)
        local v = getXMLString(h, key)
        if v == nil then return nil end
        return v == "true" or v == "1"
    end
end

return M
