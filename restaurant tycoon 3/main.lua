-- RTHelper (single-file, perf-tuned + player-order ignore + stale-prune)
-- Seat -> Take Orders -> Auto Cook (burst) -> Serve (single-hold, order-driven) -> Bills/Dishes (active tables only)

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

-- ===== Flags / tuners =====
local flags = {
    autoSeatOrder = true,
    autoCook      = true,
    autoServe     = true,
    housekeeping  = true,
    antiAFK       = true,
}
local tuners = {
    seatPeriod   = 0.35,
    cookPeriod   = 0.25,
    servePeriod  = 0.04,
    serveDelay   = 0.05,
    serveTimeout = 1.20,
    housePeriod  = 0.20,  -- sliced over active tables
    holdGrace    = 0.70,  -- treat as "holding" shortly after grab (reparent jitter)
}
local ORDER_COOLDOWN = 0.5
local SEAT_COOLDOWN  = 1.5
local SEAT_RETRY_SEC = 3.0

-- ===== Player name cache (for player-order detection) =====
local playerNames = {}
for _,plr in ipairs(Players:GetPlayers()) do playerNames[plr.Name] = true end
Players.PlayerAdded:Connect(function(plr) playerNames[plr.Name] = true end)
Players.PlayerRemoving:Connect(function(plr) playerNames[plr.Name] = nil end)
local function looksLikePlayerName(s) return s and playerNames[tostring(s)] == true end

-- ===== Tables (cache once; updated by child add/remove) =====
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

-- ===== Active table set (for housekeeping) =====
local activeTables = {}  -- [tableModel] = true
local activeList   = {}  -- array mirror for sliced iteration
local activeIdx    = 1
local function addActive(tbl)
    if not tbl or not tbl.Parent or activeTables[tbl] then return end
    activeTables[tbl] = true
    activeList[#activeList+1] = tbl
    dprint("Active+", tbl.Name)
end
local function removeActive(tbl)
    if not tbl or not activeTables[tbl] then return end
    activeTables[tbl] = nil
    for i,v in ipairs(activeList) do if v==tbl then table.remove(activeList, i) break end end
    dprint("Active-", tbl and tbl.Name or "?")
end

-- ===== Customers (lightweight discovery + char index) =====
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

-- ===== Player-order detection (skip these completely) =====
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

-- ===== Read desired dish (bounded) =====
local dishNames  = { "DishId","Dish","FoodId","Food","RecipeId","MealId","ItemId","Order","OrderId","Wanted","Requested","FoodType","Meal" }
local function readDesiredDishFromChar(char)
    if not char then return nil end
    for _, n in ipairs(dishNames) do
        local v = char:GetAttribute(n)
        if v ~= nil then return tostring(v) end
    end
    for _, ch in ipairs(char:GetChildren()) do
        if ch:IsA("ValueBase") and nameIn(dishNames, ch.Name) then
            local val = readIdValue(ch); if val then return val end
        end
    end
    local n = 0
    for _, d in ipairs(char:GetChildren()) do
        n += 1; if n > 80 then break end
        for _, g in ipairs(d:GetChildren()) do
            if g:IsA("ValueBase") and nameIn(dishNames, g.Name) then
                local val = readIdValue(g); if val then return val end
            end
        end
    end
    return nil
end

-- ===== Seat + Order (adds table into active set) =====
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
                addActive(tbl)
                dprint("SendToTable", gid, tbl.Name)
            end
        end
    end

    enumerateCustomers() -- keep char index fresh
end

-- ===== Waiting and dish desires (event-driven; skip players) =====
local waitingIndex = {}               -- ["gid|cid"]=true
local desiredFoodByCustomer = {}      -- ["gid|cid"]=dishId
local waitingByFood = {}              -- [dishId]={ "gid|cid", ... }

local function pushWaitingForDish(gid, cid)
    if isPlayerCustomer(gid,cid) then
        dprint("Skip player waiter", gid, cid)
        return
    end
    local key = keyFor(gid,cid)
    waitingIndex[key] = true
    local char = getChar(gid,cid)
    if not char then refreshCharIndex(); char = getChar(gid,cid) end
    local dish = readDesiredDishFromChar(char)
    if dish then
        desiredFoodByCustomer[key] = tostring(dish)
        waitingByFood[dish] = waitingByFood[dish] or {}
        waitingByFood[dish][#waitingByFood[dish]+1] = key
        dprint("Want", gid, cid, "dish", dish)
    else
        desiredFoodByCustomer[key] = nil
        dprint("Want", gid, cid, "dish (unknown)")
    end
end
local function clearWaiting(gid, cid)
    local key = keyFor(gid,cid)
    waitingIndex[key] = nil
    local dish = desiredFoodByCustomer[key]
    if dish and waitingByFood[dish] then
        for i=#waitingByFood[dish],1,-1 do
            if waitingByFood[dish][i] == key then table.remove(waitingByFood[dish], i) end
        end
        if #waitingByFood[dish]==0 then waitingByFood[dish]=nil end
    end
    desiredFoodByCustomer[key] = nil
end

if Customers.CustomerStateChanged then
    Customers.CustomerStateChanged:Connect(function(ty, gid, cid, _, state)
        if ty ~= Tycoon then return end
        gid, cid = toStringId(gid), toStringId(cid)
        local k = keyFor(gid,cid)
        if state == CustomerState.WaitingForDish then
            if not waitingIndex[k] then pushWaitingForDish(gid,cid) end
        else
            if waitingIndex[k] then clearWaiting(gid,cid) end
        end
    end)
end

-- periodic prune: remove vanished or non-waiting entries (lightweight)
local lastPrune = 0
local function pruneWaitingIfNeeded()
    if now() - (lastPrune or 0) < 3.0 then return end
    lastPrune = now()
    for k,_ in pairs(waitingIndex) do
        local gid, cid = k:match("^(.-)|(.-)$")
        if gid and cid then
            if isPlayerCustomer(gid,cid) then
                clearWaiting(gid,cid)
            else
                local ok, st = pcall(Customers.GetCustomerState, Customers, Tycoon, gid, cid)
                if (not ok) or (st ~= CustomerState.WaitingForDish) then
                    clearWaiting(gid,cid)
                end
            end
        end
    end
end

-- ===== Plates (event-driven queue) =====
local function isFoodPlate(inst)
    if not (typeof(inst)=="Instance" and inst:IsA("Model")) then return false end
    local n = tostring(inst.Name)
    if n:lower() == "trash" then return false end
    return n:match("^%d+$") ~= nil -- numeric ids only; player plates usually not pure digits
end

local dishAttrNames = { "DishId","Dish","FoodId","Food","RecipeId","MealId","ItemId" }
local plateDish = setmetatable({}, { __mode="k" }) -- cache per plate model (weak keys)

local function readDishIdFromPlate(plate)
    local cached = plateDish[plate]
    if cached ~= nil then return cached end
    local id = tostring(plate.Name or "")
    if id == "" or id:lower()=="trash" then id = nil end
    if not id then
        for _, n in ipairs(dishAttrNames) do local v = plate:GetAttribute(n); if v ~= nil then id = tostring(v) break end end
    end
    plateDish[plate] = id
    return id
end

-- shallow target ids from plate (no deep scan)
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
local function qpush(q,v) q[#q+1] = v end
local function qpop(q) if #q==0 then return nil end local v=q[1]; table.remove(q,1); return v end

local function recordPlate(plate)
    if not isFoodPlate(plate) or seenPlates[plate] then return end
    seenPlates[plate] = true
    qpush(PlateQ, plate)
    readDishIdFromPlate(plate) -- prime cache
    dprint("Plate +", plate.Name, "dish", plateDish[plate] or "?")
end
local function scanFoodFolderOnce()
    for _, ch in ipairs(FoodFolder:GetChildren()) do recordPlate(ch) end
end
FoodFolder.ChildAdded:Connect(recordPlate)
FoodFolder.ChildRemoved:Connect(function(ch) seenPlates[ch] = nil; plateDish[ch] = nil end)

-- ===== Serve (single-hold with immediate delivery) =====
local carryingPlate, carrySince = nil, 0

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

local function chooseTargetsForDish(dishId)
    local targets = {}
    local list = dishId and waitingByFood[dishId] or nil
    if list and #list > 0 then
        for _, k in ipairs(list) do
            if waitingIndex[k] then
                local gid, cid = k:match("^(.-)|(.-)$")
                if gid and cid and (not isPlayerCustomer(gid,cid)) then
                    targets[#targets+1] = {gid=gid, cid=cid, key=k}
                end
            end
        end
    end
    if #targets == 0 then
        for k,_ in pairs(waitingIndex) do
            local gid, cid = k:match("^(.-)|(.-)$")
            if gid and cid and (not isPlayerCustomer(gid,cid)) then
                targets[#targets+1] = {gid=gid, cid=cid, key=k}
            end
        end
    end
    return targets
end

local function pickBestPlate()
    -- prefer a plate whose dish is wanted by NPCs
    for i=1,#PlateQ do
        local p = PlateQ[i]
        if p and p.Parent and p:IsDescendantOf(FoodFolder) then
            local did = readDishIdFromPlate(p)
            local t = chooseTargetsForDish(did)
            if #t > 0 then
                table.remove(PlateQ, i)
                return p, did, t
            end
            -- fallback to direct gid/cid on plate (skip players)
            local gid, cid = plateTargetIds(p)
            if gid and cid and (not isPlayerCustomer(gid,cid)) then
                table.remove(PlateQ, i)
                return p, did, { {gid=gid, cid=cid, key=keyFor(gid,cid)} }
            end
        end
    end
    return nil, nil, nil
end

local function serveTick()
    if not flags.autoServe then return end
    pruneWaitingIfNeeded()

    -- Finish delivery if already holding
    if carryingPlate then
        local dishId = readDishIdFromPlate(carryingPlate)
        local targets = chooseTargetsForDish(dishId)
        if #targets == 0 then
            -- try plate's own shallow mapping
            local gid, cid = plateTargetIds(carryingPlate)
            if gid and cid and (not isPlayerCustomer(gid,cid)) then
                targets = { {gid=gid,cid=cid,key=keyFor(gid,cid)} }
            end
        end
        local served = false
        for _, t in ipairs(targets) do
            served = serveConfirm(t.gid, t.cid, carryingPlate)
            if served then clearWaiting(t.gid, t.cid) break end
        end
        if not served then dprint("Serve retry failed; dropping carry") end
        carryingPlate, carrySince = nil, 0
        return
    end

    -- Acquire best plate (only if it has an NPC target)
    if #PlateQ == 0 then scanFoodFolderOnce() end
    local plate, dishId, targets = pickBestPlate()
    if not plate then return end
    if not (plate.Parent and plate:IsDescendantOf(FoodFolder)) then return end
    if not targets or #targets == 0 then
        -- nobody valid -> park it back
        qpush(PlateQ, plate)
        return
    end

    local okGrab = pcall(function() GrabFoodRF:InvokeServer(plate) end)
    if not okGrab then
        dprint("Grab failed; requeue")
        if plate.Parent and plate:IsDescendantOf(FoodFolder) then qpush(PlateQ, plate) end
        return
    end
    carryingPlate, carrySince = plate, now()

    -- immediate attempt
    local served = false
    for _, tgt in ipairs(targets) do
        served = serveConfirm(tgt.gid, tgt.cid, plate)
        if served then clearWaiting(tgt.gid, tgt.cid); break end
    end
    if served then
        dprint("Served ✓ (immediate)")
        carryingPlate, carrySince = nil, 0
    else
        dprint("Immediate serve failed; will retry")
    end
end

-- ===== Cooking (burst; minimal checks) =====
local cookActive, cookLast = false, 0
if Cook.Started  then Cook.Started:Connect (function(ty) if ty==Tycoon then cookActive=true;  cookLast=now(); dprint("Cook started")  end end) end
if Cook.Finished then Cook.Finished:Connect(function(ty) if ty==Tycoon then cookActive=false; cookLast=now(); dprint("Cook finished") end end) end

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
    if prompt and typeof(fpp)=="function" then pcall(fpp,prompt); dprint("Pressed counter (prompt)"); return true end
    local base = counter:FindFirstChildOfClass("BasePart") or counter:FindFirstChild("Base")
    if base and base:IsA("BasePart") then
        Interacted:FireServer(Tycoon, {
            WorldPosition=base.Position, HoldDuration=0, Id="0",
            TemporaryPart=base, Model=counter, ActionText="Cook",
            Prompt=prompt, Part=base, InteractionType="OrderCounter"
        })
        dprint("Pressed counter (remote)")
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

-- ===== Housekeeping (only active tables; sliced; hands free) =====
local dishCD, billCD = {}, {}
local function tableLooksIdle(tbl)
    if not tbl or not tbl.Parent then return true end
    local bill = tbl:FindFirstChild("Bill")
    if bill and bill:GetAttribute("Taken") ~= true then return false end
    if tbl:FindFirstChild("Trash") then return false end
    if tbl:GetAttribute("InUse") == true then return false end
    return true
end

local function houseTick()
    if not flags.housekeeping then return end
    if carryingPlate and (now() - (carrySince or 0) < tuners.holdGrace) then return end
    ensureTables()
    if #activeList == 0 then return end

    local slice = #activeList
    for _=1, slice do
        if activeIdx > #activeList then activeIdx = 1 end
        local tbl = activeList[activeIdx]; activeIdx = activeIdx + 1
        if tbl and tbl.Parent then
            local t = now()
            if tbl:FindFirstChild("Trash") and (t - (dishCD[tbl] or 0) >= 0.45) then
                dishCD[tbl] = t
                TaskCompleted:FireServer({ Name=TaskEnum.CollectDishes, FurnitureModel=tbl, Tycoon=Tycoon })
                dprint("Collect dishes", tbl.Name)
            end
            local bill = tbl:FindFirstChild("Bill")
            if bill and bill:GetAttribute("Taken") ~= true and (t - (billCD[tbl] or 0) >= 0.9) then
                billCD[tbl] = t
                TaskCompleted:FireServer({ Name=TaskEnum.CollectBill, FurnitureModel=tbl, Tycoon=Tycoon })
                dprint("Collect bill", tbl.Name)
            end
            if tableLooksIdle(tbl) then removeActive(tbl) end
        else
            removeActive(tbl)
        end
    end
end

-- ===== Loops =====
task.spawn(function() dprint("Seat/Order loop start"); while true do pcall(seatAndOrderTick); task.wait(tuners.seatPeriod) end end)
task.spawn(function() dprint("Serve loop start");      while true do pcall(serveTick);       task.wait(tuners.servePeriod) end end)
task.spawn(function() dprint("Cook loop start");       while true do pcall(cookTick);        task.wait(tuners.cookPeriod) end end)
task.spawn(function() dprint("House loop start");      while true do pcall(houseTick);       task.wait(tuners.housePeriod) end end)
task.spawn(function() while task.wait(180) do if workspace:FindFirstChild("Temp") then workspace.Temp:ClearAllChildren() end end end)

pcall(seatAndOrderTick)
scanFoodFolderOnce()

-- ===== Anti-AFK =====
if flags.antiAFK then
    local vu = game:GetService("VirtualUser")
    LocalPlayer.Idled:Connect(function() vu:CaptureController(); vu:ClickButton2(Vector2.new()) end)
end

-- ===== Minimal UI =====
local function loadUILib()
    local URL = "https://raw.githubusercontent.com/ProtonDev-sys/the-return/refs/heads/main/ui%20library/ui%20library.lua"
    local ok, lib = pcall(function() return loadstring(game:HttpGet(URL))() end)
    if ok then return lib end
    return nil
end
local function mkWindow(lib, spec)
    if type(lib)=="function" then local ok,w=pcall(lib,spec); if ok and type(w)=="table" then return w end end
    for _,name in ipairs({"Window","CreateWindow","New","new"}) do
        local f=(type(lib)=="table") and lib[name]
        if type(f)=="function" then local ok,w=pcall(f,lib,spec); if not ok then ok,w=pcall(f,spec) end; if ok and type(w)=="table" then return w end end
    end
    return nil
end
local function addToggle(where,label,default,cb)
    if where and type(where.Toggle)=="function" then local t=where:Toggle(label,cb); if t and t.Set then t:Set(default) end; return end
    if where and type(where.AddToggle)=="function" then where:AddToggle(label,default,cb); return end
    cb(default)
end
local function addSlider(where,label,min,max,default,cb)
    if where and type(where.Slider)=="function" then where:Slider(label,min,max,default,cb); return end
    if where and type(where.AddSlider)=="function" then where:AddSlider(label,min,max,default,cb); return end
end

task.defer(function()
    local UI = loadUILib()
    if not UI then return end
    local win = mkWindow(UI, { Title="RT3 Helper (Perf+NoPlayerOrders)", CFG="RT3_PERF_NOPLAYERS", Key=Enum.KeyCode.RightShift })
    if not win then return end
    local tab = (win.Tab and win:Tab("Automation")) or win
    local sec = (tab.Section and tab:Section("Main")) or tab

    addToggle(sec,"Auto Seat + Order",true,function(v) flags.autoSeatOrder=v end)
    addSlider(sec,"Seat tick (s)",0.10,1.00,tuners.seatPeriod,function(v) tuners.seatPeriod=tonumber(string.format("%.2f",v)) end)

    addToggle(sec,"Auto Serve",true,function(v) flags.autoServe=v end)
    addSlider(sec,"Serve tick (s)",0.03,0.20,tuners.servePeriod,function(v) tuners.servePeriod=tonumber(string.format("%.2f",v)) end)
    addSlider(sec,"Serve confirm delay (s)",0.03,0.15,tuners.serveDelay,function(v) tuners.serveDelay=tonumber(string.format("%.2f",v)) end)

    addToggle(sec,"Auto Cook (burst)",true,function(v) flags.autoCook=v end)
    addSlider(sec,"Cook tick (s)",0.10,1.00,tuners.cookPeriod,function(v) tuners.cookPeriod=tonumber(string.format("%.2f",v)) end)

    addToggle(sec,"Bills + Dishes (active only)",true,function(v) flags.housekeeping=v end)
    addSlider(sec,"House tick (s)",0.10,1.00,tuners.housePeriod,function(v) tuners.housePeriod=tonumber(string.format("%.2f",v)) end)
end)

print("[RTHelper] loaded (perf tuned + player-order ignore + prune).")
