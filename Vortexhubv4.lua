--[[
    VORTEX HUB — Build a Base and Steal
    Mobile-friendly version
    Remote: ReplicatedStorage.RemoteEvent
    Action: steal_hold_begin(ownerUserId, petUUID)
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local RS               = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 15)
local StealRemote = RS:FindFirstChild("RemoteEvent") or RS:WaitForChild("RemoteEvent", 10)

-- ══════════════════════════════════════════════
--  RARITY WEIGHTS
-- ══════════════════════════════════════════════
local RARITY_WEIGHT = {
    Common=1, Uncommon=2, Rare=3, Epic=4,
    Legendary=5, Mythical=6, Godly=7, Secret=8,
    Divine=9, Celestial=10, OG=11, ULTRA=12,
}

-- ══════════════════════════════════════════════
--  CONFIG
-- ══════════════════════════════════════════════
local CFG = {
    StealMode   = "MPS",
    AutoLoop    = false,
    LoopDelay   = 5.0,
    AnchorPoint = nil,
    HumanizeTP  = true,
    TPSteps     = 4,
    StepDelay   = 0.07,
    PostTPDelay = 0.45,
    SimulateFall= true,
    YJitter     = true,
    AntiAFK     = true,
    SkipLocked  = true,
    SkipOwn     = true,
}

local stealThread  = nil
local stealRunning = false
local lastStatus   = "Idle"
local statusColor  = Color3.fromRGB(100, 220, 120)

-- ══════════════════════════════════════════════
--  UTILITY
-- ══════════════════════════════════════════════
local function getRootPart()
    local char = LocalPlayer.Character
    return char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
end

local function getHumanoid()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function rand(lo, hi) return lo + math.random()*(hi-lo) end

-- Touch-compatible button connection (Delta mobile safe)
local function connectButton(btn, fn)
    btn.MouseButton1Click:Connect(fn)
    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            fn()
        end
    end)
end


-- ══════════════════════════════════════════════
--  HUMANIZED TP
-- ══════════════════════════════════════════════
local function humanTP(targetCF)
    local root = getRootPart()
    if not root then return end
    if not CFG.HumanizeTP then
        root.CFrame = targetCF
        task.wait(CFG.PostTPDelay)
        return
    end
    local origin = root.CFrame
    for i = 1, CFG.TPSteps do
        local a = i/(CFG.TPSteps+1)
        root.CFrame = origin:Lerp(targetCF,a) + Vector3.new(rand(-.2,.2),rand(-.08,.08),rand(-.2,.2))
        task.wait(CFG.StepDelay)
    end
    local fy = CFG.YJitter and (targetCF.Y+rand(-.3,.3)) or targetCF.Y
    root.CFrame = CFrame.new(targetCF.X, fy, targetCF.Z)*targetCF.Rotation
    if CFG.SimulateFall then
        local h = getHumanoid()
        if h then
            h:ChangeState(Enum.HumanoidStateType.Freefall)
            task.wait(0.1)
            h:ChangeState(Enum.HumanoidStateType.Running)
        end
    end
    task.wait(CFG.PostTPDelay)
end

-- ══════════════════════════════════════════════
--  LOCKED BASE CHECK
-- ══════════════════════════════════════════════
local function isBaseLocked(ownerUserId)
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return false end
    for _, plot in ipairs(plots:GetChildren()) do
        if plot:GetAttribute("OwnerUserId") == ownerUserId then
            return plot:GetAttribute("LockState") == "Locked"
        end
    end
    return false
end

-- ══════════════════════════════════════════════
--  PET SCANNER
-- ══════════════════════════════════════════════
local function getPetScore(model)
    local species = model:GetAttribute("Species")
    if not species then return 0 end
    local petsFolder = RS:FindFirstChild("Pets")
    local pf = petsFolder and petsFolder:FindFirstChild(species)
    if not pf then return 0 end
    if CFG.StealMode == "MPS" then
        local v = pf:FindFirstChild("MPS")
        return v and v.Value or 0
    else
        local v = pf:FindFirstChild("Rarity")
        return RARITY_WEIGHT[v and v.Value or "Common"] or 0
    end
end

local function scanBestPet()
    local rp = Workspace:FindFirstChild("RuntimePets")
    if not rp then return nil,nil,nil,nil end
    local best,bestScore,bestCF,bestId,bestOwner = nil,-math.huge,nil,nil,nil
    for _, model in ipairs(rp:GetChildren()) do
        if model:IsA("Model") then
            local pid   = model:GetAttribute("PetId")
            local oid   = model:GetAttribute("OwnerUserId")
            if pid and oid then
                if CFG.SkipOwn and oid == LocalPlayer.UserId then continue end
                if CFG.SkipLocked and isBaseLocked(oid) then continue end
                local score = getPetScore(model)
                if score > bestScore then
                    local part = model:FindFirstChildWhichIsA("BasePart")
                    if part then
                        bestScore = score
                        best      = model
                        bestCF    = part.CFrame
                        bestId    = pid
                        bestOwner = oid
                    end
                end
            end
        end
    end
    return best, bestCF, bestId, bestOwner
end

-- ══════════════════════════════════════════════
--  FLASH STEAL
-- ══════════════════════════════════════════════
local function setStatus(txt, col)
    lastStatus  = txt
    statusColor = col or Color3.fromRGB(100,220,120)
end

local function doFlashSteal()
    if stealRunning then return end
    stealRunning = true
    setStatus("Scanning...", Color3.fromRGB(255,200,80))

    local petModel, petCF, petId, ownerId = scanBestPet()
    if not petModel then
        setStatus("No pets found", Color3.fromRGB(255,100,100))
        stealRunning = false
        return
    end

    local species  = petModel:GetAttribute("Species") or "?"
    local mutation = petModel:GetAttribute("Mutation")
    local label    = mutation and (mutation.." "..species) or species

    setStatus("TP → "..label, Color3.fromRGB(255,200,80))
    humanTP(petCF + Vector3.new(0,3,0))
    task.wait(0.2 + rand(0,0.1))

    pcall(function()
        StealRemote:FireServer("steal_hold_begin", ownerId, petId)
    end)

    task.wait(0.3 + rand(0,0.15))

    if CFG.AnchorPoint then
        setStatus("Returning...", Color3.fromRGB(255,200,80))
        humanTP(CFrame.new(CFG.AnchorPoint))
        setStatus("Done ✓ "..label, Color3.fromRGB(100,220,120))
    else
        setStatus("⚠ Set anchor!", Color3.fromRGB(255,100,100))
    end

    stealRunning = false
end

local function startLoop()
    if stealThread then task.cancel(stealThread) end
    stealThread = task.spawn(function()
        while CFG.AutoLoop do
            doFlashSteal()
            task.wait(math.max(CFG.LoopDelay + rand(-.8,.8), 2))
        end
    end)
end

local function stopLoop()
    if stealThread then task.cancel(stealThread) stealThread = nil end
end

-- ══════════════════════════════════════════════
--  ANTI-AFK
-- ══════════════════════════════════════════════
task.spawn(function()
    local VU = game:GetService("VirtualUser")
    while true do
        task.wait(55+rand(-5,5))
        if CFG.AntiAFK then
            pcall(function() VU:CaptureController() end)
            pcall(function() VU:ClickButton2(Vector2.new()) end)
        end
    end
end)

-- ══════════════════════════════════════════════
--  GUI — mobile-first sizing
--  Big tap targets, large fonts, no hover states
-- ══════════════════════════════════════════════

if PlayerGui:FindFirstChild("VortexHub") then
    PlayerGui:FindFirstChild("VortexHub"):Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = "VortexHub"
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent         = PlayerGui

-- detect screen size for positioning
local vp  = workspace.CurrentCamera.ViewportSize
local isMobile = vp.X < 900

-- panel dimensions: compact for mobile
local PW = isMobile and math.min(vp.X - 16, 360) or 420
local PH = isMobile and math.min(vp.Y - 60, 520)  or 540
local PX = isMobile and 8 or (vp.X/2 - PW/2 - 2)
local PY = isMobile and 30 or (vp.Y/2 - PH/2 - 2)

local hue = 0

local RGBBorder = Instance.new("Frame")
RGBBorder.Size            = UDim2.new(0, PW+4, 0, PH+4)
RGBBorder.Position        = UDim2.new(0, PX, 0, PY)
RGBBorder.BackgroundColor3 = Color3.fromHSV(0,1,1)
RGBBorder.BorderSizePixel = 0
RGBBorder.Active          = true
RGBBorder.Parent          = ScreenGui
Instance.new("UICorner", RGBBorder).CornerRadius = UDim.new(0,12)

local Main = Instance.new("Frame")
Main.Size             = UDim2.new(0, PW, 0, PH)
Main.Position         = UDim2.new(0,2,0,2)
Main.BackgroundColor3 = Color3.fromRGB(12,12,17)
Main.BorderSizePixel  = 0
Main.Parent           = RGBBorder
Instance.new("UICorner", Main).CornerRadius = UDim.new(0,10)

-- DRAG — works with both mouse and touch
do
    local dragging, dragStart, startPos
    local function onBegan(pos)
        dragging  = true
        dragStart = pos
        startPos  = RGBBorder.Position
    end
    local function onMoved(pos)
        if not dragging then return end
        local d = pos - dragStart
        RGBBorder.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + d.X,
            startPos.Y.Scale, startPos.Y.Offset + d.Y
        )
    end
    local function onEnded() dragging = false end

    RGBBorder.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            onBegan(i.Position)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch then
            onMoved(i.Position)
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            onEnded()
        end
    end)
end

-- HEADER
local HEADER_H = isMobile and 54 or 50

local Header = Instance.new("Frame")
Header.Size             = UDim2.new(1,0,0,HEADER_H)
Header.BackgroundColor3 = Color3.fromRGB(17,17,25)
Header.BorderSizePixel  = 0
Header.Parent           = Main
Instance.new("UICorner", Header).CornerRadius = UDim.new(0,10)

local HFix = Instance.new("Frame")
HFix.Size             = UDim2.new(1,0,0.5,0)
HFix.Position         = UDim2.new(0,0,0.5,0)
HFix.BackgroundColor3 = Color3.fromRGB(17,17,25)
HFix.BorderSizePixel  = 0
HFix.Parent           = Header

local TitleLbl = Instance.new("TextLabel")
TitleLbl.Size               = UDim2.new(1,-110,1,0)
TitleLbl.Position           = UDim2.new(0,14,0,0)
TitleLbl.BackgroundTransparency = 1
TitleLbl.Text               = "⚡  Vortex Hub"
TitleLbl.TextColor3         = Color3.fromRGB(220,210,255)
TitleLbl.Font               = Enum.Font.GothamBold
TitleLbl.TextSize           = isMobile and 18 or 17
TitleLbl.TextXAlignment     = Enum.TextXAlignment.Left
TitleLbl.Parent             = Header

-- minimize + close — 44px tap targets for mobile
local isMinimized = false

local MinBtn = Instance.new("TextButton")
MinBtn.Size             = UDim2.new(0, isMobile and 44 or 30, 0, isMobile and 44 or 28)
MinBtn.Position         = UDim2.new(1, isMobile and -96 or -74, 0.5, isMobile and -22 or -14)
MinBtn.BackgroundColor3 = Color3.fromRGB(50,50,75)
MinBtn.Text             = "—"
MinBtn.TextColor3       = Color3.fromRGB(200,200,220)
MinBtn.Font             = Enum.Font.GothamBold
MinBtn.TextSize         = 16
MinBtn.BorderSizePixel  = 0
MinBtn.Parent           = Header
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0,8)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size             = UDim2.new(0, isMobile and 44 or 30, 0, isMobile and 44 or 28)
CloseBtn.Position         = UDim2.new(1, isMobile and -48 or -38, 0.5, isMobile and -22 or -14)
CloseBtn.BackgroundColor3 = Color3.fromRGB(200,55,75)
CloseBtn.Text             = "✕"
CloseBtn.TextColor3       = Color3.fromRGB(255,255,255)
CloseBtn.Font             = Enum.Font.GothamBold
CloseBtn.TextSize         = 16
CloseBtn.BorderSizePixel  = 0
CloseBtn.Parent           = Header
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0,8)

local function doClose() ScreenGui:Destroy() end
CloseBtn.MouseButton1Click:Connect(doClose)
CloseBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then doClose() end
end)

local function doMinimize()
    isMinimized = not isMinimized
    if isMinimized then
        Body.Visible   = false
        RGBBorder.Size = UDim2.new(0, PW+4, 0, HEADER_H+4)
        Main.Size      = UDim2.new(0, PW, 0, HEADER_H)
        MinBtn.Text    = "+"
    else
        Body.Visible   = true
        RGBBorder.Size = UDim2.new(0, PW+4, 0, PH+4)
        Main.Size      = UDim2.new(0, PW, 0, PH)
        MinBtn.Text    = "—"
    end
end
MinBtn.MouseButton1Click:Connect(doMinimize)
MinBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then doMinimize() end
end)

-- TAB BAR
local TAB_H   = isMobile and 46 or 38
local TabBar  = Instance.new("Frame")
TabBar.Size             = UDim2.new(1,0,0,TAB_H)
TabBar.BackgroundColor3 = Color3.fromRGB(15,15,22)
TabBar.BorderSizePixel  = 0
TabBar.Parent           = Body
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Parent        = TabBar

local ContentArea = Instance.new("Frame")
ContentArea.Size              = UDim2.new(1,0,1,-TAB_H)
ContentArea.Position          = UDim2.new(0,0,0,TAB_H)
ContentArea.BackgroundTransparency = 1
ContentArea.Parent            = Body

local TAB_NAMES = {"Flash Steal","Set Point","Settings"}
local tabBtns   = {}
local tabPages  = {}
local activeTab = nil

local function makePage(name)
    local sf = Instance.new("ScrollingFrame")
    sf.Name                   = name
    sf.Size                   = UDim2.new(1,0,1,0)
    sf.BackgroundTransparency = 1
    sf.BorderSizePixel        = 0
    sf.ScrollBarThickness     = isMobile and 2 or 3
    sf.ScrollBarImageColor3   = Color3.fromRGB(110,70,220)
    sf.CanvasSize             = UDim2.new(0,0,0,0)
    sf.AutomaticCanvasSize    = Enum.AutomaticSize.Y
    sf.Visible                = false
    sf.Parent                 = ContentArea
    sf.ScrollingEnabled       = true
    local ll = Instance.new("UIListLayout")
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Padding   = UDim.new(0,6)
    ll.Parent    = sf
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft  = UDim.new(0,10)
    pad.PaddingRight = UDim.new(0,10)
    pad.PaddingTop   = UDim.new(0,10)
    pad.Parent       = sf
    return sf
end

local function switchTab(name)
    activeTab = name
    for n,pg  in pairs(tabPages) do pg.Visible = (n==name) end
    for n,btn in pairs(tabBtns) do
        btn.BackgroundColor3 = n==name and Color3.fromRGB(80,48,195) or Color3.fromRGB(20,20,30)
        btn.TextColor3       = n==name and Color3.fromRGB(255,255,255) or Color3.fromRGB(120,110,150)
    end
end

local tabW = math.floor(PW/#TAB_NAMES)
for i, tName in ipairs(TAB_NAMES) do
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, tabW, 1, 0)
    btn.BackgroundColor3 = Color3.fromRGB(20,20,30)
    btn.Text             = tName
    btn.TextColor3       = Color3.fromRGB(120,110,150)
    btn.Font             = Enum.Font.GothamSemibold
    btn.TextSize         = isMobile and 12 or 12
    btn.TextWrapped      = true
    btn.BorderSizePixel  = 0
    btn.LayoutOrder      = i
    btn.Parent           = TabBar
    tabBtns[tName]       = btn
    tabPages[tName]      = makePage(tName)
    local function tap() switchTab(tName) end
    btn.MouseButton1Click:Connect(tap)
    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then tap() end
    end)
end

-- UI HELPERS
local BTN_H   = isMobile and 52 or 38
local FONT_SZ = isMobile and 15 or 13
local TW_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad)

local function makeCard(parent, order)
    local f = Instance.new("Frame")
    f.Size             = UDim2.new(1,0,0,0)
    f.AutomaticSize    = Enum.AutomaticSize.Y
    f.BackgroundColor3 = Color3.fromRGB(19,19,28)
    f.BorderSizePixel  = 0
    f.LayoutOrder      = order or 0
    f.Parent           = parent
    Instance.new("UICorner",f).CornerRadius = UDim.new(0,8)
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = pad.PaddingRight = pad.PaddingTop = pad.PaddingBottom = UDim.new(0,10)
    pad.Parent = f
    local ll = Instance.new("UIListLayout")
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Padding   = UDim.new(0,isMobile and 10 or 7)
    ll.Parent    = f
    return f
end

local function sectionLbl(parent, txt, order)
    local l = Instance.new("TextLabel")
    l.Size               = UDim2.new(1,0,0,isMobile and 24 or 20)
    l.BackgroundTransparency = 1
    l.Text               = txt
    l.TextColor3         = Color3.fromRGB(150,120,255)
    l.Font               = Enum.Font.GothamBold
    l.TextSize           = isMobile and 13 or 11
    l.TextXAlignment     = Enum.TextXAlignment.Left
    l.LayoutOrder        = order or 0
    l.Parent             = parent
end

local function makeToggle(parent, labelTxt, initState, order, onChange)
    local ROW_H = isMobile and 46 or 30
    local row = Instance.new("Frame")
    row.Size               = UDim2.new(1,0,0,ROW_H)
    row.BackgroundTransparency = 1
    row.LayoutOrder        = order or 0
    row.Parent             = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size               = UDim2.new(1,-62,1,0)
    lbl.BackgroundTransparency = 1
    lbl.Text               = labelTxt
    lbl.TextColor3         = Color3.fromRGB(195,190,215)
    lbl.Font               = Enum.Font.Gotham
    lbl.TextSize           = FONT_SZ
    lbl.TextXAlignment     = Enum.TextXAlignment.Left
    lbl.Parent             = row

    local TW = isMobile and 52 or 44
    local TH = isMobile and 28 or 22
    local track = Instance.new("Frame")
    track.Size             = UDim2.new(0,TW,0,TH)
    track.Position         = UDim2.new(1,-TW,0.5,-TH/2)
    track.BackgroundColor3 = initState and Color3.fromRGB(80,48,195) or Color3.fromRGB(45,45,60)
    track.BorderSizePixel  = 0
    track.Parent           = row
    Instance.new("UICorner",track).CornerRadius = UDim.new(1,0)

    local KS = isMobile and 22 or 16
    local knob = Instance.new("Frame")
    knob.Size              = UDim2.new(0,KS,0,KS)
    knob.Position          = initState and UDim2.new(1,-(KS+2),0.5,-KS/2) or UDim2.new(0,2,0.5,-KS/2)
    knob.BackgroundColor3  = Color3.fromRGB(255,255,255)
    knob.BorderSizePixel   = 0
    knob.Parent            = track
    Instance.new("UICorner",knob).CornerRadius = UDim.new(1,0)

    local state = initState
    local hitbox = Instance.new("TextButton")
    hitbox.Size               = UDim2.new(1,0,1,0)
    hitbox.BackgroundTransparency = 1
    hitbox.Text               = ""
    hitbox.Parent             = row

    local function toggle()
        state = not state
        TweenService:Create(track, TW_INFO, {
            BackgroundColor3 = state and Color3.fromRGB(80,48,195) or Color3.fromRGB(45,45,60)
        }):Play()
        TweenService:Create(knob, TW_INFO, {
            Position = state and UDim2.new(1,-(KS+2),0.5,-KS/2) or UDim2.new(0,2,0.5,-KS/2)
        }):Play()
        if onChange then onChange(state) end
    end
    hitbox.MouseButton1Click:Connect(toggle)
    hitbox.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then toggle() end
    end)
end

local function makeButton(parent, labelTxt, color, order, onClick)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1,0,0,BTN_H)
    btn.BackgroundColor3 = color or Color3.fromRGB(75,45,185)
    btn.Text             = labelTxt
    btn.TextColor3       = Color3.fromRGB(255,255,255)
    btn.Font             = Enum.Font.GothamSemibold
    btn.TextSize         = FONT_SZ
    btn.BorderSizePixel  = 0
    btn.LayoutOrder      = order or 0
    btn.Parent           = parent
    Instance.new("UICorner",btn).CornerRadius = UDim.new(0,8)

    local function fire()
        TweenService:Create(btn, TweenInfo.new(0.08), {BackgroundTransparency=0.35}):Play()
        task.delay(0.08, function()
            TweenService:Create(btn, TweenInfo.new(0.08), {BackgroundTransparency=0}):Play()
        end)
        if onClick then onClick() end
    end
    btn.MouseButton1Click:Connect(fire)
    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then fire() end
    end)
    return btn
end

local function makeDropdown(parent, labelTxt, options, initIdx, order, onChange)
    local container = Instance.new("Frame")
    container.Size             = UDim2.new(1,0,0,0)
    container.AutomaticSize    = Enum.AutomaticSize.Y
    container.BackgroundTransparency = 1
    container.LayoutOrder      = order or 0
    container.Parent           = parent
    local ll = Instance.new("UIListLayout"); ll.Padding=UDim.new(0,4); ll.Parent=container

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1,0,0,isMobile and 22 or 18)
    lbl.BackgroundTransparency=1
    lbl.Text=labelTxt; lbl.TextColor3=Color3.fromRGB(195,190,215)
    lbl.Font=Enum.Font.Gotham; lbl.TextSize=FONT_SZ
    lbl.TextXAlignment=Enum.TextXAlignment.Left; lbl.LayoutOrder=0; lbl.Parent=container

    local selected = initIdx or 1
    local open     = false

    local selBtn = Instance.new("TextButton")
    selBtn.Size             = UDim2.new(1,0,0,isMobile and 46 or 30)
    selBtn.BackgroundColor3 = Color3.fromRGB(25,25,38)
    selBtn.Text             = options[selected].."  ▾"
    selBtn.TextColor3       = Color3.fromRGB(190,180,240)
    selBtn.Font             = Enum.Font.Gotham; selBtn.TextSize=FONT_SZ
    selBtn.BorderSizePixel  = 0; selBtn.LayoutOrder=1; selBtn.Parent=container
    Instance.new("UICorner",selBtn).CornerRadius=UDim.new(0,6)

    local itemH    = isMobile and 46 or 28
    local dropList = Instance.new("Frame")
    dropList.Size             = UDim2.new(1,0,0,#options*itemH)
    dropList.BackgroundColor3 = Color3.fromRGB(22,22,34)
    dropList.BorderSizePixel  = 0; dropList.Visible=false
    dropList.ZIndex=10; dropList.LayoutOrder=2; dropList.Parent=container
    Instance.new("UICorner",dropList).CornerRadius=UDim.new(0,6)
    local dll=Instance.new("UIListLayout"); dll.Parent=dropList

    for i, opt in ipairs(options) do
        local ob = Instance.new("TextButton")
        ob.Size=UDim2.new(1,0,0,itemH); ob.BackgroundTransparency=1
        ob.Text=opt; ob.TextColor3=Color3.fromRGB(175,165,210)
        ob.Font=Enum.Font.Gotham; ob.TextSize=FONT_SZ
        ob.BorderSizePixel=0; ob.LayoutOrder=i; ob.ZIndex=11; ob.Parent=dropList
        local function pick()
            selected=i; selBtn.Text=options[i].."  ▾"
            dropList.Visible=false; open=false
            if onChange then onChange(options[i],i) end
        end
        ob.MouseButton1Click:Connect(pick)
        ob.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch then pick() end
        end)
    end

    local function toggleDrop()
        open=not open; dropList.Visible=open
    end
    selBtn.MouseButton1Click:Connect(toggleDrop)
    selBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then toggleDrop() end
    end)
end

-- ══════════════════════════════════════════════
--  TAB: FLASH STEAL
-- ══════════════════════════════════════════════
local fsPage = tabPages["Flash Steal"]

sectionLbl(fsPage,"FLASH STEAL",1)
local fsCard = makeCard(fsPage,2)

local statusLbl = Instance.new("TextLabel")
statusLbl.Size               = UDim2.new(1,0,0,isMobile and 30 or 26)
statusLbl.BackgroundTransparency = 1
statusLbl.Text               = "Status: Idle"
statusLbl.TextColor3         = Color3.fromRGB(100,220,120)
statusLbl.Font               = Enum.Font.GothamSemibold
statusLbl.TextSize           = isMobile and 14 or 12
statusLbl.TextXAlignment     = Enum.TextXAlignment.Left
statusLbl.LayoutOrder        = 0
statusLbl.Parent             = fsCard

makeToggle(fsCard,"Auto Loop",false,1,function(s)
    CFG.AutoLoop = s
    if s then startLoop() else stopLoop(); setStatus("Idle") end
end)

makeDropdown(fsCard,"Target Mode",{"MPS (earnings/sec)","Rarity"},1,2,function(val,_)
    CFG.StealMode = val:find("MPS") and "MPS" or "Rarity"
end)

makeButton(fsCard,"⚡  Flash Steal Now",Color3.fromRGB(75,42,195),3,function()
    if not CFG.AnchorPoint then
        setStatus("⚠ Set anchor first!",Color3.fromRGB(255,100,100))
        return
    end
    task.spawn(doFlashSteal)
end)

-- ══════════════════════════════════════════════
--  TAB: SET POINT
-- ══════════════════════════════════════════════
local spPage = tabPages["Set Point"]
sectionLbl(spPage,"ANCHOR POINT",1)
local spCard = makeCard(spPage,2)

local pointLbl = Instance.new("TextLabel")
pointLbl.Size               = UDim2.new(1,0,0,isMobile and 50 or 38)
pointLbl.BackgroundTransparency = 1
pointLbl.Text               = "No anchor set.\nStand at your base and tap Set."
pointLbl.TextColor3         = Color3.fromRGB(155,145,185)
pointLbl.Font               = Enum.Font.Gotham; pointLbl.TextSize=FONT_SZ
pointLbl.TextXAlignment     = Enum.TextXAlignment.Left
pointLbl.TextWrapped        = true; pointLbl.LayoutOrder=0; pointLbl.Parent=spCard

makeButton(spCard,"📍  Set Current Position",Color3.fromRGB(42,155,90),1,function()
    local root = getRootPart()
    if root then
        CFG.AnchorPoint   = root.Position
        pointLbl.Text     = string.format("Anchor ✓\nX: %.1f  Y: %.1f  Z: %.1f",
            root.Position.X, root.Position.Y, root.Position.Z)
        pointLbl.TextColor3 = Color3.fromRGB(100,220,120)
    else
        pointLbl.Text     = "⚠ Character not loaded."
        pointLbl.TextColor3 = Color3.fromRGB(255,100,100)
    end
end)

makeButton(spCard,"🏠  TP to Anchor",Color3.fromRGB(55,75,185),2,function()
    if CFG.AnchorPoint then
        task.spawn(function() humanTP(CFrame.new(CFG.AnchorPoint)) end)
    end
end)

makeButton(spCard,"🗑  Clear Anchor",Color3.fromRGB(155,48,62),3,function()
    CFG.AnchorPoint     = nil
    pointLbl.Text       = "No anchor set.\nStand at your base and tap Set."
    pointLbl.TextColor3 = Color3.fromRGB(155,145,185)
end)

-- ══════════════════════════════════════════════
--  TAB: SETTINGS
-- ══════════════════════════════════════════════
local stPage = tabPages["Settings"]
sectionLbl(stPage,"HUMANIZATION",1)
local humCard = makeCard(stPage,2)
makeToggle(humCard,"Humanize Teleport",true,0,function(s) CFG.HumanizeTP=s end)
makeToggle(humCard,"Simulate Fall",true,1,function(s) CFG.SimulateFall=s end)
makeToggle(humCard,"Y-Offset Jitter",true,2,function(s) CFG.YJitter=s end)

sectionLbl(stPage,"LOOP",3)
local loopCard = makeCard(stPage,4)
makeToggle(loopCard,"Anti-AFK",true,0,function(s) CFG.AntiAFK=s end)
makeToggle(loopCard,"Skip Locked Bases",true,1,function(s) CFG.SkipLocked=s end)
makeToggle(loopCard,"Skip Own Pets",true,2,function(s) CFG.SkipOwn=s end)

-- Loop delay simple buttons for mobile (no slider needed)
sectionLbl(stPage,"LOOP DELAY",5)
local delayCard = makeCard(stPage,6)
local delayLbl = Instance.new("TextLabel")
delayLbl.Size=UDim2.new(1,0,0,isMobile and 30 or 24)
delayLbl.BackgroundTransparency=1
delayLbl.Text="Loop delay: "..string.format("%.1f",CFG.LoopDelay).."s"
delayLbl.TextColor3=Color3.fromRGB(195,190,215)
delayLbl.Font=Enum.Font.Gotham; delayLbl.TextSize=FONT_SZ
delayLbl.TextXAlignment=Enum.TextXAlignment.Left
delayLbl.LayoutOrder=0; delayLbl.Parent=delayCard

local arrowRow = Instance.new("Frame")
arrowRow.Size=UDim2.new(1,0,0,BTN_H)
arrowRow.BackgroundTransparency=1
arrowRow.LayoutOrder=1; arrowRow.Parent=delayCard
local al=Instance.new("UIListLayout"); al.FillDirection=Enum.FillDirection.Horizontal
al.Padding=UDim.new(0,8); al.Parent=arrowRow

local function arrowBtn(parent, label, order, onClick)
    local b = Instance.new("TextButton")
    b.Size=UDim2.new(0.5,-4,1,0); b.BackgroundColor3=Color3.fromRGB(50,50,75)
    b.Text=label; b.TextColor3=Color3.fromRGB(255,255,255)
    b.Font=Enum.Font.GothamBold; b.TextSize=isMobile and 18 or 15
    b.BorderSizePixel=0; b.LayoutOrder=order; b.Parent=parent
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,8)
    b.MouseButton1Click:Connect(onClick)
    b.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then onClick() end
    end)
end

arrowBtn(arrowRow,"− 1s",1,function()
    CFG.LoopDelay = math.max(2, CFG.LoopDelay-1)
    delayLbl.Text = "Loop delay: "..string.format("%.1f",CFG.LoopDelay).."s"
end)
arrowBtn(arrowRow,"+ 1s",2,function()
    CFG.LoopDelay = math.min(30, CFG.LoopDelay+1)
    delayLbl.Text = "Loop delay: "..string.format("%.1f",CFG.LoopDelay).."s"
end)

-- ══════════════════════════════════════════════
--  RGB + STATUS RENDER LOOP
-- ══════════════════════════════════════════════
RunService.RenderStepped:Connect(function()
    hue = (hue+0.003)%1
    RGBBorder.BackgroundColor3 = Color3.fromHSV(hue,1,1)
    if activeTab and tabBtns[activeTab] then
        tabBtns[activeTab].BackgroundColor3 = Color3.fromHSV(hue,0.75,0.65)
    end
    statusLbl.Text      = "Status: "..lastStatus
    statusLbl.TextColor3 = statusColor
end)

switchTab("Flash Steal")
print("[VortexHub Mobile] Loaded.")
