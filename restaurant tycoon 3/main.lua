-- RTHelper UI Build (single-file)
-- FAST + RELIABLE: auto-seat, auto-take-orders, auto-start cook, auto-cook (ALL remotes),
-- auto-serve to correct customer, auto-collect bills & dishes (TaskCompleted),
-- Anti-AFK, flexible UI adapter (Window/CreateWindow/New/callable).

--!strict
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local DEBUG = false

-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║                                Utils                                 ║
-- ╚══════════════════════════════════════════════════════════════════════╝
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

-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║                          Game Module Requires                        ║
-- ╚══════════════════════════════════════════════════════════════════════╝
local FurnitureUtility       = safeRequire(path(ReplicatedStorage, "Source", "Utility", "FurnitureUtility"))
local TableConnectionUtility = safeRequire(path(ReplicatedStorage, "Source", "Utility", "Furniture", "TableConnectionUtility"))
local Customers              = safeRequire(path(LocalPlayer:WaitForChild("PlayerScripts"), "Source", "Systems", "Restaurant", "Customers"))
local CustomerState          = safeRequire(path(ReplicatedStorage, "Source", "Enums", "Restaurant", "Customer", "CustomerState"))
local Cook                   = safeRequire(path(LocalPlayer.PlayerScripts, "Source", "Systems", "Cook"))
local CookReplication        = safeRequire(path(ReplicatedStorage, "Source", "Enums", "Cook", "CookReplication"))
local TaskEnum               = safeRequire(path(ReplicatedStorage, "Source", "Enums", "Restaurant", "Task"))

assert(FurnitureUtility, "require(FurnitureUtility) failed")
assert(TableConnectionUtility, "require(TableConnectionUtility) failed")
assert(Customers, "require(Customers) failed")
assert(CustomerState, "require(CustomerState) failed")
assert(Cook, "require(Cook) failed")
assert(CookReplication, "require(CookReplication) failed")
assert(TaskEnum, "require(Task) failed")

-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║                               Tycoon                                 ║
-- ╚══════════════════════════════════════════════════════════════════════╝
local function waitTycoonOV(timeout: number?): Instance?
	local deadline = os.clock() + (timeout or 5)
	local ov = LocalPlayer:FindFirstChild("Tycoon") or LocalPlayer:WaitForChild("Tycoon", timeout or 5)
	if not (ov and ov:IsA("ObjectValue")) then return nil end
	if ov.Value then return ov.Value end
	while os.clock() < deadline and ov.Value == nil do task.wait(0.1) end
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

-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║                                Types                                 ║
-- ╚══════════════════════════════════════════════════════════════════════╝
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
	local Events           = path(ReplicatedStorage, "Events")
	local Restaurant       = path(Events, "Restaurant")
	self.TaskCompleted     = path(Restaurant, "TaskCompleted") :: RemoteEvent
	self.GrabFoodRF        = path(Restaurant, "GrabFood") :: RemoteFunction
	self.Interacted        = path(Restaurant, "Interactions", "Interacted") :: RemoteEvent

	-- Cook remotes
	local CookEvents       = path(Events, "Cook")
	self.CookInputRequested= path(CookEvents, "CookInputRequested") :: RemoteEvent
	self.CookUpdated       = path(CookEvents, "CookUpdated") :: RemoteEvent

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
	self._serveQueue    = {} :: { {gid: string, cid: string} }
	self._lastFoodModel = nil :: Instance?
	self._cookActive    = false

	-- per-table + per-group cooldowns
	self._dishCooldown  = {} :: {[Model]: number}
	self._billCooldown  = {} :: {[Model]: number}
	self._seatCooldown  = {} :: {[string]: number} -- groupId -> last seat try

	-- control flags for loops
	self.flags = {
		autoSeatOrder = true,
		autoCook      = true,
		housekeeping  = true,
	}
	self.tuners = {
		seatPeriod    = 0.35,
		cookPeriod    = 0.75,
		housePeriod   = 0.6,
		housePerTick  = 10,
	}

	-- stats
	self.stats = {
		ordersTaken  = 0,
		groupsSeated = 0,
		served       = 0,
		dishes       = 0,
		bills        = 0,
		cookStarts   = 0,
	}

	self:_bindSurfaceWatcher()
	self:_bindFoodWatcher()
	self:_bindCustomerEvents()
	self:_bindCookEvents()

	if DEBUG then print("[RTHelper] Tycoon:", self.Tycoon:GetFullName()) end
	return self
end

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

function RTHelper:_bindFoodWatcher()
	self.FoodFolder.ChildAdded:Connect(function(ch)
		self._lastFoodModel = ch
		if DEBUG then print("[RTHelper] Food ready:", ch.Name) end
	end)
end

-- customer events -> queue serves
function RTHelper:_bindCustomerEvents()
	if Customers.CustomerStateChanged then
		Customers.CustomerStateChanged:Connect(function(...)
			local a = { ... }
			local tycoon = a[1]; if tycoon ~= self.Tycoon then return end
			local gid    = toStringId(a[2])
			local cid    = toStringId(a[3])
			local state  = a[5] or a[#a]
			if state == CustomerState.WaitingForDish then
				table.insert(self._serveQueue, { gid = gid, cid = cid })
				if DEBUG then print("[RTHelper] queued serve:", gid, cid) end
			end
		end)
	end
end

-- cooking spammer
function RTHelper:_cookInteract(model: Instance, itemType: any)
	self.CookInputRequested:FireServer(CookReplication.Interact, model, itemType)
end
function RTHelper:_cookComplete(model: Instance?, itemType: any, instrKey: any?)
	self.CookInputRequested:FireServer(CookReplication.CompleteTask, model, itemType)
	if instrKey ~= nil then
		self.CookInputRequested:FireServer(CookReplication.CompleteTask, itemType, instrKey, false)
	end
end
function RTHelper:_bindCookEvents()
	if Cook.Started then
		Cook.Started:Connect(function(ty)
			if ty == self.Tycoon then self._cookActive = true; self.stats.cookStarts += 1 end
		end)
	end
	if Cook.Finished then
		Cook.Finished:Connect(function(ty)
			if ty == self.Tycoon then
				self._cookActive = false
				task.defer(function() self:GrabFoodAndServeNext() end)
			end
		end)
	end

	self.CookUpdated.OnClientEvent:Connect(function(op, ...)
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
			task.defer(function() self:GrabFoodAndServeNext() end)
		end
	end)

	if Cook.StateUpdated then
		Cook.StateUpdated:Connect(function(state)
			if not state then return end
			self:_cookComplete(nil, nil, state.InstructionKey)
		end)
	end
end

-- start cooking (order counter)
function RTHelper:PressOrderCounter()
	local counters = FurnitureUtility:FindWhere(self.Tycoon, self.Surface, function(inst)
		return FurnitureUtility:Is(inst, FurnitureUtility.ItemType.OrderCounter)
	end)
	if #counters == 0 then return false end
	local counter = counters[1]

	local prompt: ProximityPrompt?
	for _, d in ipairs(counter:GetDescendants()) do
		if d:IsA("ProximityPrompt") then prompt = d break end
	end
	local fpp = getfenv().fireproximityprompt
	if prompt and typeof(fpp) == "function" then
		pcall(fpp, prompt)
		return true
	end
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

-- after cook -> grab & serve next queued
function RTHelper:GrabFoodAndServeNext()
	local food = self._lastFoodModel
	if not (food and food.Parent == self.FoodFolder) then
		local kids = self.FoodFolder:GetChildren()
		table.sort(kids, function(a,b) return a.Name > b.Name end)
		food = kids[1]
	end
	if not food then return end

	local nextServe = table.remove(self._serveQueue, 1)
	if not nextServe then return end

	pcall(function() self.GrabFoodRF:InvokeServer(food) end)
	local args: {ServeArgs} = { {
		Name = TaskEnum.Serve, GroupId = nextServe.gid, Tycoon = self.Tycoon, FoodModel = food, CustomerId = nextServe.cid
	} }
	self.TaskCompleted:FireServer(unpack(args))
	self.stats.served += 1
end

-- tables
local function _findTables(self): {Model}
	local found = {}
	local ok, list = pcall(FurnitureUtility.FindWhere, FurnitureUtility, self.Tycoon, self.Surface, function(inst)
		local ok2, isTable = pcall(FurnitureUtility.IsTable, FurnitureUtility, inst)
		return ok2 and isTable
	end)
	if ok and type(list) == "table" then
		for _, v in ipairs(list) do
			if typeof(v) == "Instance" and v:IsA("Model") then table.insert(found, v) end
		end
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
		if md.plateAdornee and (not md.inUse) and md.seats > 0 then
			table.insert(out, m)
		end
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

-- group + orders
function RTHelper:_iterSpeechUIs()
	local pg = LocalPlayer.PlayerGui
	local out = {}
	if not pg then return out end
	for _, gui in ipairs(pg:GetChildren()) do
		if gui:IsA("BillboardGui") and gui.Name == "CustomerSpeechUI" and gui.Adornee then
			local head = gui.Adornee
			local char = head.Parent
			local group = char and char.Parent
			if char and group then
				table.insert(out, {head = head, char = char, group = group})
			end
		end
	end
	return out
end
function RTHelper:_extractIds(group: Instance, char: Instance): (string, string)
	local gid = group:GetAttribute("GroupId") or group:GetAttribute("Id") or group.Name
	local cid = char:GetAttribute("CustomerId") or char:GetAttribute("Id") or char.Name
	return toStringId(gid), toStringId(cid)
end
function RTHelper:GetCustomerState(groupId: string | number, customerId: string | number)
	local ok, state = pcall(Customers.GetCustomerState, Customers, self.Tycoon, toStringId(groupId), toStringId(customerId))
	if ok then return state end
	return nil
end
function RTHelper:GetGroupState(groupId: string | number)
	local ok, state = pcall(Customers.GetGroupState, Customers, self.Tycoon, toStringId(groupId))
	if ok then return state end
	return nil
end
function RTHelper:IsDummySeated(char: Instance): (boolean, Model?)
	self:_ensureTables()
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return false, nil end
	for _, tbl in ipairs(self._tableList) do
		local md = self._tableMeta[tbl]
		for _, seat in ipairs(md.chairList) do
			if (seat:IsA("Seat") or seat:IsA("VehicleSeat")) and seat.Occupant == hum then
				return true, tbl
			end
		end
	end
	return false, nil
end

-- seat/order with strict gating + correct stats
function RTHelper:HandleSpeechPrompts()
	local prompts = self:_iterSpeechUIs()

	-- gather per group
	local groups: {[string]: {group: Instance, unseated: number, anyOrdering: boolean, gstate: any}} = {}
	local orders = {}  -- { {gid, cid} }

	for _, p in ipairs(prompts) do
		local gid, cid = self:_extractIds(p.group, p.char)
		local state = self:GetCustomerState(gid, cid)

		-- seated customers asking to order
		if state == CustomerState.Ordering then
			table.insert(orders, {gid = gid, cid = cid})
		end

		-- init group bucket
		local g = groups[gid]
		if not g then
			g = { group = p.group, unseated = 0, anyOrdering = false, gstate = self:GetGroupState(gid) }
			groups[gid] = g
		end
		if state == CustomerState.Ordering then g.anyOrdering = true end

		-- per-dummy seating
		local isSeated = select(1, self:IsDummySeated(p.char))
		if not isSeated then g.unseated += 1 end
	end

	-- Take orders first
	for _, o in ipairs(orders) do
		self:TakeOrder(o.cid, o.gid)
		self.stats.ordersTaken += 1
	end

	-- Seat only true waiting groups (cooldown + state checks)
	local now = os.clock()
	for gid, g in pairs(groups) do
		if g.unseated > 0 and not g.anyOrdering then
			local gs = g.gstate
			local goingOrSeated =
				(gs == CustomerState.GoingToTable) or
				(gs == CustomerState.Seated) or
				(gs == CustomerState.WaitingForDish)

			if not goingOrSeated then
				local last = self._seatCooldown[gid] or 0
				if (now - last) >= 1.5 then
					local tbl = self:GetTableForGroup(g.group)
					if tbl then
						self:SendToTable(gid, tbl)
						self.stats.groupsSeated += 1 -- count only when we actually seat
						self._seatCooldown[gid] = now
					else
						self._seatCooldown[gid] = now -- backoff when no table
					end
				end
			end
		end
	end
end

-- bills + dishes via TaskCompleted
function RTHelper:_canCollectDishes(tbl: Model): boolean
	return tbl:FindFirstChild("Trash") ~= nil
end
function RTHelper:_canCollectBill(tbl: Model): boolean
	local bill = tbl:FindFirstChild("Bill")
	return bill ~= nil and (bill:GetAttribute("Taken") ~= true)
end
function RTHelper:_collectDishes(tbl: Model)
	self.TaskCompleted:FireServer({
		Name = TaskEnum.CollectDishes;
		FurnitureModel = tbl;
		Tycoon = self.Tycoon;
	})
	self.stats.dishes += 1
end
function RTHelper:_collectBill(tbl: Model)
	self.TaskCompleted:FireServer({
		Name = TaskEnum.CollectBill;
		FurnitureModel = tbl;
		Tycoon = self.Tycoon;
	})
	self.stats.bills += 1
end
function RTHelper:SweepBillsAndDishesOnce(maxActions: number?)
	self:_ensureTables()
	local now = os.clock()
	local left = maxActions or 8

	for _, tbl in ipairs(self._tableList) do
		if left <= 0 then break end

		if self:_canCollectDishes(tbl) then
			local last = self._dishCooldown[tbl] or 0
			if now - last >= 0.55 then
				self._dishCooldown[tbl] = now
				self:_collectDishes(tbl)
				left -= 1
				if left <= 0 then break end
			end
		end

		if self:_canCollectBill(tbl) then
			local last = self._billCooldown[tbl] or 0
			if now - last >= 1.05 then
				self._billCooldown[tbl] = now
				self:_collectBill(tbl)
				left -= 1
				if left <= 0 then break end
			end
		end
	end
end

-- remotes
function RTHelper:SendToTable(groupId: string | number, furnitureModel: Instance)
	local args: {TableSendArgs} = { {
		GroupId = toStringId(groupId), Tycoon = self.Tycoon, Name = TaskEnum.SendToTable, FurnitureModel = furnitureModel,
	} }
	self.TaskCompleted:FireServer(unpack(args))
end
function RTHelper:GrabFood(food: Instance | string | number)
	local foodInstance: Instance
	if typeof(food) == "Instance" then
		foodInstance = food
	else
		foodInstance = path(self.Objects, "Food"):WaitForChild(toStringId(food))
	end
	self.GrabFoodRF:InvokeServer(foodInstance)
end
function RTHelper:Serve(customerId: string | number, groupId: string | number?, foodModel: Instance?)
	local args: {ServeArgs} = { {
		Name = TaskEnum.Serve, GroupId = toStringId(groupId or "1"), Tycoon = self.Tycoon,
		FoodModel = foodModel or Instance.new("Model"), CustomerId = toStringId(customerId),
	} }
	self.TaskCompleted:FireServer(unpack(args))
	self.stats.served += 1
end
function RTHelper:TakeOrder(customerId: string | number, groupId: string | number?)
	local args: {TakeOrderArgs} = { {
		Name = TaskEnum.TakeOrder, GroupId = toStringId(groupId or "2"), Tycoon = self.Tycoon, CustomerId = toStringId(customerId),
	} }
	self.TaskCompleted:FireServer(unpack(args))
	self.stats.ordersTaken += 1
end
function RTHelper:Interact(details: InteractArgs, tycoonOverride: Instance?)
	local tycoon = tycoonOverride or self.Tycoon
	if typeof(details.WorldPosition) ~= "Vector3" then error("WorldPosition must be a Vector3") end
	self.Interacted:FireServer(tycoon, details)
end

-- background loops (toggleable)
function RTHelper:RunSeatOrderLoop()
	task.spawn(function()
		while true do
			if self.flags.autoSeatOrder then
				pcall(function() self:HandleSpeechPrompts() end)
			end
			task.wait(self.tuners.seatPeriod)
		end
	end)
end
function RTHelper:RunCookLoop()
	task.spawn(function()
		while true do
			if self.flags.autoCook and not self._cookActive then
				pcall(function() self:PressOrderCounter() end)
			end
			task.wait(self.tuners.cookPeriod)
		end
	end)
end
function RTHelper:RunHousekeepingLoop()
	task.spawn(function()
		while true do
			if self.flags.housekeeping then
				pcall(function() self:SweepBillsAndDishesOnce(self.tuners.housePerTick) end)
			end
			task.wait(self.tuners.housePeriod)
		end
	end)
end

-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║                               Anti-AFK                               ║
-- ╚══════════════════════════════════════════════════════════════════════╝
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

-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║                              UI Adapter                              ║
-- ╚══════════════════════════════════════════════════════════════════════╝
local function loadUILib()
	local URL = "https://raw.githubusercontent.com/ProtonDev-sys/the-return/refs/heads/main/ui%20library/ui%20library.lua"
	local ok, lib = pcall(function() return loadstring(game:HttpGet(URL))() end)
	if ok then return lib end
	warn("[RTHelper] UI library failed to load: ", tostring(lib))
	return nil
end
local function tryMakeWindow(lib, spec)
	-- lib as a function?
	if type(lib) == "function" then
		local ok, win = pcall(lib, spec); if ok and type(win) == "table" then return win end
	end
	-- common ctors
	local candidates = { "Window", "CreateWindow", "New", "new" }
	for _, name in ipairs(candidates) do
		local fn = (type(lib) == "table") and lib[name]
		if type(fn) == "function" then
			local ok, win = pcall(fn, lib, spec) -- method
			if not ok then ok, win = pcall(fn, spec) end -- function
			if ok and type(win) == "table" then return win end
		end
	end
	return nil
end
local function tryMethod(obj, name, ...)
	local fn = obj and obj[name]
	if type(fn) == "function" then
		local ok, a, b, c = pcall(fn, obj, ...)
		if ok then return a, b, c end
	end
	return nil
end
local function addToggle(where, label, default, cb)
	if where and type(where.Toggle) == "function" then
		local t = where:Toggle(label, cb); if t and t.Set then t:Set(default) end; return
	end
	if where and type(where.AddToggle) == "function" then
		where:AddToggle(label, default, cb); return
	end
	cb(default)
end
local function addSlider(where, label, min, max, default, cb)
	if where and type(where.Slider) == "function" then where:Slider(label, min, max, default, cb); return end
	if where and type(where.AddSlider) == "function" then where:AddSlider(label, min, max, default, cb); return end
end
local function addLabel(where, text)
	if where and type(where.Label) == "function" then return where:Label(text) end
	if where and type(where.AddLabel) == "function" then return where:AddLabel(text) end
	return nil
end

-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║                               Boot / UI                              ║
-- ╚══════════════════════════════════════════════════════════════════════╝
local rt = RTHelper.new()
rt:RunSeatOrderLoop()
rt:RunCookLoop()
rt:RunHousekeepingLoop()
AntiAFK:set(true)

local UI = loadUILib()
if UI then
	local win = tryMakeWindow(UI, {
		Title = "RT3 Helper",
		CFG   = "RT3_HELPER_CFG",
		Key   = Enum.KeyCode.RightShift,
		External = { KeySystem = false }
	})
	if not win then
		warn("[RTHelper] UI: couldn’t create window; running headless.")
	else
		-- layout: TSection -> Tab -> Section (fallbacks tolerant)
		local autoSection = tryMethod(win, "TSection", "Automation") or win
		local autoTab     = tryMethod(autoSection, "Tab", "Main")   or autoSection
		local auto        = tryMethod(autoTab, "Section", "Toggles") or autoTab

		local cookTab     = tryMethod(autoSection, "Tab", "Cooking") or autoSection
		local cookSec     = tryMethod(cookTab, "Section", "Control") or cookTab

		local hkTab       = tryMethod(autoSection, "Tab", "Housekeeping") or autoSection
		local hkSec       = tryMethod(hkTab, "Section", "Bills & Dishes") or hkTab

		local miscSection = tryMethod(win, "TSection", "Misc") or win
		local miscTab     = tryMethod(miscSection, "Tab", "Other") or miscSection
		local misc        = tryMethod(miscTab, "Section", "Anti-AFK & Stats") or miscTab

		-- toggles
		addToggle(auto, "Auto Seat & Take Orders", true, function(state) rt.flags.autoSeatOrder = state end)
		addToggle(auto, "Auto Cook",               true, function(state) rt.flags.autoCook      = state end)
		addToggle(hkSec, "Auto Bills + Dishes",    true, function(state) rt.flags.housekeeping  = state end)
		addToggle(misc, "Anti-AFK",                true, function(state) AntiAFK:set(state) end)

		-- sliders
		addSlider(hkSec, "Per tick actions", 1, 20, rt.tuners.housePerTick, function(v) rt.tuners.housePerTick = math.floor(v) end)
		addSlider(hkSec, "Sweep every (s)",  0.2, 3.0, rt.tuners.housePeriod, function(v) rt.tuners.housePeriod = tonumber(string.format("%.2f", v)) end)
		addSlider(cookSec, "Cook check (s)", 0.25, 2.0, rt.tuners.cookPeriod, function(v) rt.tuners.cookPeriod = tonumber(string.format("%.2f", v)) end)
		addSlider(auto,   "Seat check (s)",  0.1,  1.0, rt.tuners.seatPeriod, function(v) rt.tuners.seatPeriod = tonumber(string.format("%.2f", v)) end)

		-- live stats
		local statsLabel = addLabel(misc, "Stats initialising...")
		task.spawn(function()
			while true do
				if statsLabel and statsLabel.Set then
					statsLabel:Set(string.format(
						"Stats: %d seated | %d orders | %d served | %d dishes | %d bills | %d cook starts",
						rt.stats.groupsSeated, rt.stats.ordersTaken, rt.stats.served, rt.stats.dishes, rt.stats.bills, rt.stats.cookStarts
					))
				end
				task.wait(1)
			end
		end)
	end
else
	warn("[RTHelper] UI not available; running headless.")
end

print(("[RTHelper] tycoon: %s | tables: %d | available: %d")
	:format(rt.Tycoon and rt.Tycoon.Name or "nil", #rt:GetAllTables(), #rt:GetAvailableTables()))
