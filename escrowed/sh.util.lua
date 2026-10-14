RZ = RZ or {}

local Time, Geo, Id, Util, S = {}, {}, {}, {}, {}
RZ.Time, RZ.Geo, RZ.Id, RZ.Util, RZ.Serializer = Time, Geo, Id, Util, S

local floor = math.floor
local sqrt = math.sqrt
local huge = math.huge

local function daysFromCivil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = floor((y >= 0 and y or (y - 399)) / 400)
    local yoe = y - era * 400
    local mp = (m > 2) and (m - 3) or (m + 9)
    local doy = floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function civilFromDays(z)
    z = z + 719468
    local era = floor((z >= 0 and z or (z - 146096)) / 146097)
    local doe = z - era * 146097
    local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
    local mp = floor((5 * doy + 2) / 153)
    local d = doy - floor((153 * mp + 2) / 5) + 1
    local m = (mp < 10) and (mp + 3) or (mp - 9)
    if m <= 2 then y = y + 1 end
    return y, m, d
end

local function weekdayFromDays(z)
    return (z + 4) % 7
end

function Time.ClockAt(utc, offsetSeconds)
    offsetSeconds = tonumber(offsetSeconds) or 0
    local localSecs = utc + offsetSeconds
    local days = floor(localSecs / 86400)
    local rem = localSecs - days * 86400
    local y, mo, d = civilFromDays(days)
    return {
        year   = y,
        month  = mo,
        day    = d,
        hour   = floor(rem / 3600),
        min    = floor((rem % 3600) / 60),
        sec    = rem % 60,
        wday   = weekdayFromDays(days),
        offset = offsetSeconds,
    }
end

function Time.OffsetLabel(offsetSeconds)
    offsetSeconds = tonumber(offsetSeconds) or 0
    if offsetSeconds == 0 then return 'UTC' end
    local sign = offsetSeconds < 0 and '-' or '+'
    local abs = offsetSeconds < 0 and -offsetSeconds or offsetSeconds
    local h = floor(abs / 3600)
    local m = floor((abs % 3600) / 60)
    if m == 0 then return ('UTC%s%d'):format(sign, h) end
    return ('UTC%s%d:%02d'):format(sign, h, m)
end

function Time.NowUtc()
    return os.time()
end

function Time.IsHourInWindow(hour, openHour, closeHour)
    if openHour == closeHour then return true end
    if openHour < closeHour then
        return hour >= openHour and hour < closeHour
    end
    return hour >= openHour or hour < closeHour
end

function Time.SecondsUntilScheduleChange(clock, openHour, closeHour)
    local isOpen = Time.IsHourInWindow(clock.hour, openHour, closeHour)
    local targetHour = isOpen and closeHour or openHour
    local nowSecs = clock.hour * 3600 + clock.min * 60 + clock.sec
    local delta = targetHour * 3600 - nowSecs
    if delta <= 0 then delta = delta + 86400 end
    return delta, isOpen
end

function Time.AddDays(y, m, d, delta)
    return civilFromDays(daysFromCivil(y, m, d) + delta)
end

function Time.SessionId(clock, openHour, closeHour)
    if not Time.IsHourInWindow(clock.hour, openHour, closeHour) then
        return nil
    end
    return Time.SessionIdUnchecked(clock, openHour, closeHour)
end

function Time.SessionIdUnchecked(clock, openHour, closeHour)
    local y, m, d = clock.year, clock.month, clock.day
    if openHour > closeHour and clock.hour < closeHour then
        y, m, d = Time.AddDays(y, m, d, -1)
    end
    return ('%04d-%02d-%02d'):format(y, m, d)
end

function Geo.Dist2D(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

function Geo.Dist3D(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function Geo.ProjectOutward(center, coords, distance)
    local dx, dy = coords.x - center.x, coords.y - center.y
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.01 then
        dx, dy, len = 1.0, 0.0, 1.0
    end
    return vec3(center.x + (dx / len) * distance, center.y + (dy / len) * distance, coords.z)
end

function Geo.PointInPolygon(point, polygon)
    if type(polygon) ~= 'table' then return false end
    local n = #polygon
    if n < 3 then return false end
    local px, py = point.x + 0.0, point.y + 0.0
    local inside = false
    local j = n
    for i = 1, n do
        local a, b = polygon[i], polygon[j]
        local ax, ay = a.x + 0.0, a.y + 0.0
        local bx, by = b.x + 0.0, b.y + 0.0
        if (ay > py) ~= (by > py) then
            local x = (bx - ax) * (py - ay) / (by - ay) + ax
            if px < x then inside = not inside end
        end
        j = i
    end
    return inside
end

function Geo.InZone(point, zone)
    if not zone or type(zone.points) ~= 'table' then return false end
    local z = point.z
    if zone.minZ and z and z < zone.minZ then return false end
    if zone.maxZ and z and z > zone.maxZ then return false end
    return Geo.PointInPolygon(point, zone.points)
end

local function closestOnSegment(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local lenSq = dx * dx + dy * dy
    if lenSq <= 0.0 then
        local ox, oy = px - ax, py - ay
        return ax, ay, ox * ox + oy * oy
    end
    local t = ((px - ax) * dx + (py - ay) * dy) / lenSq
    if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
    local cx, cy = ax + t * dx, ay + t * dy
    local ox, oy = px - cx, py - cy
    return cx, cy, ox * ox + oy * oy
end

function Geo.NearestEdgePoint(point, polygon)
    local n = #polygon
    local px, py = point.x + 0.0, point.y + 0.0
    local bestX, bestY, bestSq = px, py, huge
    local j = n
    for i = 1, n do
        local a, b = polygon[j], polygon[i]
        local cx, cy, dSq = closestOnSegment(px, py, a.x + 0.0, a.y + 0.0, b.x + 0.0, b.y + 0.0)
        if dSq < bestSq then
            bestX, bestY, bestSq = cx, cy, dSq
        end
        j = i
    end
    return bestX, bestY, sqrt(bestSq)
end

function Geo.EjectFromPolygon(point, polygon, padding)
    local ex, ey = Geo.NearestEdgePoint(point, polygon)
    local dx, dy = ex - (point.x + 0.0), ey - (point.y + 0.0)
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.001 then
        local cx, cy = Geo.Centroid(polygon)
        dx, dy = ex - cx, ey - cy
        len = sqrt(dx * dx + dy * dy)
        if len < 0.001 then return ex, ey end
    end
    local nx, ny = dx / len, dy / len
    local tx, ty = ex + nx * padding, ey + ny * padding
    if Geo.PointInPolygon({ x = tx, y = ty }, polygon) then
        local cx, cy = Geo.Centroid(polygon)
        local ox, oy = (point.x + 0.0) - cx, (point.y + 0.0) - cy
        local olen = sqrt(ox * ox + oy * oy)
        if olen < 0.001 then ox, oy, olen = 1.0, 0.0, 1.0 end
        local reach = Geo.BoundingRadius(polygon) + padding + 1.0
        tx, ty = cx + (ox / olen) * reach, cy + (oy / olen) * reach
    end
    return tx, ty
end

function Geo.SignedArea2(polygon)
    local n = #polygon
    local sum = 0.0
    local j = n
    for i = 1, n do
        local a, b = polygon[j], polygon[i]
        sum = sum + (a.x * b.y - b.x * a.y)
        j = i
    end
    return sum
end

function Geo.PolygonArea(polygon)
    if #polygon < 3 then return 0.0 end
    return math.abs(Geo.SignedArea2(polygon)) * 0.5
end

function Geo.Centroid(polygon)
    local n = #polygon
    if n == 0 then return 0.0, 0.0 end
    local a2 = Geo.SignedArea2(polygon)
    if math.abs(a2) < 0.0001 then
        local sx, sy = 0.0, 0.0
        for i = 1, n do sx, sy = sx + polygon[i].x, sy + polygon[i].y end
        return sx / n, sy / n
    end
    local cx, cy = 0.0, 0.0
    local j = n
    for i = 1, n do
        local p, q = polygon[j], polygon[i]
        local cross = p.x * q.y - q.x * p.y
        cx = cx + (p.x + q.x) * cross
        cy = cy + (p.y + q.y) * cross
        j = i
    end
    local f = 1.0 / (3.0 * a2)
    return cx * f, cy * f
end

function Geo.BoundingRadius(polygon)
    local cx, cy = Geo.Centroid(polygon)
    local best = 0.0
    for i = 1, #polygon do
        local dx, dy = polygon[i].x - cx, polygon[i].y - cy
        local d = sqrt(dx * dx + dy * dy)
        if d > best then best = d end
    end
    return best
end

function Geo.Bounds(polygon)
    local minX, minY = huge, huge
    local maxX, maxY = -huge, -huge
    for i = 1, #polygon do
        local p = polygon[i]
        if p.x < minX then minX = p.x end
        if p.y < minY then minY = p.y end
        if p.x > maxX then maxX = p.x end
        if p.y > maxY then maxY = p.y end
    end
    return minX, minY, maxX, maxY
end

local function segmentsCross(ax, ay, bx, by, cx, cy, dx, dy)
    local function cross(ox, oy, px, py, qx, qy)
        return (px - ox) * (qy - oy) - (py - oy) * (qx - ox)
    end
    local d1 = cross(cx, cy, dx, dy, ax, ay)
    local d2 = cross(cx, cy, dx, dy, bx, by)
    local d3 = cross(ax, ay, bx, by, cx, cy)
    local d4 = cross(ax, ay, bx, by, dx, dy)
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0))
       and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
end

function Geo.IsSimplePolygon(polygon)
    local n = #polygon
    if n < 3 then return false, 'a zone needs at least 3 points' end
    local MIN_EDGE = 1.0
    for i = 1, n do
        local a, b = polygon[i], polygon[i % n + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        if sqrt(dx * dx + dy * dy) < MIN_EDGE then
            return false, ('points %d and %d are less than %.1fm apart'):format(i, i % n + 1, MIN_EDGE)
        end
    end
    for i = 1, n do
        local a, b = polygon[i], polygon[i % n + 1]
        for j = i + 1, n do
            local adjacent = (j == i) or (j % n + 1 == i) or (j == i % n + 1)
            if not adjacent then
                local c, d = polygon[j], polygon[j % n + 1]
                if segmentsCross(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y) then
                    return false, ('edges %d and %d cross'):format(i, j)
                end
            end
        end
    end
    return true, nil
end

function Geo.DerivedCenter(polygon, z)
    local cx, cy = Geo.Centroid(polygon)
    return vec3(cx, cy, (z or 0.0) + 0.0)
end

Geo.DerivedRadius = Geo.BoundingRadius

local function spansAt(poly, y, out)
    local n, xs = #poly, {}
    for i = 1, n do
        local a, b = poly[i], poly[i % n + 1]
        if (a.y <= y) ~= (b.y <= y) then
            xs[#xs + 1] = a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
        end
    end
    table.sort(xs)
    local m = 0
    for i = 1, #xs - 1, 2 do
        if xs[i + 1] - xs[i] > 0.25 then
            m = m + 1
            out[m] = { xs[i], xs[i + 1] }
        end
    end
    for i = #out, m + 1, -1 do out[i] = nil end
    return out
end

function Geo.PolygonBlipParts(poly, detail, maxParts)
    if type(poly) ~= 'table' or #poly < 3 then return {} end
    detail = math.max(0.5, tonumber(detail) or 8.0)
    maxParts = math.max(1, tonumber(maxParts) or 64)

    local rows, seen = {}, {}
    for i = 1, #poly do
        local y = math.floor(poly[i].y * 100 + 0.5) / 100
        if not seen[y] then seen[y] = true; rows[#rows + 1] = y end
    end
    table.sort(rows)

    local parts, lo, hi, sub = {}, {}, {}, {}
    for _ = 1, 8 do
        parts = {}
        for k = 1, #rows - 1 do
            local y0, y1 = rows[k], rows[k + 1]
            local h = y1 - y0
            if h >= 0.25 then
                local eps = math.min(h * 0.02, 0.05)
                spansAt(poly, y0 + eps, lo)
                spansAt(poly, y1 - eps, hi)
                local flat = #lo == #hi
                if flat then
                    for i = 1, #lo do
                        if math.abs(lo[i][1] - hi[i][1]) > 0.35 or math.abs(lo[i][2] - hi[i][2]) > 0.35 then
                            flat = false
                            break
                        end
                    end
                end
                local steps = flat and 1 or math.max(1, math.ceil(h / detail))
                for s = 0, steps - 1 do
                    local a0, a1 = y0 + h * s / steps, y0 + h * (s + 1) / steps
                    spansAt(poly, (a0 + a1) * 0.5, sub)
                    for i = 1, #sub do
                        parts[#parts + 1] = {
                            x = (sub[i][1] + sub[i][2]) * 0.5,
                            y = (a0 + a1) * 0.5,
                            w = sub[i][2] - sub[i][1],
                            h = a1 - a0,
                        }
                    end
                end
            end
        end
        if #parts <= maxParts then break end
        detail = detail * 1.75
    end

    return parts
end

local idCounter = 0
local HEX = '0123456789abcdef'

local function randomHex(len)
    local out = {}
    for i = 1, len do
        local n = math.random(1, 16)
        out[i] = HEX:sub(n, n)
    end
    return table.concat(out)
end

function Id.New(prefix)
    idCounter = idCounter + 1
    return ('%s_%x_%x_%s'):format(prefix, os.time(), idCounter, randomHex(16))
end

function Util.FormatDuration(ms)
    local total = math.max(0, floor(ms / 1000))
    local m = floor(total / 60)
    local s = total % 60
    if m > 0 then
        return ('%dm %02ds'):format(m, s)
    end
    return ('%ds'):format(s)
end

function Util.CopyArray(t)
    local out = {}
    for i = 1, #t do out[i] = t[i] end
    return out
end

function Util.PackageFor(zoneId)
    local zone = zoneId and Config.Zones[zoneId]
    return (zone and zone.package) or Config.Items.package
end

function S.IsVector(v)
    local t = type(v)
    if t == 'vector3' then return true, false end
    if t == 'vector4' then return true, true end
    if t == 'table' and type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number' then
        return true, type(v.w) == 'number'
    end
    return false, false
end

function S.VectorToJson(v)
    local isVec, hasW = S.IsVector(v)
    if not isVec then return nil end
    local out = { x = v.x + 0.0, y = v.y + 0.0, z = v.z + 0.0 }
    if hasW then out.w = v.w + 0.0 end
    return out
end

function S.JsonToVector(t)
    if type(t) ~= 'table' then return nil end
    local x, y, z, w = tonumber(t.x), tonumber(t.y), tonumber(t.z), tonumber(t.w)
    if not x or not y or not z then return nil end
    for _, n in ipairs({ x, y, z }) do
        if n ~= n or n == huge or n == -huge then return nil end
    end
    if w then
        if w ~= w or w == huge or w == -huge then return nil end
        return vec4(x, y, z, w)
    end
    return vec3(x, y, z)
end

function S.ToJson(value)
    if S.IsVector(value) then return S.VectorToJson(value) end
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do
        out[k] = S.ToJson(v)
    end
    return out
end

function S.FromJson(value)
    if type(value) ~= 'table' then return value end
    if S.IsVector(value) then
        local vec = S.JsonToVector(value)
        if vec then return vec end
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = S.FromJson(v)
    end
    return out
end

function S.SplitPath(path)
    if type(path) ~= 'string' or path == '' or #path > 200 then return nil end
    if path:find('[^%w_%.%-]') then return nil end
    if path:find('%.%.') or path:sub(1, 1) == '.' or path:sub(-1) == '.' then return nil end
    local segments = {}
    for segment in path:gmatch('[^%.]+') do
        segments[#segments + 1] = segment
    end
    return #segments > 0 and segments or nil
end

function S.Get(root, path)
    local segments = S.SplitPath(path)
    if not segments then return nil end
    local node = root
    for i = 1, #segments do
        if type(node) ~= 'table' then return nil end
        local key = segments[i]
        local value = node[key]
        if value == nil then
            local n = tonumber(key)
            if n then value = node[n] end
        end
        if value == nil then return nil end
        node = value
    end
    return node
end

function S.Set(root, path, value)
    local segments = S.SplitPath(path)
    if not segments then return false end
    local node = root
    for i = 1, #segments - 1 do
        local key = segments[i]
        local n = tonumber(key)
        if n and node[n] ~= nil then key = n end
        if type(node[key]) ~= 'table' then
            node[key] = {}
        end
        node = node[key]
    end
    local last = segments[#segments]
    local lastNum = tonumber(last)
    if lastNum and node[lastNum] ~= nil then last = lastNum end
    node[last] = value
    return true
end

function S.IsArray(t)
    if type(t) ~= 'table' then return false end
    return t[1] ~= nil or next(t) == nil
end

function S.DeepMerge(target, override)
    for k, v in pairs(override) do
        if type(v) == 'table' and not S.IsVector(v) and type(target[k]) == 'table'
            and not S.IsVector(target[k]) and not S.IsArray(v) then
            S.DeepMerge(target[k], v)
        else
            target[k] = v
        end
    end
end

function S.Copy(value)
    if type(value) ~= 'table' then return value end
    if S.IsVector(value) then
        local hasW = type(value.w) == 'number'
        return hasW and vec4(value.x, value.y, value.z, value.w) or vec3(value.x, value.y, value.z)
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = S.Copy(v)
    end
    return out
end

function S.Describe(value)
    local isVec, hasW = S.IsVector(value)
    if isVec then
        if hasW then
            return ('%.4f, %.4f, %.4f, %.4f'):format(value.x, value.y, value.z, value.w)
        end
        return ('%.4f, %.4f, %.4f'):format(value.x, value.y, value.z)
    end
    local t = type(value)
    if t == 'boolean' then return value and 'true' or 'false' end
    if t == 'nil' then return '(unset)' end
    if t == 'number' then
        if value == floor(value) then return tostring(floor(value)) end
        return ('%.4f'):format(value)
    end
    if t == 'string' then return value end
    if t == 'table' then
        local parts, count = {}, 0
        for _, v in ipairs(value) do
            count = count + 1
            if count > 8 then parts[#parts + 1] = '…' break end
            parts[#parts + 1] = type(v) == 'table' and '{…}' or tostring(v)
        end
        if #parts > 0 then return '[' .. table.concat(parts, ', ') .. ']' end
        local keys = 0
        for _ in pairs(value) do keys = keys + 1 end
        return ('{%d field(s)}'):format(keys)
    end
    return tostring(value)
end

function S.Equal(a, b)
    local aVec, aW = S.IsVector(a)
    local bVec, bW = S.IsVector(b)
    if aVec or bVec then
        if not (aVec and bVec) or aW ~= bW then return false end
        if a.x ~= b.x or a.y ~= b.y or a.z ~= b.z then return false end
        if aW and a.w ~= b.w then return false end
        return true
    end
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do
        if not S.Equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
