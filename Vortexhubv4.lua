--// VORTEX HUB v6 · hardcoded backbone edition
--// pet ranks hardcoded (live-game names), tp/home blink through walls,
--// ESP highlights only the single best pet in the server.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TS = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local PPS = game:GetService("ProximityPromptService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LP = Players.LocalPlayer

local ALIVE = true
local T = {
    InstaSteal = true, Velocidad = false, Speed = 32,
    Xray = false, FPSBoost = false, ESPMax = true, StealCap = 3,
}
local SavedReturn, HomeAnchor, BUSY = nil, nil, false
local ORIG_SPEED = 16
local sessionSteals, nextStealAt = 0, 0

local function getRoot()
    local c = LP.Character or LP.CharacterAdded:Wait()
    return c:WaitForChild("HumanoidRootPart", 10), c
end
local function humanDelay(a, b) return a + math.random() * (b - a) end

--// ---------------- hardcoded pet backbone ----------------
--// exact names observed in the live game (footage, aug 2026)
local PET_TABLE = {
    ["Hidra"] = 2000,   -- 1 in 1.5q tier
    ["Mech"] = 1500,    -- ULTRA $b/s tier
    ["Maddie"] = 1200,
    ["Lana"] = 1000,
}
--// hardcoded keyword ranks for pets not in the exact table
local KEY_RANKS = {
    ["secret"] = 950, ["galactic"] = 920, ["galaxy"] = 920, ["cosmic"] = 900,
    ["celestial"] = 880, ["god"] = 850, ["divine"] = 830, ["void"] = 800,
    ["omega"] = 780, ["infinity"] = 760, ["mythic"] = 720, ["dragon"] = 700,
    ["ultra"] = 680, ["rainbow"] = 640, ["golden"] = 600, ["gold"] = 580,
    ["legendary"] = 540, ["epic"] = 450, ["rare"] = 300,
}
local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, q = 1e15 }
local function parseRarity(text)
    local best = 0
    for core, suf in text:gmatch("1%s*[iI][nN]%s+([%d%,%.]+)%s*([kKmMbBtTqQ]?)") do
        local v = tonumber(core:gsub(",", ""))
        if v then suf = suf:lower(); if SUFFIX[suf] then v = v * SUFFIX[suf] end; if v > best then best = v end end
    end
    return best
end

local function rankModel(model)
    local n = model.Name
    local rank = PET_TABLE[n] or 0
    local label = n
    if rank == 0 then
        local ln = n:lower()
        for k, v in pairs(KEY_RANKS) do
            if ln:find(k, 1, true) and v > rank then rank = v; label = n end
        end
    end
    -- bonus only: live rarity text if the game happens to show it
    local bb = model:FindFirstChildOfClass("BillboardGui")
    if bb then
        for _, d in ipairs(bb:GetDescendants()) do
            if d:IsA("TextLabel") then
                local rr = parseRarity(d.Text)
                if rr > 1 then
                    local bonus = 800 + math.min(1200, math.floor(math.log10(rr) * 100))
                    if bonus > rank then rank = bonus; label = n end
                end
            end
        end
    end
    return rank, label
end

local function getPetPart(m)
    return m.PrimaryPart or m:FindFirstChild("HumanoidRootPart") or m:FindFirstChildWhichIsA("BasePart")
end

local function rankedPets()
    if not HomeAnchor then local r = getRoot(); if r then HomeAnchor = r.CFrame end end
    local found, seen, nodes = {}, {}, 0
    local stack = { Workspace }
    while #stack > 0 do
        local node = table.remove(stack); nodes = nodes + 1
        if nodes > 20000 then break end
        for _, c in ipairs(node:GetChildren()) do
            if c:IsA("Model") and not seen[c] then
                seen[c] = true
                if not Players:GetPlayerFromCharacter(c) and getPetPart(c) then
                    local rank = rankModel(c)
                    if rank > 0 then
                        table.insert(found, { model = c, rank = rank })
                    end
                end
            end
            if #c:GetChildren() > 0 then table.insert(stack, c) end
        end
    end
    -- prefer pets outside your own base
    local others, own = {}, {}
    for _, p in ipairs(found) do
        local part = getPetPart(p.model)
        if part and HomeAnchor and (part.Position - HomeAnchor.Position).Magnitude > 55 then
            table.insert(others, p) else table.insert(own, p) end
    end
    local pool = #others > 0 and others or own
    table.sort(pool, function(a, b) return a.rank > b.rank end)
    return pool
end
local function pickBest()
    local r = rankedPets()
    return r[1]
end

--// ---------------- fast blink (through walls — the thing that works) ----------------
local function fastBlink(destPos)
    local r = getRoot(); if not r then return false end
    local cur = r.CFrame
    while ALIVE and (cur.Position - destPos).Magnitude > 140 do
        cur = cur + (destPos - cur.Position).Unit * 140
        r.CFrame = cur
        local pause = 0.02 + math.random() * 0.04
        if math.random() < 0.08 then pause = pause * 2.2 end
        task.wait(pause)
        r = getRoot(); if not r then return false end
    end
    if not ALIVE then return false end
    r.CFrame = CFrame.new(destPos + Vector3.new((math.random()-0.5)*2, 3, (math.random()-0.5)*2))
    return true
end

--// ---------------- steal execution (multi-method) ----------------
local fireLog, lastFireAt = {}, 0
local function rateOK()
    local now = os.clock()
    fireLog[#fireLog + 1] = now
    while fireLog[1] and now - fireLog[1] > 60 do table.remove(fireLog, 1) end
    if #fireLog > 12 then return false end
    if now - lastFireAt < 0.4 then return false end
    return true
end
local function firePrompt(p)
    if not rateOK() then return false end
    lastFireAt = os.clock()
    if type(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, p); return true
    end
    pcall(function()
        local key = p.KeyboardKeyCode
        VirtualInputManager:SendKeyEvent(true, key, false, game)
        task.wait(math.max(p.HoldDuration, 0.1))
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
    return true
end

local function executeSteal(petModel)
    local r = getRoot(); if not r then return false end
    local prompt = nil
    for _, d in ipairs(petModel:GetDescendants()) do
        if d:IsA("ProximityPrompt") then prompt = d; break end
    end
    if prompt then
        pcall(function() prompt.HoldDuration = 0 end)
        firePrompt(prompt)
        return true
    end
    local char = LP.Character
    if char then
        local tool = nil
        local keywords = { "steal", "net", "grab", "catch", "robar", "agarrar" }
        for _, src in ipairs({ char, LP:FindFirstChildOfClass("Backpack") }) do
            if src then
                for _, t in ipairs(src:GetChildren()) do
                    if t:IsA("Tool") then
                        for _, k in ipairs(keywords) do
                            if t.Name:lower():find(k) then tool = t; break end
                        end
                    end
                    if tool then break end
                end
            end
            if tool then break end
        end
        if tool then
            if tool.Parent ~= char then pcall(function() tool.Parent = char end) end
            task.wait(0.1)
            tool:Activate()
            return true
        end
    end
    for _, d in ipairs(petModel:GetDescendants()) do
        if d:IsA("ClickDetector") then
            if type(fireclickdetector) == "function" then pcall(fireclickdetector, d) end
            return true
        end
    end
    return false
end

local function waitForHand(petModel, timeout)
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        local char = LP.Character
        if char then
            if petModel.Parent and petModel:IsDescendantOf(char) then return true end
            if char:FindFirstChild(petModel.Name) then return true end
            if not petModel.Parent then return true end
            if not getPetPart(petModel) then return true end
        end
        task.wait(0.15)
    end
    return false
end

--// ---------------- max pet esp ----------------
local espModel, espHL, espBB = nil, nil, nil
local function refreshMaxESP()
    local best = pickBest()
    local bm = best and best.model or nil
    if bm ~= espModel then
        if espHL then pcall(function() espHL:Destroy() end); espHL = nil end
        if espBB then pcall(function() espBB:Destroy() end); espBB = nil end
        espModel = bm
        if bm then
            local hl = Instance.new("Highlight")
            hl.Adornee = bm
            hl.FillColor = Color3.fromRGB(255, 200, 40)
            hl.OutlineColor = Color3.fromRGB(255, 255, 255)
            hl.FillTransparency = 0.5
            hl.Parent = bm
            espHL = hl
            local part = getPetPart(bm)
            if part then
                local bb = Instance.new("BillboardGui")
                bb.Size = UDim2.new(0, 170, 0, 30)
                bb.StudsOffset = Vector3.new(0, 4, 0)
                bb.AlwaysOnTop = true
                local l = Instance.new("TextLabel")
                l.Size = UDim2.new(1, 0, 1, 0)
                l.BackgroundTransparency = 1
                l.Font = Enum.Font.GothamBlack
                l.TextSize = 14
                l.Text = "★ MAX PET · " .. bm.Name
                l.TextColor3 = Color3.fromRGB(255, 200, 40)
                l.TextStrokeTransparency = 0.1
                l.Parent = bb
                bb.Parent = part
                espBB = bb
            end
        end
    end
end

--// ================================================================
--// GUI (the shell you liked, v6)
--// ================================================================
local function guiParent()
    if gethui then return gethui() end
    return LP:WaitForChild("PlayerGui")
end
local sg = Instance.new("ScreenGui")
sg.Name = "VortexHub"; sg.ResetOnSpawn = false
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.Parent = guiParent()

local ACC1 = Color3.fromRGB(124, 31, 208)
local ACC2 = Color3.fromRGB(0, 200, 255)
local BG = Color3.fromRGB(15, 16, 21)
local BG2 = Color3.fromRGB(22, 24, 31)
local TXT = Color3.fromRGB(225, 228, 235)
local DIM = Color3.fromRGB(130, 135, 148)

local win = Instance.new("Frame")
win.Size = UDim2.new(0, 470, 0, 320)
win.Position = UDim2.new(0.5, -235, 0.5, -160)
win.BackgroundColor3 = BG; win.BorderSizePixel = 0; win.ClipsDescendants = true
win.Parent = sg
Instance.new("UICorner", win).CornerRadius = UDim.new(0, 10)
local wStroke = Instance.new("UIStroke", win); wStroke.Color = Color3.fromRGB(48, 52, 66)

local topbar = Instance.new("Frame")
topbar.Size = UDim2.new(1, 0, 0, 42); topbar.BackgroundColor3 = BG2
topbar.BorderSizePixel = 0; topbar.Parent = win
Instance.new("UICorner", topbar).CornerRadius = UDim.new(0, 10)
local tbFix = Instance.new("Frame", topbar)
tbFix.Size = UDim2.new(1, 0, 0, 10); tbFix.Position = UDim2.new(0, 0, 1, -10)
tbFix.BackgroundColor3 = BG2; tbFix.BorderSizePixel = 0

local logo = Instance.new("TextLabel")
logo.Size = UDim2.new(0, 220, 1, 0); logo.Position = UDim2.new(0, 14, 0, 0)
logo.BackgroundTransparency = 1; logo.Text = "VORTEX  HUB  v6"
logo.Font = Enum.Font.GothamBlack; logo.TextSize = 15
logo.TextXAlignment = Enum.TextXAlignment.Left; logo.TextColor3 = TXT
logo.Parent = topbar
local lg = Instance.new("UIGradient", logo)
lg.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, ACC1), ColorSequenceKeypoint.new(1, ACC2) })

local function topBtn(text, x)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 30, 0, 26); b.Position = UDim2.new(1, x, 0, 8)
    b.BackgroundColor3 = Color3.fromRGB(32, 35, 44); b.BorderSizePixel = 0
    b.Text = text; b.Font = Enum.Font.GothamBold; b.TextSize = 12; b.TextColor3 = DIM
    b.Parent = topbar
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end
local minBtn = topBtn("—", -70)
local burnBtn = topBtn("X", -36)

local sidebar = Instance.new("Frame")
sidebar.Size = UDim2.new(0, 108, 1, -42); sidebar.Position = UDim2.new(0, 0, 0, 42)
sidebar.BackgroundColor3 = BG; sidebar.BorderSizePixel = 0; sidebar.Parent = win
local tabLayout = Instance.new("UIListLayout", sidebar); tabLayout.Padding = UDim.new(0, 4)
local spad = Instance.new("UIPadding", sidebar)
spad.PaddingTop = UDim.new(0, 10); spad.PaddingLeft = UDim.new(0, 8); spad.PaddingRight = UDim.new(0, 8)

local body = Instance.new("Frame")
body.Size = UDim2.new(1, -108, 1, -42); body.Position = UDim2.new(0, 108, 0, 42)
body.BackgroundColor3 = BG; body.BorderSizePixel = 0; body.Parent = win

local tabs, pages = {}, {}
local function selectTab(name)
    for n, p in pairs(pages) do p.Visible = (n == name) end
    for n, b in pairs(tabs) do
        b.TextColor3 = (n == name) and TXT or DIM
        b.BackgroundColor3 = (n == name) and Color3.fromRGB(34, 37, 47) or Color3.fromRGB(0, 0, 0, 0)
    end
end
local function makeTab(name)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 32); b.BackgroundColor3 = Color3.fromRGB(0, 0, 0, 0)
    b.BorderSizePixel = 0; b.Text = name; b.Font = Enum.Font.GothamBold
    b.TextSize = 12; b.TextColor3 = DIM; b.Parent = sidebar
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7)
    tabs[name] = b
    local page = Instance.new("ScrollingFrame")
    page.Size = UDim2.new(1, 0, 1, 0); page.BackgroundTransparency = 1
    page.BorderSizePixel = 0; page.ScrollBarThickness = 3
    page.ScrollBarImageColor3 = Color3.fromRGB(60, 64, 80)
    page.CanvasSize = UDim2.new(0, 0, 0, 0); page.Visible = false; page.Parent = body
    local lay = Instance.new("UIListLayout", page); lay.Padding = UDim.new(0, 8)
    local p2 = Instance.new("UIPadding", page)
    p2.PaddingTop = UDim.new(0, 12); p2.PaddingLeft = UDim.new(0, 14); p2.PaddingRight = UDim.new(0, 14)
    pages[name] = page
    b.MouseButton1Click:Connect(function() selectTab(name) end)
    return page
end
local function section(page, text)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, 0, 0, 16); l.BackgroundTransparency = 1
    l.Text = text; l.Font = Enum.Font.GothamBlack; l.TextSize = 11
    l.TextColor3 = ACC2; l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = page
end
local function toggle(page, label, default, cb)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 36); row.BackgroundColor3 = BG2
    row.BorderSizePixel = 0; row.Parent = page
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
    local t = Instance.new("TextLabel")
    t.Size = UDim2.new(1, -60, 1, 0); t.Position = UDim2.new(0, 12, 0, 0)
    t.BackgroundTransparency = 1; t.Text = label; t.Font = Enum.Font.Gotham
    t.TextSize = 12; t.TextColor3 = TXT; t.TextXAlignment = Enum.TextXAlignment.Left
    t.Parent = row
    local pill = Instance.new("Frame")
    pill.Size = UDim2.new(0, 40, 0, 20); pill.Position = UDim2.new(1, -50, 0.5, -10)
    pill.BorderSizePixel = 0; pill.Parent = row
    Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 10)
    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 14, 0, 14); knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0; knob.Parent = pill
    Instance.new("UICorner", knob).CornerRadius = UDim.new(0, 7)
    local on = default
    local function paint()
        pill.BackgroundColor3 = on and ACC1 or Color3.fromRGB(50, 53, 64)
        TS:Create(knob, TweenInfo.new(0.15), {
            Position = on and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
        }):Play()
    end
    paint()
    row.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            on = not on; paint(); cb(on)
        end
    end)
end
local function slider(page, label, min, max, default, cb)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 44); row.BackgroundColor3 = BG2
    row.BorderSizePixel = 0; row.Parent = page
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
    local t = Instance.new("TextLabel")
    t.Size = UDim2.new(0.6, 0, 0, 20); t.Position = UDim2.new(0, 12, 0, 4)
    t.BackgroundTransparency = 1; t.Text = label; t.Font = Enum.Font.Gotham
    t.TextSize = 12; t.TextColor3 = TXT; t.TextXAlignment = Enum.TextXAlignment.Left
    t.Parent = row
    local val = Instance.new("TextLabel")
    val.Size = UDim2.new(0.35, -12, 0, 20); val.Position = UDim2.new(0.65, 0, 0, 4)
    val.BackgroundTransparency = 1; val.Text = tostring(default)
    val.Font = Enum.Font.GothamBold; val.TextSize = 12; val.TextColor3 = ACC2
    val.TextXAlignment = Enum.TextXAlignment.Right; val.Parent = row
    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, -24, 0, 4); bar.Position = UDim2.new(0, 12, 1, -12)
    bar.BackgroundColor3 = Color3.fromRGB(45, 48, 60); bar.BorderSizePixel = 0; bar.Parent = row
    Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 2)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
    fill.BackgroundColor3 = ACC1; fill.BorderSizePixel = 0; fill.Parent = bar
    Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 2)
    local dragging = false
    local function setFromX(x)
        local rel = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        local v = math.floor(min + rel * (max - min))
        val.Text = tostring(v); cb(v)
    end
    bar.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            dragging = true; setFromX(inp.Position.X)
        end
    end)
    UIS.InputChanged:Connect(function(inp)
        if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            setFromX(inp.Position.X)
        end
    end)
    UIS.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
end
local function button(page, label, cb, accent)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 36); b.BackgroundColor3 = accent and ACC1 or BG2
    b.BorderSizePixel = 0; b.Text = label; b.Font = Enum.Font.GothamBold
    b.TextSize = 12; b.TextColor3 = TXT; b.Parent = page
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    if accent then
        local g = Instance.new("UIGradient", b)
        g.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, ACC1), ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 20, 160)) })
    end
    b.MouseButton1Click:Connect(cb)
    return b
end

local notifyHolder = Instance.new("Frame")
notifyHolder.Size = UDim2.new(0, 220, 1, 0); notifyHolder.Position = UDim2.new(1, -230, 0, 0)
notifyHolder.BackgroundTransparency = 1; notifyHolder.Parent = sg
local nLayout = Instance.new("UIListLayout", notifyHolder)
nLayout.Padding = UDim.new(0, 6)
nLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
local function notify(title, text, color)
    local n = Instance.new("Frame")
    n.Size = UDim2.new(1, 0, 0, 52); n.BackgroundColor3 = BG2; n.BorderSizePixel = 0
    n.Parent = notifyHolder
    Instance.new("UICorner", n).CornerRadius = UDim.new(0, 8)
    local s = Instance.new("UIStroke", n); s.Color = color or ACC2
    local t1 = Instance.new("TextLabel")
    t1.Size = UDim2.new(1, -16, 0, 18); t1.Position = UDim2.new(0, 10, 0, 5)
    t1.BackgroundTransparency = 1; t1.Text = title; t1.Font = Enum.Font.GothamBlack
    t1.TextSize = 11; t1.TextColor3 = color or ACC2; t1.TextXAlignment = Enum.TextXAlignment.Left
    t1.Parent = n
    local t2 = Instance.new("TextLabel")
    t2.Size = UDim2.new(1, -16, 0, 22); t2.Position = UDim2.new(0, 10, 0, 24)
    t2.BackgroundTransparency = 1; t2.Text = text; t2.Font = Enum.Font.Gotham
    t2.TextSize = 10; t2.TextColor3 = DIM; t2.TextXAlignment = Enum.TextXAlignment.Left
    t2.TextWrapped = true; t2.Parent = n
    n.Position = UDim2.new(1, 40, 0, 0)
    TS:Create(n, TweenInfo.new(0.25), { Position = UDim2.new(0, 0, 0, 0) }):Play()
    task.delay(3, function()
        TS:Create(n, TweenInfo.new(0.25), { Position = UDim2.new(1, 40, 0, 0) }):Play()
        task.wait(0.3); n:Destroy()
    end)
end

--// ---------------- tabs ----------------
local pageMain = makeTab("Main")
local pageSteal = makeTab("Steal")
local pageSet = makeTab("Settings")

section(pageMain, "MOVEMENT")
toggle(pageMain, "Velocidad", T.Velocidad, function(on) T.Velocidad = on end)
slider(pageMain, "Walk speed", 16, 60, T.Speed, function(v) T.Speed = v end)
section(pageMain, "VISUALS")
toggle(pageMain, "ESP max pet (best only)", T.ESPMax, function(on)
    T.ESPMax = on
    if not on then
        if espHL then pcall(function() espHL:Destroy() end); espHL = nil end
        if espBB then pcall(function() espBB:Destroy() end); espBB = nil end
        espModel = nil
    end
end)
toggle(pageMain, "Xray walls", T.Xray, function(on) T.Xray = on; if not on then resetXray() end end)
toggle(pageMain, "FPS boost", T.FPSBoost, function(on) T.FPSBoost = on; applyFPS(on) end)

section(pageSteal, "TELEPORT + STEAL")
toggle(pageSteal, "Insta steal", T.InstaSteal, function(on) T.InstaSteal = on end)
button(pageSteal, "GUARDAR POSICIÓN", function()
    local r = getRoot(); if not r then return end
    SavedReturn = r.CFrame
    notify("VORTEX", "return point saved", Color3.fromRGB(120, 255, 160))
end)
button(pageSteal, "TP TO BEST PET", function()
    local best = pickBest()
    if not best then
        notify("VORTEX", "no pets found", Color3.fromRGB(255, 100, 100))
        return
    end
    local part = getPetPart(best.model)
    if part then
        fastBlink(part.Position)
        notify("TP", "at " .. best.model.Name, Color3.fromRGB(120, 255, 160))
    end
end)
button(pageSteal, "FLASH STEAL", function()
    if BUSY then return end
    if os.clock() < nextStealAt then
        notify("HUMANIZER", "cooling down — humans wait", Color3.fromRGB(255, 200, 40))
        return
    end
    if sessionSteals >= T.StealCap then
        notify("HUMANIZER", "session cap hit — rest", Color3.fromRGB(255, 200, 40))
        return
    end
    BUSY = true
    task.spawn(function()
        local r = getRoot()
        if not r then BUSY = false; return end
        if not SavedReturn then SavedReturn = r.CFrame end
        if not HomeAnchor then HomeAnchor = r.CFrame end
        notify("VORTEX", "hunting best pet...", ACC2)
        local best = pickBest()
        if not best then
            notify("VORTEX", "no pets found", Color3.fromRGB(255, 100, 100))
            BUSY = false; return
        end
        notify("FLASH", "-> " .. best.model.Name, ACC1)
        local part = getPetPart(best.model)
        fastBlink(part.Position)
        task.wait(humanDelay(0.25, 0.7))
        executeSteal(best.model)
        waitForHand(best.model, 3)
        task.wait(humanDelay(0.8, 1.6))
        fastBlink(SavedReturn.Position)
        sessionSteals = sessionSteals + 1
        nextStealAt = os.clock() + humanDelay(60, 120)
        notify("VORTEX", "home · " .. best.model.Name, Color3.fromRGB(120, 255, 160))
        BUSY = false
    end)
end, true)
button(pageSteal, "GO HOME", function()
    local target = SavedReturn or HomeAnchor
    if target then
        fastBlink(target.Position)
        notify("VORTEX", "home", Color3.fromRGB(120, 255, 160))
    end
end)

section(pageSet, "HUMANIZER")
slider(pageSet, "Steals per session", 1, 6, T.StealCap, function(v) T.StealCap = v end)
section(pageSet, "SAFETY")
button(pageSet, "BURN — clean exit", function() burn() end)
section(pageSet, "CONFIG")
button(pageSet, "Save config", function()
    pcall(function()
        if writefile then
            writefile("vortex_cfg.json", HttpService:JSONEncode(T))
            notify("VORTEX", "config saved", Color3.fromRGB(120, 255, 160))
        end
    end)
end)

--// ---------------- loops ----------------
local xrayT, fpsT = {}, {}
function resetXray()
    for part, _ in pairs(xrayT) do pcall(function() part.LocalTransparencyModifier = 0 end) end
    xrayT = {}
end
function applyFPS(on)
    if on then
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d:IsA("ParticleEmitter") or d:IsA("Sparkles") or d:IsA("Beam") then
                fpsT[d] = d.Enabled; pcall(function() d.Enabled = false end)
            end
        end
    else
        for obj, was in pairs(fpsT) do pcall(function() obj.Enabled = was end) end
        fpsT = {}
    end
end

PPS.PromptShown:Connect(function(prompt)
    if not ALIVE or not T.InstaSteal then return end
    local label = ((prompt.ActionText or "") .. " " .. (prompt.ObjectText or "")):lower()
    if label:find("steal") or label:find("grab") or label:find("take") or label:find("robar") then
        pcall(function() prompt.HoldDuration = 0 end)
        task.spawn(function() task.wait(humanDelay(0.05, 0.2)); firePrompt(prompt) end)
    end
end)

RunService.Heartbeat:Connect(function()
    if not ALIVE then return end
    pcall(function()
        local _, char = getRoot()
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        if T.Velocidad and hum.WalkSpeed ~= T.Speed then hum.WalkSpeed = T.Speed end
        if not T.Velocidad and hum.WalkSpeed ~= ORIG_SPEED then hum.WalkSpeed = ORIG_SPEED end
    end)
end)

task.spawn(function()
    while ALIVE do
        task.wait(1.5)
        pcall(function()
            if T.ESPMax then refreshMaxESP() end
            if T.Xray then
                local r = getRoot()
                if r then
                    local count = 0
                    for _, d in ipairs(Workspace:GetDescendants()) do
                        if count > 1500 then break end
                        if d:IsA("BasePart") and d.Transparency < 0.5 then
                            local inChar = LP.Character and d:IsDescendantOf(LP.Character)
                            if not inChar and (d.Position - r.Position).Magnitude < 120 then
                                d.LocalTransparencyModifier = 0.55
                                xrayT[d] = true
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end)
    end
end)

--// ---------------- burn / hide / drag / boot ----------------
function burn()
    ALIVE = false
    pcall(function()
        local _, char = getRoot()
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = ORIG_SPEED end
    end)
    resetXray(); applyFPS(false)
    if espHL then pcall(function() espHL:Destroy() end) end
    if espBB then pcall(function() espBB:Destroy() end) end
    pcall(function() sg:Destroy() end)
end
burnBtn.MouseButton1Click:Connect(burn)
UIS.InputBegan:Connect(function(inp, gp)
    if gp then return end
    if inp.KeyCode == Enum.KeyCode.K then burn() end
    if inp.KeyCode == Enum.KeyCode.RightShift then win.Visible = not win.Visible end
end)
minBtn.MouseButton1Click:Connect(function() win.Visible = not win.Visible end)

local dragStart, winStart = nil, nil
topbar.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
        dragStart = inp.Position; winStart = win.Position
    end
end)
UIS.InputChanged:Connect(function(inp)
    if dragStart and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
        local d = inp.Position - dragStart
        win.Position = UDim2.new(winStart.X.Scale, winStart.X.Offset + d.X, winStart.Y.Scale, winStart.Y.Offset + d.Y)
    end
end)
UIS.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then dragStart = nil end
end)

selectTab("Steal")
task.spawn(function()
    getRoot(); HomeAnchor = getRoot().CFrame
    notify("VORTEX v6", "hardcoded backbone live · K = burn", Color3.fromRGB(120, 255, 160))
end)
