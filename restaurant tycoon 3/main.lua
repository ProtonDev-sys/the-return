-- RTHelper (single-file, no return)
-- Auto-seat & take orders, auto-start cook, full cook-step spam, robust plate pickup,
-- always-serve (queues + live scan), bills & dishes, Anti-AFK, single-tab UI.

--!strict
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local DEBUG = false

-- ───────────────── helpers
local function path(parent: Instance, ...): Instance
	local cur = parent
	for _, name in ipairs({...}) do cur = cur:WaitForChild(name) end
	return cur
end
local function safeRequire(inst: Instance)
	local ok, mod = pcall(require, inst)
	return ok and mod or nil
end
local function toStringId(v: string | number): string
	return (typeof(v) == "number") and tostring(v) or (v :: string)
end
local function parseTableIndex(name: string): number
	return tonumber(string.match(name, "^T(%d+)$") or string.match(name, "^T(%d+)")) or math.huge
end
local function now() return os.clock() end

-- ───────────────── game modules
local FurnitureUtility       = safeRequire(path(ReplicatedStorage, "Source", "Utility", "FurnitureUtility"))
local TableConnectionUtility = safeRequire(path(ReplicatedStorage, "Source", "Utility", "Furniture", "TableConnectionUtility"))
local Customers              = safeRequire(path(LocalPlayer:WaitForChild("PlayerScripts"), "Source", "Systems", "Restaurant", "Customers"))
local CustomerState          = safeRequire(path(ReplicatedStorage, "Source", "Enums", "Restaurant", "Customer", "CustomerState"))
local Cook                   = safeRequire(path(LocalPlayer.PlayerScripts, "Source", "Systems", "Cook"))
local CookReplication        = safeRequire(path(ReplicatedStorage, "Source", "Enums", "Cook", "CookReplication"))
local TaskEnum               = safeRequire(path(ReplicatedStorage, "Source", "Enums", "Restaurant", "Task"))
assert(FurnitureUtility and TableConnectionUtility and Customers and CustomerState and Cook and CookReplication and TaskEnum, "require() failed for core modules")

-- ───────────────── tycoon
local function waitTycoonOV(timeout: number?): Instance?
	local deadline = now() + (timeout or 5)
	local ov = LocalPlayer:FindFirstChild("Tycoon") or LocalPlayer:WaitForChild("Tycoon", timeout or 5)
	if not (ov and ov:IsA("ObjectValue")) then return nil end
	if ov.Value then return ov.Value end
	while now() < deadline and ov.Value == nil do task.wait(0.1) end
	return ov.Value
end
local function resolveTycoon(): Instance
	local t = waitTycoonOV(5); if t then return t end
	local tycoons = Workspace:FindFirstChild("Tycoons")
	if tycoons then
		for _, m in ipairs(tycoons:GetChildren()) do
			local p = m:FindFirstChild("Player")
			if p and p:IsA("ObjectValue") and p.Value == LocalPlayer then return m end
		end
		return tycoons:FindFirstChild("Tycoon") or path(Workspace, "Tycoons", "Tycoon")
	end
	return path(Workspace, "Tycoons", "Tycoon")
end

-- ───────────────── types
type TableSendArgs = { GroupId: string, Tycoon: Instance, Name: "SendToTable", FurnitureModel: Instance }
type ServeArgs     = { Name: "Serve", GroupId: string, Tycoon: Instance, FoodModel: Instance, CustomerId: string }
type TakeOrderArgs = { Name: "TakeOrder", GroupId: string, Tycoon: Instance, CustomerId: string }
type InteractArgs  = {
	WorldPosition: Vector3, HoldDuration: number, Id: string, TemporaryPart: BasePart, Model: Instance,
	ActionText: string, Prompt: ProximityPrompt, Part: BasePart, InteractionType: string
}

-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║                               RTHelper                               ║
-- ╚══════════════════════════════════════════════════════════════════════╝
local RTHelper = {}
RTHelper.__index = RTHelper

function RTHelper.new(tycoon: Instance?)
	local self = setmetatable({}, RTHelper)

	-- Remotes
	local Events            = path(ReplicatedStorage, "Events")
	local Restaurant        = path(Events, "Restaurant")
	self.TaskCompleted      = path(Restaurant, "TaskCompleted") :: RemoteEvent
	self.GrabFoodRF         = path(Restaurant, "GrabFood") :: RemoteFunction
	self.Interacted         = path(Restaurant, "Interactions", "Interacted") :: RemoteEvent

	-- Cook remotes
	local CookEvents        = path(Events, "Cook")
	self.CookInputRequested = path(CookEvents, "CookInputRequested") :: RemoteEvent
	self.CookUpdated        = path(CookEvents, "CookUpdated") :: RemoteEvent

	-- Tycoon + roots
	self.Tycoon     = tycoon or resolveTycoon()
	self.Items      = path(self.Tycoon, "Items")
	self.Surface    = self.Items:FindFirstChild("Surface") or self.Items:FindFirstChild("Surfaces") or self.Items
	self.Objects    = path(self.Tycoon, "Objects")
	self.FoodFolder = self.Objects:FindFirstChild("Food") or path(self.Objects, "Food")

	-- Table cache
	self._tablesDirty = true
	self._tableList   = {} :: {Model}
	self._tableMeta   = {} :: {
		[Model]: { idx: number, seats: number, chairList: {Instance}, inUse: boolean, plateAdornee: Instance? }
	}

	-- Runtime state
	self._cookActive     = false
	self._cookBeatAt     = 0.0
	self._serveBusy      = false
	self._foodInHand     = nil :: Instance?

	-- queues + de-dup
	self._serveQueue     = {} :: { {gid: string, cid: string} }  -- “WaitingForDish”
	self._orderQueue     = {} :: { {gid: string, cid: string} }  -- fallback targets after TakeOrder
	self._serveSet       = {} :: {[string]: boolean}
	self._orderSet       = {} :: {[string]: boolean}

	-- cooldowns
	self._dishCooldown   = {} :: {[Model]: number}
	self._billCooldown   = {} :: {[Model]: number}
	self._seatCooldown   = {} :: {[string]: number}
	self._orderCooldown  = {} :: {[string]: number}

	-- control
	self.flags = { autoSeatOrder = true, autoCook = true, housekeeping = true }
	self.tuners = {
		seatPeriod    = 0.35,
		cookPeriod    = 0.6,
		housePeriod   = 0.6,
		housePerTick  = 10,
		serveRetries  = 10,
		serveDelay    = 0.18,
		cookStallSec  = 6.0,
		plateWaitSec  = 2.5
	}

	-- stats
	self.stats = { ordersTaken=0, groupsSeated=0, served=0, dishes=0, bills=0, cookStarts=0, stallsFixed=0 }

	self:_bindSurfaceWatcher()
	self:_bindCustomerEvents()
	self:_bindCookEvents()

	return self
end

-- ───────── surface watch
function RTHelper:_bindSurfaceWatcher()
	local function dirty() self._tablesDirty = true end
	self.Surface.ChildAdded:Connect(function(ch)
		if ch:IsA("Model") then
			ch:GetPropertyChangedSignal("Name"):Connect(dirty)
			if ch.GetAttributeChangedSignal then ch:GetAttributeChangedSignal("InUse"):Connect(dirty) end
		end
		dirty()
	end)
	self.Surface.ChildRemoved:Connect(dirty)
	for _, m in ipairs(self.Surface:GetChildren()) do
		if m:IsA("Model") then
			m:GetPropertyChangedSignal("Name"):Connect(dirty)
			if m.GetAttributeChangedSignal then m:GetAttributeChangedSignal("InUse"):Connect(dirty) end
		end
	end
end

-- ───────── customers
local function keyFor(gid: string, cid: string) return gid .. "|" .. cid end

function RTHelper:_queueServe(gid: string, cid: string)
	local k = keyFor(gid, cid)
	if not self._serveSet[k] then
		table.insert(self._serveQueue, {gid = gid, cid = cid})
		self._serveSet[k] = true
	end
end
function RTHelper:_queueOrder(gid: string, cid: string)
	local k = keyFor(gid, cid)
	if not self._orderSet[k] then
		table.insert(self._orderQueue, {gid = gid, cid = cid})
		self._orderSet[k] = true
	end
end

function RTHelper:GetCustomerState(gid: string | number, cid: string | number)
	local ok, st = pcall(Customers.GetCustomerState, Customers, self.Tycoon, toStringId(gid), toStringId(cid))
	if ok then return st end
	return nil
end
function RTHelper:GetGroupState(gid: string | number)
	local ok, st = pcall(Customers.GetGroupState, Customers, self.Tycoon, toStringId(gid))
	if ok then return st end
	return nil
end

function RTHelper:_bindCustomerEvents()
	if Customers.CustomerStateChanged then
		Customers.CustomerStateChanged:Connect(function(...)
			local a = { ... }
			local tycoon = a[1]; if tycoon ~= self.Tycoon then return end
			local gid    = toStringId(a[2])
			local cid    = toStringId(a[3])
			local state  = a[5] or a[#a]
			if state == CustomerState.WaitingForDish then
				self:_queueServe(gid, cid)
			end
		end)
	end
end

-- ───────── cooking
function RTHelper:_beat() self._cookBeatAt = now() end
function RTHelper:_cookInteract(model: Instance, itemType: any)
	self:_beat(); self.CookInputRequested:FireServer(CookReplication.Interact, model, itemType)
end
function RTHelper:_cookComplete(model: Instance?, itemType: any, instrKey: any?)
	self:_beat(); self.CookInputRequested:FireServer(CookReplication.CompleteTask, model, itemType)
	if instrKey ~= nil then
		self:_beat(); self.CookInputRequested:FireServer(CookReplication.CompleteTask, itemType, instrKey, false)
	end
end
function RTHelper:_bindCookEvents()
	if Cook.Started then
		Cook.Started:Connect(function(ty)
			if ty == self.Tycoon then
				self._cookActive = true
				self:_beat()
				self.stats.cookStarts += 1
			end
		end)
	end
	if Cook.Finished then
		Cook.Finished:Connect(function(ty)
			if ty == self.Tycoon then
				self._cookActive = false
				self:_beat()
				task.defer(function() self:ServeIfPossible() end)
			end
		end)
	end
	self.CookUpdated.OnClientEvent:Connect(function(op, ...)
		self:_beat()
		local a = { ... }
		if op == CookReplication.DirectToEquipment then
			local ty, model, itemType, key = a[1], a[2], a[3], a[4]
			if ty ~= self.Tycoon then return end
			self._cookActive = true
			self:_cookInteract(model, itemType)
			self:_cookComplete(model, itemType, key)
		elseif op == CookReplication.UpdateInteraction then
			local ty, model, itemType, key = a[1], a[2], a[3], a[4]
			if ty ~= self.Tycoon then return end
			self:_cookComplete(model, itemType, key)
		elseif op == CookReplication.Start then
			self._cookActive = true
		elseif op == CookReplication.Finish then
			self._cookActive = false
			task.defer(function() self:ServeIfPossible() end)
		end
	end)
	if Cook.StateUpdated then
		Cook.StateUpdated:Connect(function(state)
			if not state then return end
			self:_beat()
			self:_cookComplete(nil, nil, state.InstructionKey)
		end)
	end
end

-- ───────── order counter (robust)
function RTHelper:_findOrderCounter(): Instance?
	-- 1) game utility
	local list = {}
	local ok, res = pcall(FurnitureUtility.FindWhere, FurnitureUtility, self.Tycoon, self.Surface, function(inst)
		local ok2, isOC = pcall(FurnitureUtility.Is, FurnitureUtility, inst, FurnitureUtility.ItemType.OrderCounter)
		return ok2 and isOC
	end)
	if ok and type(res) == "table" and #res > 0 then return res[1] end

	-- 2) heuristic: any descendant named/typed like order counter
	for _, d in ipairs(self.Surface:GetDescendants()) do
		if d:IsA("Model") then
			if d.Name:lower():find("order") or d.Name:lower():find("counter") then
				return d
			end
			for _, pp in ipairs(d:GetDescendants()) do
				if pp:IsA("ProximityPrompt") then
					local t = ((pp.ObjectText or "") .. " " .. (pp.ActionText or "")):lower()
					if t:find("order") or t:find("cook") then return d end
				end
			end
		end
	end
	return nil
end

function RTHelper:PressOrderCounter(): boolean
	local counter = self:_findOrderCounter()
	if not counter then return false end

	-- prefer proximity prompt
	local prompt: ProximityPrompt?
	for _, d in ipairs(counter:GetDescendants()) do
		if d:IsA("ProximityPrompt") then prompt = d break end
	end
	local fpp = getfenv().fireproximityprompt
	if prompt and typeof(fpp) == "function" then
		pcall(fpp, prompt)
		return true
	end

	-- remote fallback
	local base = counter:FindFirstChildOfClass("BasePart") or counter:FindFirstChild("Base")
	if base and base:IsA("BasePart") then
		local details = {
			WorldPosition = base.Position, HoldDuration = 0, Id = "0",
			TemporaryPart = base, Model = counter, ActionText = "Cook",
			Prompt = prompt, Part = base, InteractionType = "OrderCounter",
		}
		self.Interacted:FireServer(self.Tycoon, details)
		return true
	end
	return false
end

-- ───────── seating + orders
function RTHelper:_iterSpeechUIs()
	local out = {}
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then return out end
	for _, gui in ipairs(pg:GetChildren()) do
		if gui:IsA("BillboardGui") and gui.Name == "CustomerSpeechUI" and gui.Adornee then
			local head = gui.Adornee
			local char = head.Parent
			local group = char and char.Parent
			if char and group then table.insert(out, {char=char, group=group}) end
		end
	end
	return out
end
function RTHelper:_extractIds(group: Instance, char: Instance): (string, string)
	local gid = group:GetAttribute("GroupId") or group:GetAttribute("Id") or group.Name
	local cid = char:GetAttribute("CustomerId") or char:GetAttribute("Id") or char.Name
	return toStringId(gid), toStringId(cid)
end

function RTHelper:HandleSpeechPrompts()
	self:_ensureTables()
	local prompts = self:_iterSpeechUIs()

	local groups: {[string]: {group: Instance, unseated: number, anyOrdering: boolean, gstate: any}} = {}
	local orders = {}

	for _, p in ipairs(prompts) do
		local gid, cid = self:_extractIds(p.group, p.char)
		local st = self:GetCustomerState(gid, cid)
		if st == CustomerState.Ordering then table.insert(orders, {gid=gid, cid=cid}) end

		local g = groups[gid]
		if not g then g = { group=p.group, unseated=0, anyOrdering=false, gstate=self:GetGroupState(gid) }; groups[gid]=g end
		if st == CustomerState.Ordering then g.anyOrdering = true end

		-- seated check via seat occupants
		local hum = p.char:FindFirstChildOfClass("Humanoid")
		local seated = false
		if hum then
			for _, tbl in ipairs(self._tableList) do
				local md = self._tableMeta[tbl]
				for _, seat in ipairs(md.chairList) do
					if (seat:IsA("Seat") or seat:IsA("VehicleSeat")) and seat.Occupant == hum then seated = true; break end
				end
				if seated then break end
			end
		end
		if not seated then g.unseated += 1 end
	end

	-- take orders (debounced)
	local tnow = now()
	for _, o in ipairs(orders) do
		local k = keyFor(o.gid, o.cid)
		local last = self._orderCooldown[k] or 0
		if (tnow - last) >= 0.9 then
			local args: {TakeOrderArgs} = { { Name = TaskEnum.TakeOrder, GroupId = o.gid, Tycoon = self.Tycoon, CustomerId = o.cid } }
			self.TaskCompleted:FireServer(unpack(args))
			self._orderCooldown[k] = tnow
			self.stats.ordersTaken += 1
			self:_queueOrder(o.gid, o.cid)
		end
	end

	-- seat only truly unseated groups not already going/ordering
	for gid, g in pairs(groups) do
		if g.unseated > 0 and not g.anyOrdering then
			local gs = g.gstate
			local goingOrSeated = (gs == CustomerState.GoingToTable) or (gs == CustomerState.Seated) or (gs == CustomerState.WaitingForDish)
			if not goingOrSeated then
				local last = self._seatCooldown[gid] or 0
				if (tnow - last) >= 1.5 then
					local tbl = self:GetTableForGroup(g.group)
					if tbl then
						local args: {TableSendArgs} = { { GroupId = gid, Tycoon = self.Tycoon, Name = TaskEnum.SendToTable, FurnitureModel = tbl } }
						self.TaskCompleted:FireServer(unpack(args))
						self.stats.groupsSeated += 1
					end
					self._seatCooldown[gid] = tnow
				end
			end
		end
	end
end

-- ───────── table discovery
local function _findTables(self): {Model}
	local found = {}
	local ok, list = pcall(FurnitureUtility.FindWhere, FurnitureUtility, self.Tycoon, self.Surface, function(inst)
		local ok2, isTable = pcall(FurnitureUtility.IsTable, FurnitureUtility, inst)
		return ok2 and isTable
	end)
	if ok and type(list) == "table" then
		for _, v in ipairs(list) do if typeof(v) == "Instance" and v:IsA("Model") then table.insert(found, v) end end
	end
	if #found == 0 then
		for _, d in ipairs(self.Surface:GetDescendants()) do
			if d:IsA("Model") then
				local base = d:FindFirstChild("Base")
				if (d.Name:match("^T%d+") or (base and base:FindFirstChild("PlateHeight"))) then
					table.insert(found, d)
				end
			end
		end
	end
	return found
end
function RTHelper:_rebuildTableCache()
	local list = {} :: {Model}
	local meta = {} :: {[Model]: { idx: number, seats: number, chairList: {Instance}, inUse: boolean, plateAdornee: Instance? }}

	for _, tbl in ipairs(_findTables(self)) do
		local base   = tbl:FindFirstChild("Base")
		local plate  = base and base:FindFirstChild("PlateHeight")
		local chairs = {}
		local ok, linked = pcall(TableConnectionUtility.FindChairs, TableConnectionUtility, self.Tycoon, tbl)
		if ok and type(linked) == "table" then chairs = linked end

		table.insert(list, tbl)
		meta[tbl] = {
			idx          = parseTableIndex(tbl.Name),
			seats        = #chairs,
			chairList    = chairs,
			inUse        = tbl:GetAttribute("InUse") == true,
			plateAdornee = plate,
		}
	end

	table.sort(list, function(a, b)
		local ia, ib = meta[a].idx, meta[b].idx
		if ia ~= ib then return ia < ib end
		return a.Name < b.Name
	end)

	self._tableList, self._tableMeta, self._tablesDirty = list, meta, false
end
function RTHelper:_ensureTables()
	if self._tablesDirty or #self._tableList == 0 then
		self:_rebuildTableCache()
	end
end
function RTHelper:GetAllTables(): {Model}
	self:_ensureTables(); return self._tableList
end
function RTHelper:GetAvailableTables(): {Model}
	self:_ensureTables()
	local out = {}
	for _, m in ipairs(self._tableList) do
		local md = self._tableMeta[m]
		if md.plateAdornee and (not md.inUse) and md.seats > 0 then table.insert(out, m) end
	end
	return out
end
function RTHelper:GetTableForGroup(group: Instance | number): Model?
	self:_ensureTables()
	local size: number
	if typeof(group) == "number" then
		size = group :: number
	else
		local n = 0
		for _, c in ipairs((group :: Instance):GetChildren()) do
			if c:IsA("Model") or c:IsA("Folder") then n += 1 end
		end
		size = math.max(n, 1)
	end
	local best: Model? = nil
	local bestSeats = math.huge
	for _, m in ipairs(self._tableList) do
		local md = self._tableMeta[m]
		if md.plateAdornee and (not md.inUse) and md.seats > 0 then
			if md.seats >= size and md.seats < bestSeats then
				best, bestSeats = m, md.seats
				if bestSeats == size then break end
			end
		end
	end
	return best
end

-- ───────── serving
function RTHelper:_getNewestFoodOnCounter(): Instance?
	local kids = self.FoodFolder:GetChildren()
	if #kids == 0 then return nil end
	table.sort(kids, function(a,b) return a.Name > b.Name end)
	return kids[1]
end
function RTHelper:_isServeConfirmed(gid: string, cid: string, food: Instance?): boolean
	local st = self:GetCustomerState(gid, cid)
	if st and st ~= CustomerState.WaitingForDish then return true end
	if not food or food.Parent == nil then return true end
	return false
end
function RTHelper:_scanWaitingFallback(): (string?, string?)
	-- actively discover anyone WaitingForDish (if we missed events)
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then return nil, nil end
	for _, gui in ipairs(pg:GetChildren()) do
		if gui:IsA("BillboardGui") and gui.Name == "CustomerSpeechUI" and gui.Adornee then
			local char = gui.Adornee.Parent
			local group = char and char.Parent
			if char and group then
				local gid, cid = self:_extractIds(group, char)
				local st = self:GetCustomerState(gid, cid)
				if st == CustomerState.WaitingForDish then return gid, cid end
			end
		end
	end
	return nil, nil
end
function RTHelper:_pickTarget(): (string?, string?)
	if #self._serveQueue > 0 then
		local rec = table.remove(self._serveQueue, 1)
		self._serveSet[keyFor(rec.gid, rec.cid)] = nil
		return rec.gid, rec.cid
	end
	-- upgrade any ordered customer who is now waiting
	for i = 1, #self._orderQueue do
		local rec = self._orderQueue[i]
		if self:GetCustomerState(rec.gid, rec.cid) == CustomerState.WaitingForDish then
			table.remove(self._orderQueue, i)
			self._orderSet[keyFor(rec.gid, rec.cid)] = nil
			return rec.gid, rec.cid
		end
	end
	-- live scan fallback
	return self:_scanWaitingFallback()
end

function RTHelper:_grabAndServe(gid: string, cid: string)
	if self._serveBusy then return end
	self._serveBusy = true

	-- wait for plate to appear (after finish)
	local deadline = now() + self.tuners.plateWaitSec
	local food = self:_getNewestFoodOnCounter()
	while not food and now() < deadline do
		task.wait(0.05)
		food = self:_getNewestFoodOnCounter()
	end
	if not food then
		self._serveBusy = false
		return
	end

	local okGrab, res = pcall(function() return self.GrabFoodRF:InvokeServer(food) end)
	if not okGrab then
		if DEBUG then warn("[RTHelper] GrabFood failed:", res) end
		self._serveBusy = false
		return
	end
	self._foodInHand = food

	-- retries
	local served = false
	for _ = 1, self.tuners.serveRetries do
		local args: {ServeArgs} = { { Name = TaskEnum.Serve, GroupId = gid, Tycoon = self.Tycoon, FoodModel = food, CustomerId = cid } }
		self.TaskCompleted:FireServer(unpack(args))
		task.wait(self.tuners.serveDelay)
		if self:_isServeConfirmed(gid, cid, food) then served = true; break end
	end

	if served then
		self.stats.served += 1
		self._foodInHand = nil
	else
		-- push back to queue; we’ll try again shortly
		self:_queueServe(gid, cid)
	end
	self._serveBusy = false
end

function RTHelper:ServeIfPossible()
	if self._serveBusy then return end
	local gid, cid = self:_pickTarget()
	if not gid then return end
	self:_grabAndServe(gid, cid)
end

-- ───────── bills + dishes (TaskCompleted path)
function RTHelper:_canCollectDishes(tbl: Model): boolean
	return tbl:FindFirstChild("Trash") ~= nil
end
function RTHelper:_canCollectBill(tbl: Model): boolean
	local bill = tbl:FindFirstChild("Bill")
	return bill ~= nil and (bill:GetAttribute("Taken") ~= true)
end
function RTHelper:_collectDishes(tbl: Model)
	self.TaskCompleted:FireServer({ Name = TaskEnum.CollectDishes; FurnitureModel = tbl; Tycoon = self.Tycoon; })
	self.stats.dishes += 1
end
function RTHelper:_collectBill(tbl: Model)
	self.TaskCompleted:FireServer({ Name = TaskEnum.CollectBill; FurnitureModel = tbl; Tycoon = self.Tycoon; })
	self.stats.bills += 1
end
function RTHelper:SweepBillsAndDishesOnce(maxActions: number?)
	self:_ensureTables()
	local tnow = now()
	local left = maxActions or 8
	for _, tbl in ipairs(self._tableList) do
		if left <= 0 then break end
		if self:_canCollectDishes(tbl) then
			local last = self._dishCooldown[tbl] or 0
			if (tnow - last) >= 0.55 then
				self._dishCooldown[tbl] = tnow
				self:_collectDishes(tbl)
				left -= 1; if left <= 0 then break end
			end
		end
		if self:_canCollectBill(tbl) then
			local last = self._billCooldown[tbl] or 0
			if (tnow - last) >= 1.05 then
				self._billCooldown[tbl] = tnow
				self:_collectBill(tbl)
				left -= 1; if left <= 0 then break end
			end
		end
	end
end

-- ───────── table cache
function RTHelper:_rebuildTableCache()
	local list = {} :: {Model}
	local meta = {} :: {[Model]: { idx: number, seats: number, chairList: {Instance}, inUse: boolean, plateAdornee: Instance? }}

	for _, tbl in ipairs((function(selfRef) -- local scope iterator
		local found = {}
		local ok, res = pcall(FurnitureUtility.FindWhere, FurnitureUtility, selfRef.Tycoon, selfRef.Surface, function(inst)
			local ok2, isTable = pcall(FurnitureUtility.IsTable, FurnitureUtility, inst)
			return ok2 and isTable
		end)
		if ok and type(res) == "table" then
			for _, v in ipairs(res) do if typeof(v) == "Instance" and v:IsA("Model") then table.insert(found, v) end end
		end
		if #found == 0 then
			for _, d in ipairs(selfRef.Surface:GetDescendants()) do
				if d:IsA("Model") then
					local base = d:FindFirstChild("Base")
					if (d.Name:match("^T%d+") or (base and base:FindFirstChild("PlateHeight"))) then
						table.insert(found, d)
					end
				end
			end
		end
		return found
	end)(self)) do
		local base   = tbl:FindFirstChild("Base")
		local plate  = base and base:FindFirstChild("PlateHeight")
		local chairs = {}
		local ok, linked = pcall(TableConnectionUtility.FindChairs, TableConnectionUtility, self.Tycoon, tbl)
		if ok and type(linked) == "table" then chairs = linked end

		table.insert(list, tbl)
		meta[tbl] = {
			idx          = parseTableIndex(tbl.Name),
			seats        = #chairs,
			chairList    = chairs,
			inUse        = tbl:GetAttribute("InUse") == true,
			plateAdornee = plate,
		}
	end

	table.sort(list, function(a, b)
		local ia, ib = meta[a].idx, meta[b].idx
		if ia ~= ib then return ia < ib end
		return a.Name < b.Name
	end)

	self._tableList, self._tableMeta, self._tablesDirty = list, meta, false
end
function RTHelper:_ensureTables()
	if self._tablesDirty or #self._tableList == 0 then self:_rebuildTableCache() end
end
function RTHelper:GetAllTables(): {Model} self:_ensureTables(); return self._tableList end
function RTHelper:GetAvailableTables(): {Model}
	self:_ensureTables()
	local out = {}
	for _, m in ipairs(self._tableList) do
		local md = self._tableMeta[m]
		if md.plateAdornee and (not md.inUse) and md.seats > 0 then table.insert(out, m) end
	end
	return out
end

-- ───────── loops (with watchdog & serve-first policy)
function RTHelper:RunSeatOrderLoop()
	task.spawn(function()
		while true do
			if self.flags.autoSeatOrder then pcall(function() self:HandleSpeechPrompts() end) end
			task.wait(self.tuners.seatPeriod)
		end
	end)
end
function RTHelper:RunCookLoop()
	task.spawn(function()
		while true do
			-- watchdog
			if self._cookActive and (now() - self._cookBeatAt) > self.tuners.cookStallSec then
				if DEBUG then warn("[RTHelper] cook stalled; forcing idle") end
				self._cookActive = false
				self.stats.stallsFixed += 1
			end

			-- serve first if we can
			if not self._serveBusy then pcall(function() self:ServeIfPossible() end) end

			-- start cooking aggressively (works even if there’s 0 orders; harmless)
			if self.flags.autoCook and (not self._cookActive) and (not self._serveBusy) and (self._foodInHand == nil) then
				pcall(function() self:PressOrderCounter() end)
			end

			task.wait(self.tuners.cookPeriod)
		end
	end)
end
function RTHelper:RunHousekeepingLoop()
	task.spawn(function()
		while true do
			if self.flags.housekeeping then pcall(function() self:SweepBillsAndDishesOnce(self.tuners.housePerTick) end) end
			task.wait(self.tuners.housePeriod)
		end
	end)
end

-- ───────── Interact passthrough (rarely needed)
function RTHelper:Interact(details: InteractArgs, tycoonOverride: Instance?)
	local tycoon = tycoonOverride or self.Tycoon
	if typeof(details.WorldPosition) ~= "Vector3" then error("WorldPosition must be a Vector3") end
	self.Interacted:FireServer(tycoon, details)
end

-- ───────── Anti-AFK
local AntiAFK = { _conn = nil, enabled = false }
function AntiAFK:set(state: boolean)
	self.enabled = state
	if self._conn then self._conn:Disconnect() self._conn = nil end
	if state then
		local vu = game:GetService("VirtualUser")
		self._conn = Players.LocalPlayer.Idled:Connect(function()
			vu:CaptureController()
			vu:ClickButton2(Vector2.new())
		end)
	end
end

-- ───────── UI (single tab)
local function loadUILib()
	local URL = "https://raw.githubusercontent.com/ProtonDev-sys/the-return/refs/heads/main/ui%20library/ui%20library.lua"
	local ok, lib = pcall(function() return loadstring(game:HttpGet(URL))() end)
	if ok then return lib end
	warn("[RTHelper] UI library failed to load: ", tostring(lib))
	return nil
end
local function tryMakeWindow(lib, spec)
	if type(lib) == "function" then local ok, win = pcall(lib, spec); if ok and type(win)=="table" then return win end end
	for _, name in ipairs({ "Window","CreateWindow","New","new" }) do
		local fn = (type(lib)=="table") and lib[name]
		if type(fn)=="function" then
			local ok, win = pcall(fn, lib, spec); if not ok then ok, win = pcall(fn, spec) end
			if ok and type(win)=="table" then return win end
		end
	end
	return nil
end
local function addToggle(where, label, default, cb)
	if where and type(where.Toggle)=="function" then local t=where:Toggle(label, cb); if t and t.Set then t:Set(default) end; return end
	if where and type(where.AddToggle)=="function" then where:AddToggle(label, default, cb); return end
	cb(default)
end
local function addSlider(where, label, min, max, default, cb)
	if where and type(where.Slider)=="function" then where:Slider(label,min,max,default,cb); return end
	if where and type(where.AddSlider)=="function" then where:AddSlider(label,min,max,default,cb); return end
end
local function addLabel(where, text)
	if where and type(where.Label)=="function" then return where:Label(text) end
	if where and type(where.AddLabel)=="function" then return where:AddLabel(text) end
	return nil
end

-- ───────── boot
local rt = RTHelper.new()
rt:RunSeatOrderLoop()
rt:RunCookLoop()
rt:RunHousekeepingLoop()
AntiAFK:set(true)

local UI = loadUILib()
if UI then
	local win = tryMakeWindow(UI, { Title="RT3 Helper", CFG="RT3_HELPER_CFG", Key=Enum.KeyCode.RightShift, External={KeySystem=false} })
	if win then
		local tab = (win.Tab and win:Tab("Automation")) or win
		local sec = (tab.Section and tab:Section("Main")) or tab

		addToggle(sec, "Auto Seat & Take Orders", true, function(v) rt.flags.autoSeatOrder = v end)
		addToggle(sec, "Auto Cook",               true, function(v) rt.flags.autoCook      = v end)
		addToggle(sec, "Auto Bills + Dishes",     true, function(v) rt.flags.housekeeping  = v end)
		addToggle(sec, "Anti-AFK",                true, function(v) AntiAFK:set(v) end)

		addSlider(sec, "Seat check (s)",  0.1,  1.0, rt.tuners.seatPeriod, function(v) rt.tuners.seatPeriod = tonumber(string.format("%.2f", v)) end)
		addSlider(sec, "Cook check (s)",  0.25, 2.0, rt.tuners.cookPeriod, function(v) rt.tuners.cookPeriod = tonumber(string.format("%.2f", v)) end)
		addSlider(sec, "Housekeep (s)",   0.2,  3.0, rt.tuners.housePeriod,function(v) rt.tuners.housePeriod= tonumber(string.format("%.2f", v)) end)
		addSlider(sec, "Actions/tick",       1,   20, rt.tuners.housePerTick, function(v) rt.tuners.housePerTick = math.floor(v) end)

		local statsLabel = addLabel(sec, "Stats initialising...")
		task.spawn(function()
			while true do
				if statsLabel and statsLabel.Set then
					statsLabel:Set(string.format(
						"Stats: seated %d | orders %d | served %d | dishes %d | bills %d | cook starts %d | stalls fixed %d | Q:%d/%d | holding:%s",
						rt.stats.groupsSeated, rt.stats.ordersTaken, rt.stats.served, rt.stats.dishes, rt.stats.bills, rt.stats.cookStarts,
						rt.stats.stallsFixed, #rt._serveQueue, #rt._orderQueue, tostring(rt._foodInHand ~= nil)
					))
				end
				task.wait(1)
			end
		end)
	else
		warn("[RTHelper] UI: couldn’t create window; running headless.")
	end
else
	warn("[RTHelper] UI not available; running headless.")
end

print(("[RTHelper] tycoon: %s | tables: %d | available: %d")
	:format(rt.Tycoon and rt.Tycoon.Name or "nil", #rt:GetAllTables(), #rt:GetAvailableTables()))
