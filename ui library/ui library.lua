-- ProUI v1.5.1 — Midnight Slate, premium UX, mobile-friendly
-- MIT-ish
-- Changes in 1.5.1:
--  • Fixed syntax error in getSafeParent (typeof(gethui))
--  • Added missing 'end' for Signal:Fire
--  • ColorPicker now respects ui:SetColorWheelAsset() by default via Tab helper
--  • General tidy

local ProUI = {}
ProUI.__index = ProUI

--// Services
local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInput    = game:GetService("UserInputService")
local GuiService   = game:GetService("GuiService")
local CoreGui      = game:GetService("CoreGui")
local HttpService  = game:GetService("HttpService")

--// Env adapters
local function hasfunc(f) return typeof(f) == "function" end
local write_ok = writefile and hasfunc(writefile) or false
local read_ok  = readfile  and hasfunc(readfile)  or false
local mk_ok    = makefolder and hasfunc(makefolder) or false
local isf_ok   = isfolder   and hasfunc(isfolder) or false
local protect  = (syn and hasfunc(syn.protect_gui)) and syn.protect_gui or nil

--// Signals
local Signal = {}
Signal.__index = Signal
function Signal.new() return setmetatable({ _b = {} }, Signal) end
function Signal:Connect(fn)
	local c = { fn = fn, Connected = true }; self._b[c] = true
	return setmetatable(c, { __index = { Disconnect = function() if c.Connected then c.Connected=false; self._b[c]=nil end end } })
end
function Signal:Fire(...)
	for c in pairs(self._b) do
		if c.Connected then task.spawn(c.fn, ...) end
	end
end

--// Theme tokens
local Themes = {
	["Midnight Slate"] = {
		Bg        = Color3.fromRGB(18,19,23),
		Surface   = Color3.fromRGB(24,26,32),
		Panel     = Color3.fromRGB(30,33,40),
		Hover     = Color3.fromRGB(38,42,52),
		Text      = Color3.fromRGB(237,239,245),
		SubText   = Color3.fromRGB(171,178,191),
		Stroke    = Color3.fromRGB(64,70,84),
		Accent    = Color3.fromRGB(0,170,255),
		AccentHover = Color3.fromRGB(20,190,255),
		Success   = Color3.fromRGB(0,200,120),
		Warning   = Color3.fromRGB(255,196,62),
		Error     = Color3.fromRGB(235,90,90),
		Handle    = Color3.fromRGB(246,248,252),
		Track     = Color3.fromRGB(54,58,68),
		Fill      = Color3.fromRGB(0,170,255),
		DropdownBg= Color3.fromRGB(26,28,34),
		Scrim     = Color3.fromRGB(0,0,0),
	},
}

local function cloneTheme(t) local c={}; for k,v in pairs(t) do c[k]=v end; return c end
local ActiveTheme = cloneTheme(Themes["Midnight Slate"])

--// Utils
local function isTouch() return UserInput.TouchEnabled and not UserInput.KeyboardEnabled end
local function toNumber(x, fallback) local n=tonumber(x); return n~=nil and n or fallback end
local function round(n, step) n=toNumber(n,0); step=toNumber(step,1); if step==0 then return n end; return math.floor(n/step+0.5)*step end
local function clamp(n, a, b) n=toNumber(n,a); return math.clamp(n,a,b) end
local function create(class, props, children)
	local inst = Instance.new(class)
	for k,v in pairs(props or {}) do inst[k]=v end
	for _,c in ipairs(children or {}) do c.Parent=inst end
	return inst
end
local function tween(o,t,g) return TweenService:Create(o, TweenInfo.new(t or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), g or {}) end

--// Parent
local function getSafeParent()
	local lp = Players.LocalPlayer
	if lp then
		local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:FindFirstChild("PlayerGui")
		if pg then return pg end
	end
	if typeof(gethui)=="function" then local ok,gui=pcall(gethui); if ok and gui then return gui end end
	return CoreGui
end

--// Save
local Save = {}
Save.BaseFolder = "ProUI"
local function ensureFolder() if mk_ok and isf_ok and not isfolder(Save.BaseFolder) then pcall(makefolder, Save.BaseFolder) end end
function Save:Path(id) return ("%s/%s.json"):format(self.BaseFolder, id) end
function Save:Load(id, default)
	if read_ok and isf_ok then
		ensureFolder()
		if isfolder(self.BaseFolder) then
			local ok, data = pcall(readfile, self:Path(id))
			if ok and data then local okJ, obj = pcall(HttpService.JSONDecode, HttpService, data); if okJ and obj then return obj end end
		end
	end
	return default or {}
end
function Save:Save(id, tbl)
	if write_ok and isf_ok then
		ensureFolder()
		local okJ, data = pcall(HttpService.JSONEncode, HttpService, tbl)
		if okJ then pcall(writefile, self:Path(id), data) end
	end
end

--// Screen + Overlay
local function createScreenGui(name)
	local sg = create("ScreenGui", {
		Name=name or "ProUI", ZIndexBehavior=Enum.ZIndexBehavior.Sibling, ResetOnSpawn=false,
		IgnoreGuiInset=false, Enabled=true, DisplayOrder=2200,
	})
	local parent = getSafeParent()
	if protect and parent == CoreGui then pcall(protect, sg) end
	sg.Parent = parent
	local overlay = create("Frame", { Name="Overlay", BackgroundColor3=ActiveTheme.Scrim, BackgroundTransparency=1, Size=UDim2.fromScale(1,1), ZIndex=999, Visible=false })
	overlay.Parent = sg
	return sg, overlay
end
local function openOverlay(overlay) overlay.Visible=true end
local function closeOverlay(overlay) overlay.Visible=false; for _,c in ipairs(overlay:GetChildren()) do c:Destroy() end end

--// Keybinds
local Keybinds = {}
local InputBeganConn
local function isTyping() return UserInput:GetFocusedTextBox() ~= nil end
local function connectKeyListener()
	if InputBeganConn then InputBeganConn:Disconnect() end
	InputBeganConn = UserInput.InputBegan:Connect(function(input, gp)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		if isTyping() then return end
		for _,b in pairs(Keybinds) do
			if b.keycode == input.KeyCode then
				if gp and not b.allowGameProcessed then return end
				if b.callback then task.spawn(b.callback) end
			end
		end
	end)
end
local function setKeybind(name, keycode, callback, allowGameProcessed)
	Keybinds[name] = { keycode = keycode, callback = callback, allowGameProcessed = not not allowGameProcessed }
	connectKeyListener()
end
local function removeKeybind(name) Keybinds[name] = nil end

--// Color helpers
local function h2rgb(h,s,v)
	local i=math.floor(h*6); local f=h*6 - i; local p=v*(1-s); local q=v*(1-f*s); local t=v*(1-(1-f)*s); local r,g,b
	if i%6==0 then r,g,b=v,t,p elseif i%6==1 then r,g,b=q,v,p elseif i%6==2 then r,g,b=p,v,t elseif i%6==3 then r,g,b=p,q,v elseif i%6==4 then r,g,b=t,p,v else r,g,b=v,p,q end
	return Color3.new(r,g,b)
end

--// Controls
local Controls = {}

function Controls:Section(container, text, collapsible, tooltipText)
	local root = create("Frame", {
		Name="SectionHead", BackgroundColor3=ActiveTheme.Panel, BorderSizePixel=0,
		Size=UDim2.new(1,0,0,isTouch() and 40 or 36), ZIndex=container.ZIndex
	}, { create("UICorner",{CornerRadius=UDim.new(0,12)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	root.Parent = container

	local title = create("TextButton", {
		BackgroundTransparency=1, Size=UDim2.new(1,-12,1,0), Position=UDim2.fromOffset(12,0), Text=text or "Section",
		Font=Enum.Font.GothamMedium, TextColor3=ActiveTheme.Text, TextSize=14, TextXAlignment=Enum.TextXAlignment.Left, AutoButtonColor=false
	})
	title.Parent = root

	local caret = create("TextLabel", {
		BackgroundTransparency=1, Size=UDim2.fromOffset(20,20), Position=UDim2.new(1,-24,0.5,-10),
		Text = collapsible and "▼" or "", Font=Enum.Font.GothamBold, TextSize=14, TextColor3=ActiveTheme.SubText
	})
	caret.Parent = root

	if tooltipText and tooltipText ~= "" then
		local tip = create("TextLabel", {
			BackgroundColor3=ActiveTheme.DropdownBg, TextColor3=ActiveTheme.Text, TextSize=13, Font=Enum.Font.Gotham, Text=tooltipText,
			Visible=false, ZIndex=995, Position=UDim2.new(0,10,0, (isTouch() and 40 or 36) + 6 ), Size=UDim2.fromOffset(280,24)
		}, { create("UICorner",{CornerRadius=UDim.new(0,8)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
		tip.Parent = root
		title.MouseEnter:Connect(function() tip.Visible=true end)
		title.MouseLeave:Connect(function() tip.Visible=false end)
	end

	local content = create("Frame", { Name="SectionContent", BackgroundTransparency=1, Size=UDim2.new(1,0,0,0), ZIndex=container.ZIndex, ClipsDescendants=true })
	content.Parent = container
	local innerList = create("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,8)}); innerList.Parent = content

	local open = not collapsible
	local function measure()
		local total=0
		for _,c in ipairs(content:GetChildren()) do if c:IsA("GuiObject") and c.Visible then total += c.AbsoluteSize.Y + 8 end end
		return total
	end
	local function setOpen(v)
		open = v
		caret.Text = open and (collapsible and "▼" or "") or "►"
		local target = open and measure() or 0
		tween(content,0.2,{Size=UDim2.new(1,0,0,target)}):Play()
	end
	if collapsible then setOpen(false) end
	title.Activated:Connect(function() if collapsible then setOpen(not open) end end)

	local secApi = { Instance = content, _container = content }
	function secApi:Label(text) return Controls:Label(self._container, text) end
	function secApi:Button(text, cb) return Controls:Button(self._container, text, cb) end
	function secApi:Toggle(text, def, cb) return Controls:Toggle(self._container, text, def, cb) end
	function secApi:Slider(text, mi, ma, de, st, cb) return Controls:Slider(self._container, text, mi, ma, de, st, cb) end
	function secApi:Dropdown(text,lst,de,cb) return Controls:Dropdown(self._container, text, lst, de, cb) end
	function secApi:MultiDropdown(text,lst,de,cb) return Controls:MultiDropdown(self._container, text, lst, de, cb) end
	function secApi:Textbox(text, ph, de, cb) return Controls:Textbox(self._container, text, ph, de, cb) end
	function secApi:Keybind(label, action, defKC, cb) return Controls:Keybind(self._container, label, action, defKC, cb) end
	function secApi:ColorPicker(text, defC, cb, asset) return Controls:ColorPicker(self._container, text, defC, cb, asset) end

	content.ChildAdded:Connect(function() if open then tween(content,0.12,{Size=UDim2.new(1,0,0,measure())}):Play() end end)
	content.ChildRemoved:Connect(function() if open then tween(content,0.12,{Size=UDim2.new(1,0,0,measure())}):Play() end end)

	return secApi
end

function Controls:Label(container, text)
	local lbl = create("TextLabel", {
		BackgroundTransparency=1, Size=UDim2.new(1,-8,0,isTouch() and 26 or 22), Position=UDim2.fromOffset(8,0),
		Text=text or "", Font=Enum.Font.Gotham, TextColor3=ActiveTheme.SubText, TextSize=14, TextXAlignment=Enum.TextXAlignment.Left, ZIndex=container.ZIndex+1
	})
	lbl.Parent = container
	return { Set=function(_,v) lbl.Text=v end, Instance=lbl }
end

function Controls:Button(container, text, callback)
	local h = isTouch() and 42 or 34
	local btn = create("TextButton", {
		BackgroundColor3=ActiveTheme.Panel, Size=UDim2.new(1,0,0,h), AutoButtonColor=false, Text="", ZIndex=container.ZIndex+1
	}, {
		create("UICorner",{CornerRadius=UDim.new(0,12)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}),
		create("TextLabel",{BackgroundTransparency=1, Size=UDim2.new(1,-14,1,0), Position=UDim2.fromOffset(14,0),
			Text=text or "Button", Font=Enum.Font.GothamSemibold, TextColor3=ActiveTheme.Text, TextSize=14, TextXAlignment=Enum.TextXAlignment.Left })
	})
	btn.Parent = container
	btn.MouseEnter:Connect(function() tween(btn,0.08,{BackgroundColor3=ActiveTheme.Hover}):Play() end)
	btn.MouseLeave:Connect(function() tween(btn,0.12,{BackgroundColor3=ActiveTheme.Panel}):Play() end)
	btn.Activated:Connect(function() if callback then task.spawn(callback) end end)
	return { Instance=btn }
end

function Controls:Toggle(container, text, default, onChanged)
	local h = isTouch() and 42 or 34
	local state = default and true or false
	local root = create("Frame", { BackgroundTransparency=1, Size=UDim2.new(1,0,0,h), ZIndex=container.ZIndex+1 })
	root.Parent = container

	local trackH = isTouch() and 26 or 22
	local trackW = 50
	local pad = 12
	local track = create("TextButton", {
		BackgroundColor3= state and ActiveTheme.Success or ActiveTheme.Track,
		Size=UDim2.fromOffset(trackW, trackH),
		Position=UDim2.fromOffset(pad, (h - trackH)/2 ),
		AutoButtonColor=false, Text="", ZIndex=container.ZIndex+2
	}, { create("UICorner",{CornerRadius=UDim.new(1,0)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	track.Parent = root

	local knobSize = trackH - 4
	local knob = create("Frame", {
		BackgroundColor3=ActiveTheme.Handle, Size=UDim2.fromOffset(knobSize, knobSize),
		Position=UDim2.fromOffset(state and (trackW - knobSize - 2) or 2, 2), BorderSizePixel=0, ZIndex=container.ZIndex+3
	}, { create("UICorner",{CornerRadius=UDim.new(1,0)}) })
	knob.Parent = track

	local title = create("TextButton", {
		BackgroundTransparency=1, Size=UDim2.new(1,-(pad + trackW + 12),1,0), Position=UDim2.fromOffset(pad + trackW + 12,0),
		Text=text or "Toggle", Font=Enum.Font.Gotham, TextColor3=ActiveTheme.Text, TextSize=14,
		TextXAlignment=Enum.TextXAlignment.Left, AutoButtonColor=false, ZIndex=container.ZIndex+2
	})
	title.Parent = root

	local changed = Signal.new()
	local function set(v, fire)
		state = not not v
		tween(track,0.12,{BackgroundColor3= state and ActiveTheme.Success or ActiveTheme.Track}):Play()
		tween(knob,0.12,{Position=UDim2.fromOffset(state and (trackW - knobSize - 2) or 2, 2)}):Play()
		if fire ~= false then
			changed:Fire(state)
			if onChanged then task.spawn(onChanged, state) end
		end
	end
	local function click() set(not state) end
	track.Activated:Connect(click); title.Activated:Connect(click)

	return { Instance=root, Get=function() return state end, Set=set, Changed=changed }
end

function Controls:Slider(container, text, min, max, default, step, onChanged)
	min, max = toNumber(min,0), toNumber(max,100); step = toNumber(step,1)
	local value = clamp(default or min, min, max)
	local h = isTouch() and 56 or 48
	local root = create("Frame", { BackgroundTransparency=1, Size=UDim2.new(1,0,0,h), ZIndex=container.ZIndex+1 })
	root.Parent = container
	local header = create("TextLabel", {
		BackgroundTransparency=1, Size=UDim2.new(1,-12,0,20), Position=UDim2.fromOffset(12,0),
		Text=("%s  (%s)"):format(text or "Slider", tostring(value)), Font=Enum.Font.Gotham,
		TextColor3=ActiveTheme.Text, TextSize=14, TextXAlignment=Enum.TextXAlignment.Left, ZIndex=container.ZIndex+2
	})
	header.Parent = root
	local barH = isTouch() and 10 or 8
	local bar = create("Frame", {
		Name="Bar", BackgroundColor3=ActiveTheme.Track, Size=UDim2.new(1,-24,0,barH), Position=UDim2.fromOffset(12,h-(barH+14)),
		BorderSizePixel=0, ZIndex=container.ZIndex+2
	}, { create("UICorner",{CornerRadius=UDim.new(1,0)}) })
	bar.Parent = root
	local fill = create("Frame", {
		Name="Fill", BackgroundColor3=ActiveTheme.Fill, Size=UDim2.new((value-min)/(max-min),0,1,0),
		BorderSizePixel=0, ZIndex=container.ZIndex+3
	}, { create("UICorner",{CornerRadius=UDim.new(1,0)}) })
	fill.Parent = bar
	local knob = create("Frame", {
		BackgroundColor3=ActiveTheme.Handle, Size=UDim2.fromOffset(isTouch() and 16 or 14, isTouch() and 16 or 14),
		Position=UDim2.new((value-min)/(max-min), -(isTouch() and 8 or 7), 0.5, -(isTouch() and 8 or 7)), BorderSizePixel=0, ZIndex=container.ZIndex+4
	}, { create("UICorner",{CornerRadius=UDim.new(1,0)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	knob.Parent = bar
	local dragging=false
	local changed = Signal.new()
	local function set(v, fire)
		v = toNumber(v, value); v = clamp(round(v, step), min, max); value = v
		header.Text = ("%s  (%s)"):format(text or "Slider", tostring(value))
		local a = (value-min)/(max-min)
		tween(fill,0.08,{Size=UDim2.new(a,0,1,0)}):Play(); tween(knob,0.08,{Position=UDim2.new(a, -(isTouch() and 8 or 7), 0.5, -(isTouch() and 8 or 7))}):Play()
		if fire ~= false then changed:Fire(value); if onChanged then task.spawn(onChanged, value) end end
	end
	local function toValue(px) local abs = bar.AbsoluteSize.X; local rel = clamp(px / math.max(1,abs), 0,1); return min + rel*(max-min) end
	local function updateFromInput(input) local pos = input.Position.X - bar.AbsolutePosition.X; set(toValue(pos)) end
	bar.InputBegan:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then dragging=true; updateFromInput(input) end end)
	bar.InputEnded:Connect(function(input) if input.UserInputType~=Enum.UserInputType.MouseMovement then dragging=false end end)
	UserInput.InputChanged:Connect(function(input) if dragging and (input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch) then updateFromInput(input) end end)
	return { Instance=root, Get=function() return value end, Set=set, Changed=changed }
end

-- Dropdown builder
local function buildDropdownMenu(root, overlay, items, actionRowBuilder)
	local menu = create("Frame", {
		BackgroundColor3=ActiveTheme.DropdownBg, BorderSizePixel=0, ZIndex=1000, Size=UDim2.fromOffset(root.AbsoluteSize.X, 0),
		Position=UDim2.fromOffset(root.AbsolutePosition.X, root.AbsolutePosition.Y + root.AbsoluteSize.Y), ClipsDescendants=true
	}, { create("UICorner",{CornerRadius=UDim.new(0,12)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	menu.Parent = overlay

	local y = 6
	if actionRowBuilder then
		local row = actionRowBuilder(menu)
		if row then row.Position = UDim2.fromOffset(6,6); y = y + row.Size.Y.Offset + 6 end
	end

	local listFrame = create("Frame", { BackgroundTransparency=1, Size=UDim2.new(1, -12, 1, -y-6), Position=UDim2.fromOffset(6,y) })
	listFrame.Parent = menu
	local layout = create("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6)}); layout.Parent = listFrame

	for _, item in ipairs(items) do
		local opt = create("TextButton", {
			BackgroundColor3=ActiveTheme.Panel, Size=UDim2.new(1,0,0,isTouch() and 36 or 30),
			Text=item, Font=Enum.Font.Gotham, TextColor3=ActiveTheme.Text, TextSize=14, AutoButtonColor=false, ZIndex=1001
		}, { create("UICorner",{CornerRadius=UDim.new(0,10)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
		opt.Parent = listFrame
		opt.MouseEnter:Connect(function() tween(opt,0.08,{BackgroundColor3=ActiveTheme.Hover}):Play() end)
		opt.MouseLeave:Connect(function() tween(opt,0.12,{BackgroundColor3=ActiveTheme.Panel}):Play() end)
	end

	local height = math.clamp(#items * ((isTouch() and 36 or 30) + 6) + y + 12, 120, 320)
	tween(menu,0.12,{Size=UDim2.fromOffset(root.AbsoluteSize.X, height)}):Play()
	return menu
end

function Controls:Dropdown(container, text, list, default, onChanged)
	list = list or {}; local current = default or (list[1] or "")
	local h = isTouch() and 42 or 34
	local root = create("Frame", { Name="Dropdown", BackgroundColor3=ActiveTheme.Panel, Size=UDim2.new(1,0,0,h), BorderSizePixel=0, ZIndex=container.ZIndex+1 }, {
		create("UICorner",{CornerRadius=UDim.new(0,12)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	root.Parent = container
	local btn = create("TextButton", { BackgroundTransparency=1, Size=UDim2.new(1,-12,1,0), Position=UDim2.fromOffset(12,0), Text="", AutoButtonColor=false })
	btn.Parent = root
	local label = create("TextLabel", {
		BackgroundTransparency=1, Size=UDim2.new(1,-24,1,0),
		Text=("%s: %s"):format(text or "Select", tostring(current)), Font=Enum.Font.Gotham, TextColor3=ActiveTheme.Text, TextSize=14, TextXAlignment=Enum.TextXAlignment.Left
	})
	label.Parent = btn
	local arrow = create("TextLabel", { BackgroundTransparency=1, Size=UDim2.fromOffset(20,20), Position=UDim2.new(1,-22,0.5,-10), Text="▼", Font=Enum.Font.GothamBold, TextColor3=ActiveTheme.SubText, TextSize=14 })
	arrow.Parent = btn

	local screen = container:FindFirstAncestorOfClass("ScreenGui")
	local overlay = screen and screen:FindFirstChild("Overlay")

	local function openMenu()
		if not overlay then return end
		openOverlay(overlay)
		local menu = buildDropdownMenu(root, overlay, list, nil)
		for _,child in ipairs(menu:GetDescendants()) do
			if child:IsA("TextButton") and child.Text ~= "" then
				child.Activated:Connect(function()
					current = child.Text
					label.Text = ("%s: %s"):format(text or "Select", tostring(current))
					if onChanged then task.spawn(onChanged, current) end
					tween(menu,0.12,{Size=UDim2.fromOffset(menu.Size.X.Offset, 0)}):Play(); task.delay(0.12, function() closeOverlay(overlay) end)
				end)
			end
		end
		overlay.InputBegan:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType==Enum.UserInputType.Touch then
				tween(menu,0.12,{Size=UDim2.fromOffset(menu.Size.X.Offset, 0)}):Play(); task.delay(0.12, function() closeOverlay(overlay) end)
			end
		end)
	end
	btn.Activated:Connect(openMenu)

	return {
		Instance=root,
		Get=function() return current end,
		Set=function(_,v) if table.find(list,v) then current=v; label.Text=("%s: %s"):format(text or "Select", tostring(current)) end end,
		SetItems=function(_,newList) list=newList or {} end,
		Open=openMenu, Close=function() if overlay then closeOverlay(overlay) end end,
	}
end

function Controls:MultiDropdown(container, text, list, defaultTable, onChanged)
	list = list or {}; local selected = {}; if typeof(defaultTable)=="table" then for _,v in ipairs(defaultTable) do selected[v]=true end end
	local h = isTouch() and 42 or 34
	local root = create("Frame", { Name="MultiDropdown", BackgroundColor3=ActiveTheme.Panel, Size=UDim2.new(1,0,0,h), BorderSizePixel=0, ZIndex=container.ZIndex+1 }, {
		create("UICorner",{CornerRadius=UDim.new(0,12)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	root.Parent = container
	local btn = create("TextButton", { BackgroundTransparency=1, Size=UDim2.new(1,-12,1,0), Position=UDim2.fromOffset(12,0), Text="", AutoButtonColor=false })
	btn.Parent = root

	local function summary()
		local t = {}
		for _,v in ipairs(list) do if selected[v] then table.insert(t, v) end end
		if #t==0 then return "None" end
		if #t<=3 then return table.concat(t, ", ") end
		return ("%d selected"):format(#t)
	end
	local label = create("TextLabel", {
		BackgroundTransparency=1, Size=UDim2.new(1,-24,1,0),
		Text=("%s: %s"):format(text or "Select", summary()), Font=Enum.Font.Gotham, TextColor3=ActiveTheme.Text, TextSize=14, TextXAlignment=Enum.TextXAlignment.Left
	})
	label.Parent = btn
	local arrow = create("TextLabel", { BackgroundTransparency=1, Size=UDim2.fromOffset(20,20), Position=UDim2.new(1,-22,0.5,-10), Text="▼", Font=Enum.Font.GothamBold, TextColor3=ActiveTheme.SubText, TextSize=14 })
	arrow.Parent = btn

	local screen = container:FindFirstAncestorOfClass("ScreenGui")
	local overlay = screen and screen:FindFirstChild("Overlay")

	local function fireChanged()
		local arr = {}; for _,v in ipairs(list) do if selected[v] then table.insert(arr, v) end end
		if onChanged then task.spawn(onChanged, arr) end
		label.Text = ("%s: %s"):format(text or "Select", summary())
	end

	local function openMenu()
		if not overlay then return end
		openOverlay(overlay)

		local function pills(parent)
			local row = create("Frame", { BackgroundTransparency=1, Size=UDim2.fromOffset(root.AbsoluteSize.X-12, isTouch() and 34 or 28) })
			row.Parent = parent
			local pill = function(txt, cb)
				local b = create("TextButton", { BackgroundColor3=ActiveTheme.Accent, Text=txt, TextColor3=ActiveTheme.Text, TextSize=13, AutoButtonColor=false,
					Size=UDim2.fromOffset(90, row.Size.Y.Offset) }, { create("UICorner",{CornerRadius=UDim.new(1,0)}) })
				b.MouseEnter:Connect(function() tween(b,0.08,{BackgroundColor3=ActiveTheme.AccentHover}):Play() end)
				b.MouseLeave:Connect(function() tween(b,0.12,{BackgroundColor3=ActiveTheme.Accent}):Play() end)
				b.Activated:Connect(cb)
				return b
			end
			local selectAll = pill("Select all", function() for _,item in ipairs(list) do selected[item]=true end; fireChanged() end)
			selectAll.Parent = row; selectAll.Position = UDim2.fromOffset(0,0)
			local clear = pill("Clear", function() selected = {}; fireChanged() end)
			clear.Parent = row; clear.Position = UDim2.fromOffset(100,0)
			return row
		end

		local menu = buildDropdownMenu(root, overlay, list, pills)

		for _,child in ipairs(menu:GetDescendants()) do
			if child:IsA("TextButton") and child.Text ~= "" and (child.Text ~= "Select all" and child.Text ~= "Clear") then
				local row = child
				local chk = create("Frame", { BackgroundColor3=ActiveTheme.Track, Size=UDim2.fromOffset(18,18), Position=UDim2.fromOffset(8,(row.Size.Y.Offset-18)/2), BorderSizePixel=0 }, { create("UICorner",{CornerRadius=UDim.new(0,4)}) })
				chk.Parent = row
				local lbl = row:FindFirstChildOfClass("TextLabel"); if lbl then lbl.Position = UDim2.fromOffset(34,0); lbl.Size = UDim2.new(1,-40,1,0) end

				local function refresh()
					tween(chk,0.1,{BackgroundColor3 = selected[row.Text] and ActiveTheme.Accent or ActiveTheme.Track}):Play()
				end
				refresh()

				row.Activated:Connect(function()
					selected[row.Text] = not selected[row.Text]
					refresh(); fireChanged()
				end)
			end
		end

		overlay.InputBegan:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType==Enum.UserInputType.Touch then
				tween(menu,0.12,{Size=UDim2.fromOffset(menu.Size.X.Offset, 0)}):Play(); task.delay(0.12, function() closeOverlay(overlay) end)
			end
		end)
	end
	btn.Activated:Connect(openMenu)

	return {
		Instance=root,
		Get=function() local arr={} for _,v in ipairs(list) do if selected[v] then table.insert(arr,v) end end return arr end,
		Set=function(_,arr) selected = {}; if typeof(arr)=="table" then for _,v in ipairs(arr) do selected[v]=true end end; fireChanged() end,
		SetItems=function(_,newList) list=newList or {} end,
		Open=openMenu, Close=function() if overlay then closeOverlay(overlay) end end,
	}
end

function Controls:Textbox(container, text, placeholder, default, onChanged)
	local h = isTouch() and 42 or 34
	local root = create("Frame", { Name="Textbox", BackgroundColor3=ActiveTheme.Panel, Size=UDim2.new(1,0,0,h), BorderSizePixel=0, ZIndex=container.ZIndex+1 }, {
		create("UICorner",{CornerRadius=UDim.new(0,12)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	root.Parent = container
	local label = create("TextLabel", { BackgroundTransparency=1, Size=UDim2.new(0,120,1,0), Position=UDim2.fromOffset(12,0),
		Text=text or "Text", Font=Enum.Font.Gotham, TextColor3=ActiveTheme.Text, TextSize=14, TextXAlignment=Enum.TextXAlignment.Left })
	label.Parent = root
	local box = create("TextBox", {
		BackgroundTransparency=1, Size=UDim2.new(1,-140,1,0), Position=UDim2.new(0,132,0,0),
		PlaceholderText=placeholder or "", Text=default or "", Font=Enum.Font.Gotham, TextColor3=ActiveTheme.Text, TextSize=14, ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Left
	})
	box.Parent = root
	box.FocusLost:Connect(function(enter) if onChanged then task.spawn(onChanged, box.Text, enter) end end)
	return { Instance=root, Get=function() return box.Text end, Set=function(_,v) box.Text=tostring(v) end }
end

function Controls:Keybind(container, labelText, actionName, defaultKeyCode, onChanged)
	local h = isTouch() and 42 or 34
	local root = create("Frame", { BackgroundColor3=ActiveTheme.Panel, Size=UDim2.new(1,0,0,h), BorderSizePixel=0, ZIndex=container.ZIndex+1 }, {
		create("UICorner",{CornerRadius=UDim.new(0,12)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	root.Parent = container
	local label = create("TextLabel", { BackgroundTransparency=1, Size=UDim2.new(1,-120,1,0), Position=UDim2.fromOffset(12,0),
		Text=labelText or "Keybind", Font=Enum.Font.Gotham, TextColor3=ActiveTheme.Text, TextSize=14, TextXAlignment=Enum.TextXAlignment.Left })
	label.Parent = root
	local kbBtn = create("TextButton", { BackgroundTransparency=1, Size=UDim2.new(0,110,1,0), Position=UDim2.new(1,-114,0,0), Text="", AutoButtonColor=false })
	kbBtn.Parent = root
	local pill = create("TextLabel", { BackgroundColor3=ActiveTheme.Hover, Size=UDim2.fromOffset(100,26), Position=UDim2.new(1,-105,0.5,-13),
		Text = defaultKeyCode and defaultKeyCode.Name or "None", Font=Enum.Font.GothamSemibold, TextColor3=ActiveTheme.Text, TextSize=13 }, {
		create("UICorner",{CornerRadius=UDim.new(1,0)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	pill.Parent = root
	local listening=false
	kbBtn.Activated:Connect(function()
		if listening then return end; listening=true; pill.Text = "Press key"
		local conn; conn = UserInput.InputBegan:Connect(function(input)
			if input.UserInputType==Enum.UserInputType.Keyboard then
				listening=false; pill.Text = input.KeyCode.Name
				if onChanged then task.spawn(onChanged, input.KeyCode) end
				setKeybind(actionName, input.KeyCode, Keybinds[actionName] and Keybinds[actionName].callback or nil, false)
				if conn then conn:Disconnect() end
			end
		end)
	end)
	if defaultKeyCode then pill.Text = defaultKeyCode.Name; if not Keybinds[actionName] then setKeybind(actionName, defaultKeyCode, nil, false) end end
	return {
		Instance=root, Set=function(_,kc) pill.Text = kc and kc.Name or "None"; setKeybind(actionName, kc, Keybinds[actionName] and Keybinds[actionName].callback or nil, false); if onChanged then task.spawn(onChanged, kc) end end,
		Get=function() return Keybinds[actionName] and Keybinds[actionName].keycode or nil end, ActionName=actionName
	}
end

local DefaultWheelAsset = "rbxassetid://14333615534"
function Controls:ColorPicker(container, text, defaultColor, onChanged, wheelAssetId)
	wheelAssetId = wheelAssetId or DefaultWheelAsset
	local root = create("Frame", { BackgroundColor3=ActiveTheme.Panel, Size=UDim2.new(1,0,0,190), BorderSizePixel=0, ZIndex=container.ZIndex+1 }, {
		create("UICorner",{CornerRadius=UDim.new(0,12)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}),
		create("UIPadding",{PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,8)})
	})
	root.Parent = container
	local title = create("TextLabel", { BackgroundTransparency=1, Size=UDim2.new(1,0,0,18), Position=UDim2.fromOffset(0,0),
		Text=text or "Color", Font=Enum.Font.Gotham, TextColor3=ActiveTheme.Text, TextSize=14, TextXAlignment=Enum.TextXAlignment.Left })
	title.Parent = root

	local init = defaultColor or Color3.new(1,1,1); local h,s,v = Color3.toHSV(init)

	local wheel = create("ImageLabel", {
		BackgroundTransparency=1, Size=UDim2.fromOffset(124,124), Position=UDim2.fromOffset(0,24),
		Image = wheelAssetId
	})
	wheel.Parent = root
	local cursor = create("Frame", { Size=UDim2.fromOffset(10,10), BackgroundColor3=ActiveTheme.Handle, BorderSizePixel=0, ZIndex=root.ZIndex+3 },
	{ create("UICorner",{CornerRadius=UDim.new(1,0)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	cursor.Parent = wheel

	local vbarH = 16
	local vbar = create("Frame", { BackgroundColor3 = ActiveTheme.Track, Size=UDim2.fromOffset(124, vbarH), Position=UDim2.fromOffset(0,152), BorderSizePixel=0 })
	vbar.Parent = root; create("UICorner",{CornerRadius=UDim.new(0,8)}).Parent=vbar
	local vfill = create("Frame", { BackgroundColor3=ActiveTheme.Fill, Size=UDim2.fromOffset(vbar.AbsoluteSize.X * v, vbarH), BorderSizePixel=0 })
	vfill.Parent = vbar; create("UICorner",{CornerRadius=UDim.new(0,8)}).Parent=vfill

	local preview = create("Frame", { Size=UDim2.fromOffset(28,28), Position=UDim2.fromOffset(136,24), BackgroundColor3=init, BorderSizePixel=0 }, { create("UICorner",{CornerRadius=UDim.new(0,8)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	preview.Parent = root

	local function wheelCenter() return wheel.AbsolutePosition + wheel.AbsoluteSize/2 end
	local function setCursorFromHS()
		local center = wheelCenter(); local r = math.min(wheel.AbsoluteSize.X, wheel.AbsoluteSize.Y)/2 - 6
		local ang = h * math.pi * 2
		local x = center.X + math.cos(ang) * r * s
		local y = center.Y + math.sin(ang) * r * s
		cursor.Position = UDim2.fromOffset(x - wheel.AbsolutePosition.X - 5, y - wheel.AbsolutePosition.Y - 5)
	end

	local function apply(fire)
		local col = h2rgb(h,s,v)
		preview.BackgroundColor3 = col
		if fire and onChanged then task.spawn(onChanged, col, h, s, v) end
		return col
	end

	task.defer(function()
		setCursorFromHS()
		vfill.Size = UDim2.fromOffset(vbar.AbsoluteSize.X * v, vbarH)
		apply(false)
	end)

	local draggingWheel=false
	wheel.InputBegan:Connect(function(input)
		if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
			draggingWheel=true
		end
	end)
	wheel.InputEnded:Connect(function() draggingWheel=false end)
	UserInput.InputChanged:Connect(function(input)
		if draggingWheel and (input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch) then
			local center = wheelCenter()
			local dx = input.Position.X - center.X
			local dy = input.Position.Y - center.Y
			local dist = math.sqrt(dx*dx + dy*dy)
			local radius = math.min(wheel.AbsoluteSize.X, wheel.AbsoluteSize.Y)/2 - 6
			s = clamp(dist / radius, 0, 1)
			local angle = math.atan2(dy, dx)
			h = (angle / (2*math.pi)) % 1
			setCursorFromHS()
			apply(true)
		end
	end)

	local draggingV=false
	vbar.InputBegan:Connect(function(input)
		if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then draggingV=true end
	end)
	vbar.InputEnded:Connect(function() draggingV=false end)
	UserInput.InputChanged:Connect(function(input)
		if draggingV and (input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch) then
			local x = clamp(input.Position.X - vbar.AbsolutePosition.X, 0, vbar.AbsoluteSize.X)
			v = x / math.max(1, vbar.AbsoluteSize.X)
			vfill.Size = UDim2.fromOffset(x, vbarH)
			apply(true)
		end
	end)

	return {
		Instance=root,
		Get=function() return h2rgb(h,s,v), h,s,v end,
		Set=function(_, color3) local H,S,V = Color3.toHSV(color3); h,s,v=H,S,V; setCursorFromHS(); vfill.Size=UDim2.fromOffset(vbar.AbsoluteSize.X*v, vbarH); apply(true) end
	}
end

--// Window / Tabs
local Window, Tab = {}, {}
Window.__index = Window
Tab.__index = Tab

function ProUI.new(opts)
	opts = opts or {}
	local id       = opts.id or "default"
	local title    = opts.title or "ProUI"
	local size     = opts.size or Vector2.new(600, 500)
	local position = opts.position or Vector2.new(100, 100)
	local enableSaving = opts.save ~= false
	local noticePos = (opts.noticePosition or "top_right"):lower()
	local themeName = opts.theme or "Midnight Slate"
	local canClose = false -- minimize-only

	if Themes[themeName] then ActiveTheme = cloneTheme(Themes[themeName]) end
	local saved = enableSaving and Save:Load(id, {}) or {}

	local screen, overlay = createScreenGui(("ProUI_%s"):format(id))

	local root = create("Frame", {
		Name="Window", BackgroundColor3=ActiveTheme.Bg, Position=UDim2.fromOffset(position.X, position.Y),
		Size=UDim2.fromOffset(size.X, size.Y), BorderSizePixel=0, ZIndex=10
	}, {
		create("UICorner",{CornerRadius=UDim.new(0,14)}),
		create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}),
		create("Frame", { Name="TopBar", BackgroundColor3=ActiveTheme.Surface, BorderSizePixel=0, Size=UDim2.new(1,0,0,46), ZIndex=11 }, {
			create("UICorner",{CornerRadius=UDim.new(0,14)}),
			create("TextLabel", { Name="Title", BackgroundTransparency=1, Position=UDim2.fromOffset(14,0), Size=UDim2.new(1,-80,1,0),
				Text=title, Font=Enum.Font.GothamSemibold, TextColor3=ActiveTheme.Text, TextSize=16, TextXAlignment=Enum.TextXAlignment.Left }),
			create("TextButton", { Name="Minimize", BackgroundTransparency=1, Size=UDim2.fromOffset(46,46), Position=UDim2.new(1,-46,0,0),
				Text="–", Font=Enum.Font.GothamBold, TextSize=22, TextColor3=ActiveTheme.SubText, AutoButtonColor=false })
		}),
		create("Frame", { Name="Sidebar", BackgroundColor3=ActiveTheme.Surface, BorderSizePixel=0, Position=UDim2.fromOffset(0,46), Size=UDim2.new(0,168,1,-46), ZIndex=11 }, {
			create("UICorner",{CornerRadius=UDim.new(0,14)}),
			create("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6)}),
			create("UIPadding",{PaddingTop=UDim.new(0,10), PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), PaddingBottom=UDim.new(0,10)})
		}),
		create("Frame", { Name="Content", BackgroundTransparency=1, Position=UDim2.fromOffset(168,46), Size=UDim2.new(1,-168,1,-46), ZIndex=11 }),
		create("Frame", { Name="Grip", BackgroundTransparency=1, Size=UDim2.fromOffset(18,18), Position=UDim2.new(1,-18,1,-18), ZIndex=13 })
	})
	root.Parent = screen

	local restore = create("TextButton", { Name="Restore", BackgroundColor3=ActiveTheme.Surface, Text="☰", TextColor3=ActiveTheme.Text, TextSize=18,
		Size=UDim2.fromOffset(36,36), Position=UDim2.new(0,12,0,GuiService:GetGuiInset().Y + 12), Visible=false, ZIndex=50, AutoButtonColor=false }, {
		create("UICorner",{CornerRadius=UDim.new(1,0)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
	restore.Parent = screen

	-- Drag
	local dragging=false; local dragStart; local startPos
	root.TopBar.InputBegan:Connect(function(input)
		if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
			dragging=true; dragStart=input.Position; startPos=root.Position
			input.Changed:Connect(function() if input.UserInputState==Enum.UserInputState.End then dragging=false end end)
		end
	end)
	root.TopBar.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			root.Position = UDim2.fromOffset(startPos.X.Offset + d.X, startPos.Y.Offset + d.Y)
		end
	end)

	-- Resize
	local resizing=false; local sizeStart; local mouseStart
	root.Grip.InputBegan:Connect(function(input)
		if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
			resizing=true; mouseStart=input.Position; sizeStart=root.Size
			input.Changed:Connect(function() if input.UserInputState==Enum.UserInputState.End then resizing=false end end)
		end
	end)
	UserInput.InputChanged:Connect(function(input)
		if resizing and (input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch) then
			local dx = input.Position.X - mouseStart.X; local dy = input.Position.Y - mouseStart.Y
			local w = sizeStart.X.Offset + dx; local h = sizeStart.Y.Offset + dy
			root.Size = UDim2.fromOffset(math.max(440,w), math.max(300,h))
		end
	end)

	local api = setmetatable({
		_id=id, _screen=screen, _overlay=overlay, _root=root, _tabs={}, _active=nil,
		_saved=saved, _enableSaving=enableSaving, _noticePos=noticePos, _min=false,
		OnClosed = Signal.new(),
	}, ProUI)

	if enableSaving and saved.window then
		local p,s,m = saved.window.pos, saved.window.size, saved.window.min
		if p and #p==2 then root.Position = UDim2.fromOffset(p[1], p[2]) end
		if s and #s==2 then root.Size     = UDim2.fromOffset(s[1], s[2]) end
		api._min = m==true
		if api._min then root.Sidebar.Visible=false; root.Content.Visible=false; root.Size=UDim2.fromOffset(root.Size.X.Offset, 46); restore.Visible=true end
	end

	local function saveWin()
		if not enableSaving then return end
		saved.window = saved.window or {}
		saved.window.pos = { root.Position.X.Offset, root.Position.Y.Offset }
		saved.window.size = { root.Size.X.Offset, root.Size.Y.Offset }
		saved.window.min  = api._min
		Save:Save(id, saved)
	end

	local function repaintTree(gui)
		for _, inst in ipairs(gui:GetDescendants()) do
			if inst:IsA("Frame") or inst:IsA("TextButton") or inst:IsA("TextLabel") or inst:IsA("ScrollingFrame") then
				if inst.Name == "TopBar" or inst.Name == "Sidebar" then
					if inst:IsA("Frame") then inst.BackgroundColor3 = ActiveTheme.Surface end
				elseif inst.Name == "Window" then
					inst.BackgroundColor3 = ActiveTheme.Bg
				elseif inst:IsA("TextButton") and inst.Name == "TabButton" then
					inst.BackgroundColor3 = ActiveTheme.Panel
					local stroke = inst:FindFirstChildOfClass("UIStroke"); if stroke then stroke.Color = ActiveTheme.Stroke end
					local tl = inst:FindFirstChildWhichIsA("TextLabel"); if tl then tl.TextColor3 = ActiveTheme.Text end
				elseif inst.Name == "Dropdown" or inst.Name == "Textbox" or inst.Name=="MultiDropdown" or inst.Name=="SectionHead" then
					if inst:IsA("Frame") then
						inst.BackgroundColor3 = ActiveTheme.Panel
						local stroke = inst:FindFirstChildOfClass("UIStroke"); if stroke then stroke.Color = ActiveTheme.Stroke end
					end
				elseif inst.Name == "Bar" then
					inst.BackgroundColor3 = ActiveTheme.Track
				elseif inst.Name == "Fill" then
					inst.BackgroundColor3 = ActiveTheme.Fill
				end
			elseif inst:IsA("UIStroke") then
				inst.Color = ActiveTheme.Stroke
			end
		end
		root.TopBar.BackgroundColor3 = ActiveTheme.Surface
		root.BackgroundColor3 = ActiveTheme.Bg
		restore.BackgroundColor3 = ActiveTheme.Surface
		local rst = restore:FindFirstChildOfClass("UIStroke"); if rst then rst.Color = ActiveTheme.Stroke end
	end

	root.TopBar.Minimize.Activated:Connect(function()
		api._min = not api._min
		if api._min then
			tween(root,0.15,{Size=UDim2.fromOffset(root.Size.X.Offset, 46)}):Play()
			root.Sidebar.Visible=false; root.Content.Visible=false; restore.Visible=true
		else
			root.Sidebar.Visible=true; root.Content.Visible=true; restore.Visible=false
			tween(root,0.15,{Size=UDim2.fromOffset(saved.window and saved.window.size and saved.window.size[1] or size.X,
				saved.window and saved.window.size and saved.window.size[2] or size.Y)}):Play()
		end
		saveWin()
	end)
	restore.Activated:Connect(function() if api._min then root.TopBar.Minimize:Activate() else screen.Enabled = true end end)

	function api:Notification(text, kind, seconds)
		kind = (kind=="warn" and "warn") or (kind=="error" and "error") or "info"
		seconds = seconds or 3
		local color = (kind=="warn" and ActiveTheme.Warning) or (kind=="error" and ActiveTheme.Error) or ActiveTheme.Accent
		local bar = create("Frame", { BackgroundColor3=color, Size=UDim2.new(0,0,0,36), BorderSizePixel=0, ZIndex=205 }, {
			create("UICorner",{CornerRadius=UDim.new(0,12)}),
			create("TextLabel", { BackgroundTransparency=1, Size=UDim2.new(1,-16,1,0), Position=UDim2.fromOffset(8,0),
				Text=text or "", Font=Enum.Font.GothamSemibold, TextColor3=Color3.new(1,1,1), TextSize=14, TextXAlignment=Enum.TextXAlignment.Left })
		})
		bar.Parent = self._screen

		local list = self._screen:FindFirstChild("__noticeList") or create("Folder",{Name="__noticeList"})
		list.Parent = self._screen
		local function anchor()
			local pad=10; local height=36; local gap=8
			local idx = #list:GetChildren()
			local inset = GuiService:GetGuiInset().Y
			local yOffset = (height + gap) * (idx - 1)
			if self._noticePos=="top_left" then
				bar.Position = UDim2.fromOffset(pad, pad + inset + yOffset)
			elseif self._noticePos=="top_right" then
				bar.Position = UDim2.new(1, -(340+pad), 0, pad + inset + yOffset)
			elseif self._noticePos=="bottom_left" then
				bar.Position = UDim2.new(0, pad, 1, -(pad + height + yOffset))
			else
				bar.Position = UDim2.new(1, -(340+pad), 1, -(pad + height + yOffset))
			end
		end
		bar.Parent = list; anchor()
		tween(bar,0.15,{Size=UDim2.new(0,340,0,36)}):Play()
		task.delay(seconds, function()
			tween(bar,0.15,{Size=UDim2.new(0,0,0,36)}):Play()
			task.delay(0.16, function() if bar then bar:Destroy() end end)
		end)
	end

	function api:Tab(name)
		name = name or ("Tab %d"):format(#self._tabs + 1)
		local tabBtn = create("TextButton", {
			Name="TabButton", BackgroundColor3=ActiveTheme.Panel, Size=UDim2.new(1,0,0,isTouch() and 40 or 34), AutoButtonColor=false, Text=name,
			Font=Enum.Font.Gotham, TextColor3=ActiveTheme.Text, TextSize=14, ZIndex=12
		}, { create("UICorner",{CornerRadius=UDim.new(0,12)}), create("UIStroke",{Color=ActiveTheme.Stroke, Thickness=1}) })
		tabBtn.Parent = root.Sidebar
		tabBtn.MouseEnter:Connect(function() tween(tabBtn,0.08,{BackgroundColor3=ActiveTheme.Hover}):Play() end)
		tabBtn.MouseLeave:Connect(function() if self._active ~= tabBtn then tween(tabBtn,0.12,{BackgroundColor3=ActiveTheme.Panel}):Play() end end)

		local scroll = create("ScrollingFrame", {
			Active=true, BackgroundTransparency=1, BorderSizePixel=0, ScrollBarThickness=isTouch() and 8 or 6,
			CanvasSize=UDim2.new(0,0,0,0), Size=UDim2.new(1,-20,1,-20), Position=UDim2.fromOffset(10,10),
			Visible=false, ZIndex=12, ClipsDescendants=false
		}, {
			create("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,8)}),
			create("UIPadding",{PaddingTop=UDim.new(0,6), PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,6), PaddingBottom=UDim.new(0,6)})
		})
		scroll.Parent = root.Content

		local function recalc()
			local layout=scroll:FindFirstChildOfClass("UIListLayout")
			local total, pad=0,(layout and layout.Padding.Offset or 8)
			for _,c in ipairs(scroll:GetChildren()) do if c:IsA("GuiObject") and c.Visible then total += c.AbsoluteSize.Y + pad end end
			scroll.CanvasSize = UDim2.new(0,0,0,math.max(0,total))
		end
		scroll.ChildAdded:Connect(recalc); scroll.ChildRemoved:Connect(recalc); scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(recalc)

		local tabApi = setmetatable({ _window=self, _btn=tabBtn, _content=scroll, _name=name }, Tab)
		function tabApi:Show()
			for _,t in ipairs(self._window._tabs) do
				t._content.Visible=false; tween(t._btn,0.12,{BackgroundColor3=ActiveTheme.Panel}):Play()
			end
			self._content.Visible=true; tween(self._btn,0.12,{BackgroundColor3=ActiveTheme.Hover}):Play()
			self._window._active = self._btn; recalc()
		end

		function tabApi:Section(label, collapsible, tip) return Controls:Section(self._content, label, collapsible, tip) end
		function tabApi:Label(text)                      return Controls:Label(self._content, text) end
		function tabApi:Button(text, cb)                 return Controls:Button(self._content, text, cb) end
		function tabApi:Toggle(text, def, cb)            return Controls:Toggle(self._content, text, def, cb) end
		function tabApi:Slider(text, mi, ma, de, st, cb) return Controls:Slider(self._content, text, mi, ma, de, st, cb) end
		function tabApi:Dropdown(text, list, de, cb)     return Controls:Dropdown(self._content, text, list, de, cb) end
		function tabApi:MultiDropdown(text,lst,de,cb)    return Controls:MultiDropdown(self._content, text, lst, de, cb) end
		function tabApi:Textbox(text, ph, de, cb)        return Controls:Textbox(self._content, text, ph, de, cb) end
		function tabApi:Keybind(label, action, defKC, cb) return Controls:Keybind(self._content, label, action, defKC, cb) end
		function tabApi:ColorPicker(text, defC, cb, asset) return Controls:ColorPicker(self._content, text, defC, cb, asset or self._window._colorWheelAsset) end

		tabBtn.Activated:Connect(function() tabApi:Show() end)
		table.insert(self._tabs, tabApi)
		if #self._tabs==1 then tabApi:Show() end
		return tabApi
	end

	function api:LoadState(key, default) if not self._enableSaving then return default end; local st=self._saved.state or {}; return st[key]~=nil and st[key] or default end
	function api:SaveState(key, value) if not self._enableSaving then return end; self._saved.state=self._saved.state or {}; self._saved.state[key]=value; Save:Save(self._id, self._saved) end

	function api:BindAction(name, keycode, callback, allowGameProcessed) setKeybind(name, keycode, callback, allowGameProcessed) end
	function api:RebindAction(name, keycode) if Keybinds[name] then Keybinds[name].keycode = keycode end end
	function api:UnbindAction(name) removeKeybind(name) end
	function api:ToggleUI() self._screen.Enabled = not self._screen.Enabled end

	function api:GetThemes() local t={}; for k in pairs(Themes) do table.insert(t,k) end; table.sort(t); return t end
	function api:ApplyTheme(name) if not Themes[name] then return false end; ActiveTheme = cloneTheme(Themes[name]); repaintTree(self._root); return true end
	function api:RefreshTheme() repaintTree(self._root) end

	function api:SetColorWheelAsset(assetId) self._colorWheelAsset = assetId end

	if UserInput.KeyboardEnabled then setKeybind("ToggleUI", Enum.KeyCode.RightControl, function() api:ToggleUI() end, true) end

	return api
end

return ProUI
