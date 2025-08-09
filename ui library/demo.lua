-- ProUI v1.5.1 — Docs Demo (Midnight Slate)
local ProUI = require(game.ReplicatedStorage:WaitForChild("ProUI"))
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local LP = Players.LocalPlayer

local function getChar()
	local char = LP.Character or LP.CharacterAdded:Wait()
	return char, char:FindFirstChildOfClass("Humanoid"), char:FindFirstChild("HumanoidRootPart")
end
local function setWalkSpeed(v) local _,hum = getChar(); if hum then hum.WalkSpeed = v end end
local function setJumpPower(v) local _,hum = getChar(); if hum then hum.UseJumpPower = true; hum.JumpPower = v end end
local function setGravity(v) workspace.Gravity = v end

local ui = ProUI.new({
	id="docs_v151",
	title="Proton Tools — ProUI v1.5.1",
	size=Vector2.new(760,580),
	position=Vector2.new(120,120),
	save=true,
	theme="Midnight Slate",
	noticePosition="top_right",
})

-- Optional: supply your own HQ color wheel image
-- ui:SetColorWheelAsset("rbxassetid://YOUR_ASSET_ID")

ui:Notification("Loaded ProUI v1.5.1", "info", 2)

local main   = ui:Tab("Main")
local player = ui:Tab("Player")
local world  = ui:Tab("World")
local uiux   = ui:Tab("UI/UX")
local binds  = ui:Tab("Keybinds")
local theme  = ui:Tab("Themes")

-- MAIN
local secMain = main:Section("Overview", true, "Click to expand/collapse")
secMain:Label("Status: Ready")
secMain:Button("Hello", function() print("Hello from ProUI v1.5.1"); ui:Notification("Printed to output", "info", 1.1) end)

-- PLAYER
local secMove = player:Section("Movement", false)
local baseSpeed = ui:LoadState("speed", 16); setWalkSpeed(baseSpeed)
local spd = secMove:Slider("WalkSpeed", 8, 300, baseSpeed, 1, function(v) ui:SaveState("speed", v); setWalkSpeed(v) end)
local jmp = secMove:Slider("JumpPower", 20, 200, ui:LoadState("jump", 50), 1, function(v) ui:SaveState("jump", v); setJumpPower(v) end)

local secAbilities = player:Section("Abilities", false)
local noclipLoop
local noclipT = secAbilities:Toggle("NoClip", ui:LoadState("noclip", false), function(on)
	ui:SaveState("noclip", on)
	if on and not noclipLoop then
		noclipLoop = RunService.Stepped:Connect(function()
			local char = LP.Character
			if not char then return end
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then part.CanCollide = false end
			end
		end)
	elseif not on and noclipLoop then noclipLoop:Disconnect(); noclipLoop=nil end
end)

local infJumpConn
local infJumpT = secAbilities:Toggle("Infinite Jump", ui:LoadState("infjump", false), function(on)
	ui:SaveState("infjump", on)
	if on and not infJumpConn then
		infJumpConn = UIS.JumpRequest:Connect(function() local _,hum=getChar(); if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end end)
	elseif not on and infJumpConn then infJumpConn:Disconnect(); infJumpConn=nil end
end)

local secTP = player:Section("Teleport", false)
local savedCF
secTP:Button("Save Position", function() local _,_,hrp=getChar(); if hrp then savedCF=hrp.CFrame; ui:Notification("Saved position", "info", 1) end end)
secTP:Button("Teleport to Saved", function() local _,_,hrp=getChar(); if hrp and savedCF then hrp.CFrame=savedCF; ui:Notification("Teleported", "info", 1) else ui:Notification("No saved pos", "error", 1.2) end end)

-- WORLD
local secPhys = world:Section("Physics", false)
secPhys:Slider("Gravity", 10, 400, ui:LoadState("gravity", workspace.Gravity), 1, function(v) ui:SaveState("gravity", v); setGravity(v) end)

-- UI/UX
local secPickers = uiux:Section("Pickers", false)
local md = secPickers:MultiDropdown("Targets", {"Ore","Enemies","Coins","Gems","Chests","Bosses"}, {"Ore","Coins"}, function(arr)
	ui:Notification("Selected: "..(#arr>0 and table.concat(arr,", ") or "None"), "info", 1)
end)
local cp = secPickers:ColorPicker("Accent (wheel)", Color3.fromRGB(0,170,255), function(c) ui:Notification("Picked color", "info", 0.6) end)

local secWindow = uiux:Section("Window", false)
secWindow:Button("Minimize/Restore", function() ui._root.TopBar.Minimize:Activate() end)
secWindow:Button("Toggle UI (RightCtrl)", function() ui:ToggleUI() end)

-- KEYBINDS
local secBinds = binds:Section("Actions", false)
ui:BindAction("ToggleNoClip", Enum.KeyCode.F5, function() noclipT:Set(not noclipT:Get()) end)
secBinds:Keybind("Toggle NoClip:", "ToggleNoClip", Enum.KeyCode.F5)
ui:BindAction("ToggleInfJump", Enum.KeyCode.F6, function() infJumpT:Set(not infJumpT:Get()) end)
secBinds:Keybind("Toggle InfJump:", "ToggleInfJump", Enum.KeyCode.F6)

-- THEMES
local secTheme = theme:Section("Presets", false)
local presets = ui:GetThemes()
secTheme:Dropdown("Theme", presets, "Midnight Slate", function(name)
	if ui:ApplyTheme(name) then ui:RefreshTheme(); ui:Notification("Theme: "..name, "info", 1) end
end)

-- HUD
local secHUD = main:Section("HUD", false)
local hud1 = secHUD:Label("NoClip: " .. tostring(noclipT:Get()))
local hud2 = secHUD:Label("InfJump: " .. tostring(infJumpT:Get()))
local hud3 = secHUD:Label("Speed: " .. tostring(spd:Get()))
local hud4 = secHUD:Label("Gravity: " .. tostring(workspace.Gravity))

noclipT.Changed:Connect(function(v) hud1:Set("NoClip: " .. tostring(v)) end)
infJumpT.Changed:Connect(function(v) hud2:Set("InfJump: " .. tostring(v)) end)
spd.Changed:Connect(function(v) hud3:Set("Speed: " .. tostring(v)) end)

task.defer(function()
	noclipT:Set(ui:LoadState("noclip", false))
	infJumpT:Set(ui:LoadState("infjump", false))
	setJumpPower(ui:LoadState("jump", 50))
	setGravity(ui:LoadState("gravity", workspace.Gravity))
end)
