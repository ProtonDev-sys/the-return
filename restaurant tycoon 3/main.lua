-- RTHelper (drop-in, ultra-perf + tray-safe serving; everything OFF by default)
-- Seat -> Take Orders -> Auto Cook (burst) -> Serve (single-hold; FIFO queue) -> Bills/Dishes (per-table ChildAdded hooks)
-- Notes:
--  - All features start DISABLED. Open UI (RightShift) to enable specific toggles.
--  - Serving logic: never grabs another plate while a tray is in Character; while tray exists,
--    keep serving the queue head until the tray (held plate) disappears.
--  - Order queue is O(1) ring buffer. Player orders are ignored.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local LocalPlayer       = Players.LocalPlayer

-- ===== Debug / utils =====
local DEBUG = false
local function dprint(...) if DEBUG then print("[RTHelper]", ...) end end
local function now() return os.clock() end

local function path(parent, ...)
    local cur = parent
    for _, n in ipairs({...}) do cur = cur:WaitForChild(n) end
    return cur
end
local function waitRequire(inst, label, timeout)
    local t0 = os.clock()
    repeat
        local ok, m = pcall(require, inst)
        if ok and m then return m end
        task.wait(0.1)
    until os.clock() - t0 > (timeout or 10)
    error(("[RTHelper] require timeout for %s"):format(label))
end
local function toStringId(v) return (typeof(v)=="number") and tostring(v) or v end
local function keyFor(gid,cid) return tostring(gid).."|"..tostring(cid) end
local function nameIn(list, s) for _,n in ipairs(list) do if n==s then return true end end end
local function readIdValue(v)
    if v:IsA("StringValue") then return v.Value end
    if v:IsA("IntValue") or v:IsA("NumberValue") then return tostring(v.Value) end
end

-- ===== Tycoon =====
local function resolveTycoon()
    local ov = LocalPlayer:WaitForChild("Tycoon", 5)
    if ov and ov:IsA("ObjectValue") and ov.Value then return ov.Value end
    local tycoons = Workspace:FindFirstChild("Tycoons")
    if tycoons then
        for _, m in ipairs(tycoons:GetChildren()) do
            local p = m:FindFirstChild("Player")
            if p and p:IsA("ObjectValue") and p.Value == LocalPlayer then return m end
        end
        return tycoons:FindFirstChild("Tycoon") or path(Workspace,"Tycoons","Tycoon")
    end
    return path(Workspace,"Tycoons","Tycoon")
end
local Tycoon = resolveTycoon()
print("[RTHelper] tycoon:", Tycoon.Name)

-- ===== Modules =====
local PS = LocalPlayer:WaitForChild("PlayerScripts", 10)
local FurnitureUtility       = waitRequire(path(ReplicatedStorage,"Source","Utility","FurnitureUtility"), "FurnitureUtility")
local TableConnectionUtility = waitRequire(path(ReplicatedStorage,"Source","Utility","Furniture","TableConnectionUtility"), "TableConnectionUtility")
local Customers              = waitRequire(path(PS,"Source","Systems","Restaurant","Customers"), "Customers")
local CustomerState          = waitRequire(path(ReplicatedStorage,"Source","Enums","Restaurant","Customer","CustomerState"), "CustomerState")
local Cook                   = waitRequire(path(PS,"Source","Systems","Cook"), "Cook")
local CookReplication        = waitRequire(path(ReplicatedStorage,"Source","Enums","Cook","CookReplication"), "CookReplication")
local TaskEnum               = waitRequire(path(ReplicatedStorage,"Source","Enums","Restaurant","Task"), "Task")

-- ===== Remotes / Roots =====
local Events        = path(ReplicatedStorage,"Events")
local Restaurant    = path(Events,"Restaurant")
local TaskCompleted = path(Restaurant,"TaskCompleted")
local GrabFoodRF    = path(Restaurant,"GrabFood")
local Interacted    = path(Restaurant,"Interactions","Interacted")

local CookEvents    = path(Events,"Cook")
local CookUpdated   = path(CookEvents,"CookUpdated")
local CookInputReq  = path(CookEvents,"CookInputRequested")

local Items      = path(Tycoon,"Items")
local Surface    = Items:FindFirstChild("Surface") or Items
local Objects    = path(Tycoon,"Objects")
local FoodFolder = Objects:FindFirstChild("Food") or path(Objects,"Food")

-- ===== Flags / tuners (ALL OFF by default) =====
local flags = {
    autoSeatOrder = false,
    autoCook      = false,
    autoServe     = false,
    housekeeping  = false,
    antiAFK       = false,
}
local tuners = {
    seatPeriod   = 0.35,
    cookPeriod   = 0.25,
    servePeriod  = 0.05,
    serveDelay   = 0.05,
    serveTimeout = 1.20,
    holdGrace    = 0.70,
}
local ORDER_COOLDOWN = 0.5
local SEAT_COOLDOWN  = 1.5
local SEAT_RETRY_SEC = 3.0

-- ===== Player names (skip player orders) =====
local playerNames = {}
for _,plr in ipairs(Players:GetPlayers()) do playerNames[plr.Name] = true end
Players.PlayerAdded:Connect(function(plr) playerNames[plr.Name] = true end)
Players.PlayerRemoving:Connect(function(plr) playerNames[plr.Name] = nil end)
local function looksLikePlayerName(s) return s and playerNames[tostring(s)] == true end

-- ===== Tables (cache) =====
local tablesDirty = true
local tableList, tableMeta = {}, {} -- [Model] = { seats=#, plate=Base.PlateHeight? }

local function findTables()
    local out = {}
    local ok, list = pcall(FurnitureUtility.FindWhere, FurnitureUtility, Tycoon, Surface, function(inst)
        local ok2, isT = pcall(FurnitureUtility.IsTable, FurnitureUtility, inst); return ok2 and isT
    end)
    if ok and type(list)=="table" and #list>0 then
        for _, v in ipairs(list) do if typeof(v)=="Instance" and v:IsA("Model") then out[#out+1] = v end end
        return out
    end
    for _, d in ipairs(Surface:GetChildren()) do
        if d:IsA("Model") then
            local b = d:FindFirstChild("Base")
            if (d.Name:match("^T%d+") or (b and b:FindFirstChild("PlateHeight"))) then out[#out+1] = d end
        end
    end
    return out
end
local function rebuildTables()
    tableList, tableMeta = findTables(), {}
    for _, tbl in ipairs(tableList) do
        local base  = tbl:FindFirstChild("Base")
        local plate = base and base:FindFirstChild("PlateHeight")
        local seats = 0
        local ok, linked = pcall(TableConnectionUtility.FindChairs, TableConnectionUtility, Tycoon, tbl)
        if ok and type(linked)=="table" then seats = #linked end
        tableMeta[tbl] = { seats = seats, plate = plate }
    end
    tablesDirty = false
    dprint("tables cached:", #tableList)
end
local function ensureTables() if tablesDirty or #tableList==0 then rebuildTables() end end
Surface.ChildAdded:Connect(function() tablesDirty = true end)
Surface.ChildRemoved:Connect(function() tablesDirty = true end)

-- ===== Active table watchers (event-driven housekeeping) =====
local tableWatch = {} -- [tbl] = { addConn=..., ancConn=..., billConns={...} }

local function disconnectWatch(tbl)
    local rec = tableWatch[tbl]; if not rec then return end
    if rec.addConn then pcall(function() rec.addConn:Disconnect() end) end
    if rec.ancConn then pcall(function() rec.ancConn:Disconnect() end) end
    if rec.billConns then for _,c in ipairs(rec.billConns) do pcall(function() c:Disconnect() end) end end
    tableWatch[tbl] = nil
end

local function tryCollectDishes(tbl)
    if not flags.housekeeping then return end
    if tbl and tbl.Parent then
        if _G.__RTH_carryingSince and (now() - _G.__RTH_carryingSince < tuners.holdGrace) then
            task.delay(0.25, function() tryCollectDishes(tbl) end)
            return
        end
        TaskCompleted:FireServer({ Name=TaskEnum.CollectDishes, FurnitureModel=tbl, Tycoon=Tycoon })
        dprint("Collect dishes", tbl.Name)
    end
end
local function tryCollectBill(tbl, bill)
    if not flags.housekeeping then return end
    if not (tbl and tbl.Parent and bill and bill.Parent==tbl) then return end
    if bill:GetAttribute("Taken") == true then return end
    if _G.__RTH_carryingSince and (now() - _G.__RTH_carryingSince < tuners.holdGrace) then
        task.delay(0.25, function() tryCollectBill(tbl, bill) end)
        return
    end
    TaskCompleted:FireServer({ Name=TaskEnum.CollectBill, FurnitureModel=tbl, Tycoon=Tycoon })
    dprint("Collect bill", tbl.Name)
end
local function maybeCleanupTableWatch(tbl)
    if not tbl or not tbl.Parent then disconnectWatch(tbl); return end
    local bill = tbl:FindFirstChild("Bill")
    local trash = tbl:FindFirstChild("Trash")
    local inUse = tbl:GetAttribute("InUse") == true
    if (not inUse) and (not bill) and (not trash) then disconnectWatch(tbl) end
end
local function wireBillSignals(tbl, bill)
    local rec = tableWatch[tbl]; if not rec then return end
    rec.billConns = rec.billConns or {}
    table.insert(rec.billConns, bill:GetAttributeChangedSignal("Taken"):Connect(function()
        if bill:GetAttribute("Taken") ~= true then
            tryCollectBill(tbl, bill)
        else
            task.defer(function() maybeCleanupTableWatch(tbl) end)
        end
    end))
    table.insert(rec.billConns, bill.AncestryChanged:Connect(function(_, parent)
        if parent ~= tbl then task.defer(function() maybeCleanupTableWatch(tbl) end) end
    end))
end
local function watchTable(tbl)
    if not tbl or not tbl.Parent or tableWatch[tbl] then return end
    local rec = {}
    rec.addConn = tbl.ChildAdded:Connect(function(ch)
        if ch.Name == "Trash" then
            tryCollectDishes(tbl)
        elseif ch.Name == "Bill" then
            tryCollectBill(tbl, ch)
            wireBillSignals(tbl, ch)
        end
    end)
    rec.ancConn = tbl.AncestryChanged:Connect(function(_, parent)
        if not parent then disconnectWatch(tbl) end
    end)
    tableWatch[tbl] = rec
    local bill = tbl:FindFirstChild("Bill")
    if bill then tryCollectBill(tbl, bill); wireBillSignals(tbl, bill) end
    if tbl:FindFirstChild("Trash") then tryCollectDishes(tbl) end
end

-- ===== Customers =====
local charIndex = {} -- ["gid|cid"]=character model
local function enumerateCustomersByModule()
    local out, seen = {}, {}
    local roots = {}
    local objCustomers = Objects:FindFirstChild("Customers")
    local tyCustomers  = Tycoon:FindFirstChild("Customers")
    local tyNPCs       = Tycoon:FindFirstChild("NPCs")
    if objCustomers then roots[#roots+1] = objCustomers end
    if tyCustomers  then roots[#roots+1] = tyCustomers end
    if tyNPCs       then roots[#roots+1] = tyNPCs end
    roots[#roots+1] = Tycoon
    for _, root in ipairs(roots) do
        for _, group in ipairs(root:GetChildren()) do
            if group:IsA("Folder") or group:IsA("Model") then
                local gid = group:GetAttribute("GroupId") or group:GetAttribute("Id")
                if gid then
                    for _, char in ipairs(group:GetChildren()) do
                        if char:IsA("Model") and char:FindFirstChildOfClass("Humanoid") then
                            local cid = char:GetAttribute("CustomerId") or char:GetAttribute("Id")
                            if cid then
                                local k = keyFor(gid,cid)
                                if not seen[k] then
                                    seen[k] = true
                                    local G, C = toStringId(gid), toStringId(cid)
                                    out[#out+1] = { group=group, char=char, gid=G, cid=C }
                                    charIndex[keyFor(G,C)] = char
                                end
                            end
                        end
                    end
                end
            end
        end
        if #out > 0 then break end
    end
    return out
end
local function enumerateCustomersByGui()
    local out = {}
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui"); if not pg then return out end
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("BillboardGui") and gui.Name=="CustomerSpeechUI" and gui.Adornee then
            local head = gui.Adornee
            local char = head and head.Parent
            local group = char and char.Parent
            if char and group then
                local gid = toStringId(group:GetAttribute("GroupId") or group:GetAttribute("Id") or group.Name)
                local cid = toStringId(char:GetAttribute("CustomerId") or char:GetAttribute("Id") or char.Name)
                out[#out+1] = { group=group, char=char, gid=gid, cid=cid }
                charIndex[keyFor(gid,cid)] = char
            end
        end
    end
    return out
end
local function enumerateCustomers()
    local m = enumerateCustomersByModule()
    if #m > 0 then return m end
    return enumerateCustomersByGui()
end
local function refreshCharIndex() enumerateCustomers() end
local function getChar(gid,cid) return charIndex[keyFor(gid,cid)] end

-- ===== Player-order detection =====
local playerishAttr = { "IsPlayer","PlayerId","Player","PlayerName","Username","DisplayName" }
local function isPlayerishObject(obj)
    if not obj then return false end
    for _, n in ipairs(playerishAttr) do
        local v = obj:GetAttribute(n)
        if v ~= nil then
            if (n == "IsPlayer" and v == true) then return true end
            if (n == "PlayerId" and tonumber(v)) then return true end
            if (n == "Player" and typeof(v)=="Instance" and v:IsA("Player")) then return true end
            if (n == "PlayerName" or n=="Username" or n=="DisplayName") and looksLikePlayerName(v) then return true end
        end
    end
    for _, ch in ipairs(obj:GetChildren()) do
        if ch:IsA("ObjectValue") and ch.Name:lower():find("player") and ch.Value and ch.Value:IsA("Player") then return true end
        if ch:IsA("StringValue") and (ch.Name=="PlayerName" or ch.Name=="Username" or ch.Name=="DisplayName") and looksLikePlayerName(ch.Value) then return true end
    end
    return false
end
local function isPlayerCustomer(gid,cid)
    local char = getChar(gid,cid)
    if not char then return false end
    if looksLikePlayerName(char.Name) then return true end
    return isPlayerishObject(char) or isPlayerishObject(char.Parent)
end

-- ===== Seat + Order =====
local seatCD, seatPending, seatedOrQueued, orderCD = {}, {}, {}, {}

local function bestTableFor(group)
    ensureTables()
    local size = 0
    for _, c in ipairs(group:GetChildren()) do
        if c:IsA("Model") or c:IsA("Folder") then size += 1 end
    end
    if size == 0 then size = 1 end
    local best, bestSeats = nil, math.huge
    for _, tbl in ipairs(tableList) do
        local md = tableMeta[tbl]
        if md.plate and (tbl:GetAttribute("InUse") ~= true) and md.seats > 0 then
            if md.seats >= size and md.seats < bestSeats then best, bestSeats = tbl, md.seats end
        end
    end
    return best
end

local function seatAndOrderTick()
    if not flags.autoSeatOrder then return end
    local t = now()
    local cus = enumerateCustomers()

    -- Take orders
    for _, rec in ipairs(cus) do
        local gid, cid = rec.gid, rec.cid
        local ok, st = pcall(Customers.GetCustomerState, Customers, Tycoon, gid, cid)
        if ok and st == CustomerState.Ordering then
            local key = keyFor(gid,cid)
            if (t - (orderCD[key] or 0)) >= ORDER_COOLDOWN then
                TaskCompleted:FireServer({ Name=TaskEnum.TakeOrder, GroupId=gid, Tycoon=Tycoon, CustomerId=cid })
                orderCD[key] = t
                dprint("TakeOrder", gid, cid)
            end
        end
    end

    -- Group seating
    local groupsById, seenGids = {}, {}
    for _, rec in ipairs(cus) do groupsById[rec.gid] = rec.group; seenGids[rec.gid] = true end
    for gid in pairs(seatedOrQueued) do
        if not seenGids[gid] then seatedOrQueued[gid]=nil; seatPending[gid]=nil; seatCD[gid]=nil end
    end
    for gid, group in pairs(groupsById) do
        local canSeat = (t - (seatCD[gid] or 0)) >= SEAT_COOLDOWN
        local pendAt  = seatPending[gid]
        if pendAt and (t - pendAt) < SEAT_RETRY_SEC then canSeat = false end

        local progressing = false
        local gok, gstate = pcall(Customers.GetGroupState, Customers, Tycoon, gid)
        if gok and gstate ~= nil then
            if gstate == CustomerState.GoingToTable or gstate == CustomerState.Seated
            or gstate == CustomerState.Ordering    or gstate == CustomerState.WaitingForDish then progressing = true end
        end
        if progressing then seatedOrQueued[gid]=true; canSeat=false end

        if (not seatedOrQueued[gid]) and canSeat then
            local tbl = bestTableFor(group)
            if tbl then
                TaskCompleted:FireServer({ Name=TaskEnum.SendToTable, GroupId=gid, Tycoon=Tycoon, FurnitureModel=tbl })
                seatCD[gid]=t; seatPending[gid]=t; seatedOrQueued[gid]=true
                watchTable(tbl)
                dprint("SendToTable", gid, tbl.Name)
            end
        end
    end

    enumerateCustomers()
end

-- ===== Waiting queue (O(1) ring) & signals =====
local Q = { data = {}, head = 1, tail = 0, present = {} } -- present[key]=true to avoid dupes
local function qlen(q) return q.tail - q.head + 1 end
local function qpush(q, key)
    if q.present[key] then return end
    q.tail = q.tail + 1
    q.data[q.tail] = key
    q.present[key] = true
end
local function qpop(q)
    if q.head > q.tail then return nil end
    local key = q.data[q.head]
    q.data[q.head] = nil
    q.head = q.head + 1
    q.present[key] = nil
    return key
end
local function qremove(q, key)
    if not q.present[key] then return end
    -- lazy remove: mark absent; real removal happens when popped past.
    q.present[key] = nil
end

local function enqueueWaiter(gid, cid)
    if isPlayerCustomer(gid,cid) then return end
    qpush(Q, keyFor(gid,cid))
end
local function dequeueIfPresent(gid, cid)
    qremove(Q, keyFor(gid,cid))
end

if Customers.CustomerStateChanged then
    Customers.CustomerStateChanged:Connect(function(ty, gid, cid, _, state)
        if ty ~= Tycoon then return end
        gid, cid = toStringId(gid), toStringId(cid)
        if state == CustomerState.WaitingForDish then
            enqueueWaiter(gid, cid)
        else
            dequeueIfPresent(gid, cid)
        end
    end)
end

-- ===== Plates =====
local function isFoodPlate(inst)
    if not (typeof(inst)=="Instance" and inst:IsA("Model")) then return false end
    local n = tostring(inst.Name)
    if n:lower() == "trash" then return false end
    return n:match("^%d+$") ~= nil
end
local dishAttrNames = { "DishId","Dish","FoodId","Food","RecipeId","MealId","ItemId" }
local function readDishIdFromPlate(plate)
    local id = tostring(plate.Name or "")
    if id == "" or id:lower()=="trash" then id = nil end
    if not id then
        for _, n in ipairs(dishAttrNames) do local v = plate:GetAttribute(n); if v ~= nil then id = tostring(v) break end end
    end
    return id
end
local gidAttrNames = { "GroupId","GroupID","Group","GID" }
local cidAttrNames = { "CustomerId","CustomerID","Customer","CID" }
local function plateTargetIds(plate)
    local gid, cid
    for _, n in ipairs(gidAttrNames) do local v = plate:GetAttribute(n); if v ~= nil then gid = tostring(v) break end end
    for _, n in ipairs(cidAttrNames) do local v = plate:GetAttribute(n); if v ~= nil then cid = tostring(v) break end end
    if gid and cid then return gid, cid end
    return nil, nil
end

local PlateQ, seenPlates = {}, {}
local function pq_push(p) PlateQ[#PlateQ+1] = p end
local function pq_pop()
    if #PlateQ == 0 then return nil end
    local p = PlateQ[1]; table.remove(PlateQ,1); return p
end
local function recordPlate(plate)
    if not isFoodPlate(plate) or seenPlates[plate] then return end
    seenPlates[plate] = true
    pq_push(plate)
    dprint("Plate +", plate.Name)
end
local function scanFoodFolderOnce() for _, ch in ipairs(FoodFolder:GetChildren()) do recordPlate(ch) end end
FoodFolder.ChildAdded:Connect(recordPlate)
FoodFolder.ChildRemoved:Connect(function(ch) seenPlates[ch] = nil end)

-- ===== Tray / carry detection =====
local function charModel()
    local c = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    return c
end
local function hasTray()
    local c = LocalPlayer.Character
    if not c then return false end
    for _, ch in ipairs(c:GetChildren()) do
        if ch:IsA("Model") then
            local n = ch.Name:lower()
            if n:find("tray") or n:find("serv") then return true end
            -- cheap: also consider a model that contains a numeric-named plate
            for _, cc in ipairs(ch:GetChildren()) do
                if cc:IsA("Model") and isFoodPlate(cc) then return true end
            end
        end
    end
    return false
end
local function getHeldPlate()
    local c = LocalPlayer.Character
    if not c then return nil end
    for _, ch in ipairs(c:GetChildren()) do
        if ch:IsA("Model") and isFoodPlate(ch) then return ch end
        if ch:IsA("Model") then
            for _, cc in ipairs(ch:GetChildren()) do
                if cc:IsA("Model") and isFoodPlate(cc) then return cc end
            end
        end
    end
    return nil
end

-- ===== Serving (tray-safe; FIFO queue) =====
local function serveConfirm(gid, cid, plate)
    local deadline = now() + tuners.serveTimeout
    while now() < deadline do
        TaskCompleted:FireServer({
            Name       = TaskEnum.Serve,
            GroupId    = gid,
            Tycoon     = Tycoon,
            FoodModel  = plate,
            CustomerId = cid
        })
        local miniEnd = now() + tuners.serveDelay
        while now() < miniEnd do
            task.wait(0.02)
            if not plate.Parent then return true end
            local ok, st = pcall(Customers.GetCustomerState, Customers, Tycoon, gid, cid)
            if ok and st ~= CustomerState.WaitingForDish then return true end
        end
    end
    return not plate.Parent
end

local function nextNonPlayerKey()
    -- pop until we find a still-present NPC waiter
    while true do
        local k = qpop(Q)
        if not k then return nil end
        if Q.present[k] == false then -- lazily removed marker (not used; defensive)
            -- skip
        else
            local gid, cid = k:match("^(.-)|(.-)$")
            if gid and cid and (not isPlayerCustomer(gid,cid)) then
                -- confirm still waiting
                local ok, st = pcall(Customers.GetCustomerState, Customers, Tycoon, gid, cid)
                if ok and st == CustomerState.WaitingForDish then
                    return gid, cid, k
                end
            end
        end
    end
end

local function serveLoopTick()
    if not flags.autoServe then return end

    -- If tray present, try to deliver; don't pick up anything new.
    if hasTray() then
        local plate = getHeldPlate()
        if plate then
            -- Try mapped first (if any), else FIFO waiter head
            local mgid, mcid = plateTargetIds(plate)
            local served = false
            if mgid and mcid and (not isPlayerCustomer(mgid,mcid)) then
                served = serveConfirm(mgid, mcid, plate)
                if served then dequeueIfPresent(mgid, mcid) end
            end
            if not served then
                local gid, cid, _ = nextNonPlayerKey()
                if gid and cid then
                    served = serveConfirm(gid, cid, plate)
                    if not served then
                        -- failed: push back to queue tail and retry next tick
                        enqueueWaiter(gid, cid)
                    end
                end
            end
            if served then
                _G.__RTH_carryingSince = nil
            else
                -- Keep holding; try again next tick
            end
        else
            -- Tray model may exist briefly without a plate: wait a moment
        end
        return
    end

    -- No tray -> pick up next available plate if any waiter exists
    if qlen(Q) <= 0 then return end
    if #PlateQ == 0 then scanFoodFolderOnce() end
    local plate = pq_pop()
    if not (plate and plate.Parent and plate:IsDescendantOf(FoodFolder)) then return end

    local okGrab = pcall(function() GrabFoodRF:InvokeServer(plate) end)
    if okGrab then
        _G.__RTH_carryingSince = now()
    else
        -- couldn't grab; requeue if still there
        if plate.Parent and plate:IsDescendantOf(FoodFolder) then pq_push(plate) end
    end
end

-- ===== Cooking (burst) =====
local cookActive, cookLast = false, 0
if Cook.Started  then Cook.Started:Connect (function(ty) if ty==Tycoon then cookActive=true;  cookLast=now(); end end) end
if Cook.Finished then Cook.Finished:Connect(function(ty) if ty==Tycoon then cookActive=false; cookLast=now(); end end) end

local function pressOrderCounter()
    local ok, list = pcall(FurnitureUtility.FindWhere, FurnitureUtility, Tycoon, Surface, function(inst)
        local o, isOC = pcall(FurnitureUtility.Is, FurnitureUtility, inst, FurnitureUtility.ItemType.OrderCounter)
        return o and isOC
    end)
    if not (ok and type(list)=="table" and #list>0) then return false end
    local counter = list[1]
    local prompt
    for _, d in ipairs(counter:GetChildren()) do
        if d:IsA("ProximityPrompt") then prompt=d; break end
    end
    if not prompt then
        for _, ch in ipairs(counter:GetChildren()) do
            for _, dd in ipairs(ch:GetChildren()) do
                if dd:IsA("ProximityPrompt") then prompt=dd; break end
            end
            if prompt then break end
        end
    end
    local fpp = getfenv().fireproximityprompt
    if prompt and typeof(fpp)=="function" then pcall(fpp,prompt); return true end
    local base = counter:FindFirstChildOfClass("BasePart") or counter:FindFirstChild("Base")
    if base and base:IsA("BasePart") then
        Interacted:FireServer(Tycoon, {
            WorldPosition=base.Position, HoldDuration=0, Id="0",
            TemporaryPart=base, Model=counter, ActionText="Cook",
            Prompt=prompt, Part=base, InteractionType="OrderCounter"
        })
        return true
    end
    return false
end
local function burst(model, itemType, key)
    CookInputReq:FireServer(CookReplication.CompleteTask, model, itemType)
    if key ~= nil and itemType ~= nil then CookInputReq:FireServer(CookReplication.CompleteTask, itemType, key, false) end
    task.defer(function()
        CookInputReq:FireServer(CookReplication.CompleteTask, model, itemType)
        if key ~= nil and itemType ~= nil then CookInputReq:FireServer(CookReplication.CompleteTask, itemType, key, false) end
    end)
end
CookUpdated.OnClientEvent:Connect(function(op, ...)
    local a = { ... }
    if op == CookReplication.DirectToEquipment or op == CookReplication.UpdateInteraction then
        local ty, model, itemType, key = a[1], a[2], a[3], a[4]
        if ty ~= Tycoon then return end
        cookActive = true; cookLast = now()
        CookInputReq:FireServer(CookReplication.Interact, model, itemType)
        burst(model, itemType, key)
    elseif op == CookReplication.Start then
        cookActive = true; cookLast = now()
    elseif op == CookReplication.Finish then
        cookActive = false; cookLast = now()
    end
end)
if Cook.StateUpdated then
    Cook.StateUpdated:Connect(function(state)
        if not state then return end
        cookActive = true; cookLast = now()
        burst(nil, nil, state.InstructionKey)
    end)
end
local function cookTick()
    if not flags.autoCook then return end
    if (not cookActive) or (now() - cookLast > 0.6) then
        pressOrderCounter()
    end
end

-- ===== Loops =====
task.spawn(function() while true do pcall(seatAndOrderTick); task.wait(tuners.seatPeriod) end end)
task.spawn(function() while true do pcall(serveLoopTick);   task.wait(tuners.servePeriod) end end)
task.spawn(function() while true do pcall(cookTick);        task.wait(tuners.cookPeriod) end end)
task.spawn(function() while task.wait(180) do if Workspace:FindFirstChild("Temp") then Workspace.Temp:ClearAllChildren() end end end)

-- Prime tables (watchers are cheap & gated by flags)
ensureTables()
for _, tbl in ipairs(tableList) do
    local inUse = tbl:GetAttribute("InUse") == true
    if inUse or tbl:FindFirstChild("Bill") or tbl:FindFirstChild("Trash") then
        watchTable(tbl)
    end
end
scanFoodFolderOnce()

-- ===== Anti-AFK (gated) =====
do
    local vu = game:GetService("VirtualUser")
    LocalPlayer.Idled:Connect(function()
        if flags.antiAFK then vu:CaptureController(); vu:ClickButton2(Vector2.new()) end
    end)
end

-- ===== UI (ProUI: toggles only; start OFF) =====
task.defer(function()
    local URL = "https://raw.githubusercontent.com/ProtonDev-sys/the-return/refs/heads/main/ui%20library/ui%20library.lua"

    local ok, ProUI = pcall(function()
        return loadstring(game:HttpGet(URL))()
    end)
    if not ok or type(ProUI) ~= "table" then
        warn("[RTHelper] ProUI load failed:", tostring(ProUI))
        return
    end

    -- Window
    local ui = ProUI.new({
        id    = "RT3_HELPER_TOGGLES",
        title = "RT3 Helper",
        theme = "Midnight Slate",
        size  = Vector2.new(520, 360),
        save  = true,
        key   = Enum.KeyCode.RightShift,
    })

    local tab = ui:Tab("Automation")
    local sec = tab:Section("Features", false)

    -- helper to bind a toggle to flags[key] with saved state (DEFAULT OFF)
    local function bindToggle(label, key)
        local saved = ui:LoadState("toggle_" .. key, false) -- default false
        flags[key] = saved

        local t = sec:Toggle(label, saved, function(v)
            flags[key] = v
            ui:SaveState("toggle_" .. key, v)
        end)
        if t and t.Set then t:Set(saved, false) end
    end

    bindToggle("Auto Seat + Order", "autoSeatOrder")
    bindToggle("Auto Serve",        "autoServe")
    bindToggle("Auto Cook (burst)", "autoCook")
    bindToggle("Bills + Dishes",    "housekeeping")
    bindToggle("Anti-AFK",          "antiAFK")

    ui:Notification("All features start OFF. Toggle what you need.", "info", 3)
end)

print("[RTHelper] loaded (all features OFF by default; tray-safe serving).")
