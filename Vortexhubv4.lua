--// VORTEX HUB v4 · behavioral-hardened engine
--// profiles: WALK (zero impossible movement) / GHOST (default, capped envelope)
--// / FLASH (legacy speed). entry via game gear = server-legit raid state.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TS = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local PPS = game:GetService("ProximityPromptService")
local Workspace = game:GetService("Workspace")
local Pathfinding = game:GetService("PathfindingService")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LP = Players.LocalPlayer

local ALIVE = true
local T = {
    InstaSteal = true, Velocidad = false, Speed = 32,
    WallClimb = false, ESPPets = true, Xray = false, FPSBoost = false,
    Profile = "GHOST", StealCap = 3,
}
local SavedReturn, HomeAnchor, BUSY = nil, nil, false
local ORIG_SPEED = 16
local sessionSteals, nextStealAt = 0, 0

local function getRoot()
    local c = LP.Character or LP.CharacterAdded:Wait()
    return c:WaitForChild("HumanoidRootPart", 10), c
end

local function humanDelay(a, b) return a + math.random() * (b - a) end

local function charRayParams()
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    p.FilterDescendantsInstances = { LP.Character }
    return p
end

--// ---------------- rate limiter + prompt fire ----------------
local fireLog, lastFireAt = {}, 0
local function rateOK()
    local now = os.clock()
    fireLog[#fireLog + 1] = now
    while fireLog[1] and now - fireLog[1] > 60 do table.remove(fireLog, 1) end
    if #fireLog > 12 then return false end
    if now - lastFireAt < 0.4 then return false end
    return true
end
local STEAL_WORDS = "steal grab take pick collect claim robar agarrar"
local function isStealPrompt(p)
    local label = ((p.ActionText or "") .. " " .. (p.ObjectText or "")):lower()
    for w in STEAL_WORDS:gmatch("%S+") do
        if label:find(w, 1, true) then return true end
    end
    return false
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

--// ---------------- movers ----------------
--// FLASH: legacy fast chunks (accepts movement-category risk)
local function flashTo(dest, chunk, pMin, pMax)
    local r = getRoot(); if not r then return false end
    local cur = r.CFrame
    while ALIVE and (cur.Position - dest).Magnitude > chunk do
        cur = cur + (dest - cur.Position).Unit * chunk
        r.CFrame = cur
        local pause = pMin + math.random() * (pMax - pMin)
        if math.random() < 0.08 then pause = pause * 2.2 end
        task.wait(pause)
        r = getRoot(); if not r then return false end
    end
    if not ALIVE then return false end
    r.CFrame = CFrame.lookAt(dest + Vector3.new((math.random()-0.5)*3, 3, (math.random()-0.5)*3), dest)
    return true
end

--// GHOST: capped velocity envelope, ease-in/out, heading wobble, wall-stop.
--// never punches geometry. returns "wall" when blocked so breach takes over.
local GHOST_SPEED = 52
local function ghostTo(dest)
    local r = getRoot(); if not r then return "dead" end
    local total = (r.Position - dest).Magnitude
    if total < 4 then return "done" end
    local t = 0
    local chunkT = 0.12
    while ALIVE do
        r = getRoot(); if not r then return "dead" end
        local remaining = dest - r.Position
        local dist = remaining.Magnitude
        if dist < 4 then return "done" end
        local prog = 1 - dist / total
        local ease = math.clamp(math.min(prog, 1 - prog) * 4, 0.3, 1)
        local step = math.min(GHOST_SPEED * ease * chunkT, dist)
        local dir = remaining.Unit
        local side = Vector3.new(-dir.Z, 0, dir.X)
        local wob = math.sin(t * 5.5) * 0.5
        local nextPos = r.Position + dir * step + side * wob
        local hit = Workspace:Raycast(r.Position, (nextPos - r.Position) * 1.3, charRayParams())
        if hit then return "wall" end
        r.CFrame = CFrame.new(nextPos, nextPos + dir)
        t = t + chunkT
        task.wait(chunkT + math.random() * 0.03)
    end
    return "dead"
end

--// WALK: pure pathfinding at humanoid speed. zero impossible movement.
local function walkTo(dest, timeout)
    local r = getRoot(); if not r then return false end
    local char = r.Parent
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    local path = Pathfinding:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
    local ok = pcall(function() path:ComputeAsync(r.Position, dest) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then return false end
    local wps = path:GetWaypoints()
    local deadline = os.clock() + (timeout or 45)
    for i = 2, #wps do
        if os.clock() > deadline or not ALIVE then return false end
        if wps[i].Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
        hum:MoveTo(wps[i].Position)
        local t0 = os.clock()
        while ALIVE and (r.Position - wps[i].Position).Magnitude > 3 and os.clock() - t0 < 4 do
            task.wait(0.1)
        end
    end
    return (getRoot().Position - dest).Magnitude < 7
end

local function travelTo(dest)
    if T.Profile == "WALK" then return walkTo(dest) and "done" or "dead" end
    if T.Profile == "FLASH" then return flashTo(dest, 140, 0.02, 0.06) and "done" or "dead" end
    return ghostTo(dest)
end

--// ---------------- gear breach: server-legit entry ----------------
--// swing the game's own gear at the wall. damage is server-validated,
--// so the raid state is genuinely satisfied, not spoofed.
local function breachTo(petPart)
    local r = getRoot(); if not r then return false end
    local char = r.Parent
    local tool = char:FindFirstChildOfClass("Tool") or LP.Backpack:FindFirstChildOfClass("Tool")
    if tool and tool.Parent ~= char then pcall(function() tool.Parent = char end) end
    local deadline = os.clock() + 14
    while ALIVE and os.clock() < deadline do
        r = getRoot(); if not r then return false end
        if (r.Position - petPart.Position).Magnitude < 7 then return true end
        local hit = Workspace:Raycast(r.Position, petPart.Position - r.Position, charRayParams())
        if not hit then return true end -- clean line, walk the rest
        if tool then
            r.CFrame = CFrame.new(r.Position, hit.Position)
            tool:Activate()
            task.wait(humanDelay(0.45, 0.95)) -- human swing rhythm
            r.CFrame = r.CFrame + (hit.Position - r.Position).Unit * 1.2
        else
            return false
        end
    end
    return (getRoot().Position - petPart.Position).Magnitude < 8
end

--// ---------------- parsers + rarity scan (unchanged core) ----------------
local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, q = 1e15 }
local function parseRarity(text)
    local best = 0
    for core, suf in text:gmatch("1%s*[iI][nN]%s+([%d%,%.]+)%s*([kKmMbBtTqQ]?)") do
        local v = tonumber(core:gsub(",", ""))
        if v then suf = suf:lower(); if SUFFIX[suf] then v = v * SUFFIX[suf] end; if v > best then best = v end end
    end
    for core, suf in text:gmatch("1%s*[eE][nN]%s+([%d%,%.]+)%s*([kKmMbBtTqQ]?)") do
        local v = tonumber(core:gsub(",", ""))
        if v then suf = suf:lower(); if SUFFIX[suf] then v = v * SUFFIX[suf] end; if v > best then best = v end end
    end
    return best
end
local function parseMoney(text)
    local best = 0
    for s in text:gmatch("%$[%d%,%.]+[kKmMbBtT]?/?s?") do
        local core = s:match("%$([%d%,%.]+)"); local suf = s:match("[kKmMbBtT]")
        core = core and core:gsub(",", "") or "0"
        local v = tonumber(core)
        if v then suf = suf and suf:lower() or ""; if SUFFIX[suf] then v = v * SUFFIX[suf] end; if v > best then best = v end end
    end
    return best
end
local NAME_TIERS = {
    { "secret", 100 }, { "galaxy", 92 }, { "cosmic", 86 }, { "god", 75 },
    { "void", 65 }, { "omega", 60 }, { "mythic", 55 }, { "dragon", 50 },
    { "ultra", 48 }, { "rainbow", 45 }, { "golden", 40 }, { "legendary", 34 },
}
local function nameScore(name)
    local n, s = name:lower(), 0
    for _, t in ipairs(NAME_TIERS) do if n:find(t[1], 1, true) then s = s + t[2] end end
    return s
end
local function fmtRarity(v)
    if v >= 1e15 then return string.format("1 in %.1fq", v / 1e15) end
    if v >= 1e12 then return string.format("1 in %.1ft", v / 1e12) end
    if v >= 1e9 then return string.format("1 in %.1fb", v / 1e9) end
    if v >= 1e6 then return string.format("1 in %.1fm", v / 1e6) end
    if v >= 1e3 then return string.format("1 in %.1fk", v / 1e3) end
    return "1 in " .. tostring(math.floor(v))
end
local function getPetPart(m)
    return m.PrimaryPart or m:FindFirstChild("HumanoidRootPart") or m:FindFirstChildWhichIsA("BasePart")
end
local function measurePet(model)
    local rarity, income, score = 0, 0, nameScore(model.Name)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local rr = parseRarity(d.Text); if rr > rarity then rarity = rr end
            local mm = parseMoney(d.Text); if mm > income then income = mm end
        end
    end
    return rarity, income, score
end
local function scanPets()
    local pets, seen, nodes = {}, {}, 0
    local stack = { Workspace }
    while #stack > 0 do
        local node = table.remove(stack); nodes = nodes + 1
        if nodes > 20000 then break end
        for _, c in ipairs(node:GetChildren()) do
            if c:IsA("Terrain") or c:IsA("Camera") then continue end
            if c:IsA("Model") and not seen[c] then
                seen[c] = true
                if not Players:GetPlayerFromCharacter(c) and getPetPart(c) then
                    local rarity, income, score = measurePet(c)
                    if rarity > 0 or income > 0 or score > 0 then
                        table.insert(pets, { model = c, rarity = rarity, income = income, score = score })
                    end
                end
            end
            if #c:GetChildren() > 0 then table.insert(stack, c) end
        end
    end
    return pets
end
local function rankedPets()
    if not HomeAnchor then local r = getRoot(); if r then HomeAnchor = r.CFrame end end
    local pets = scanPets(); local others = {}
    for _, p in ipairs(pets) do
        local part = getPetPart(p.model)
        if part and HomeAnchor and (part.Position - HomeAnchor.Position).Magnitude > 55 then
            table.insert(others, p)
        end
    end
    if #others == 0 then return {} end
    local function val(p)
        if p.rarity > 0 then return p.rarity, 2 end
        if p.income > 0 then return p.income, 1 end
        return p.score, 0
    end
    table.sort(others, function(a, b)
        local va, ta = val(a); local vb, tb = val(b)
        if ta ~= tb then return ta > tb end
        return va > vb
    end)
    return others
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
local function stealNearby(radius)
    local r = getRoot(); if not r then return false end
    local fired = false
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local ok, inRange = pcall(function()
                local ad = d.Adornee; if not ad then return false end
                local pos = ad:IsA("BasePart") and ad.Position or (ad.PrimaryPart and ad.PrimaryPart.Position)
                return pos and (pos - r.Position).Magnitude <= radius
            end)
            if ok and inRange and isStealPrompt(d) then
                pcall(function() d.HoldDuration = 0 end)
                if firePrompt(d) then fired = true end
                task.wait(0.3)
            end
        end
    end
    return fired
end

--// ================================================================
--// GUI (same shell, v4 controls)
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
logo.BackgroundTransparency = 1; logo.Text = "VORTEX  HUB  v4"
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
local tabLayout = Instance.new("UIListLayout", sidebar)
tabLayout.Padding = UDim.new(0, 4)
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
toggle(pageMain, "Velocidad (mild)", T.Velocidad, function(on) T.Velocidad = on end)
slider(pageMain, "Walk speed (cap 40 in ghost)", 16, 60, T.Speed, function(v) T.Speed = v end)
toggle(pageMain, "Wall climb", T.WallClimb, function(on) T.WallClimb = on end)
section(pageMain, "VISUALS")
toggle(pageMain, "ESP pets (rarity)", T.ESPPets, function(on) T.ESPPets = on; if not on then clearESP() end end)
toggle(pageMain, "Xray walls", T.Xray, function(on) T.Xray = on; if not on then resetXray() end end)
toggle(pageMain, "FPS boost", T.FPSBoost, function(on) T.FPSBoost = on; applyFPS(on) end)

section(pageSteal, "FLASH STEAL v4")
toggle(pageSteal, "Insta steal", T.InstaSteal, function(on) T.InstaSteal = on end)
button(pageSteal, "GUARDAR POSICIÓN", function()
    local r = getRoot(); if not r then return end
    SavedReturn = r.CFrame
    notify("VORTEX", "return point saved", Color3.fromRGB(120, 255, 160))
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
        notify("VORTEX", "scanning rarest pet...", ACC2)
        local ranked = rankedPets()
        if #ranked == 0 then
            notify("VORTEX", "no pets found", Color3.fromRGB(255, 100, 100))
            BUSY = false; return
        end
        -- humans don't always take the #1: 10% take second
        local pick = ranked[1]
        if #ranked > 1 and math.random() < 0.1 then pick = ranked[2] end
        local info = pick.model.Name
        if pick.rarity > 0 then info = info .. " · " .. fmtRarity(pick.rarity) end
        notify("FLASH", "-> " .. info, ACC1)
        local part = getPetPart(pick.model)

        local res = travelTo(part.CFrame.Position + (r.Position - part.CFrame.Position).Unit * 9)
        if res == "wall" then
            notify("VORTEX", "wall — gear breach", ACC2)
            breachTo(part)
        end

        task.wait(humanDelay(0.25, 0.7)) -- human reaction before steal
        stealNearby(18)
        waitForHand(pick.model, 3)
        task.wait(humanDelay(0.8, 1.6)) -- secure rhythm

        travelTo(SavedReturn.Position)
        sessionSteals = sessionSteals + 1
        nextStealAt = os.clock() + humanDelay(60, 120)
        notify("VORTEX", "home · " .. info, Color3.fromRGB(120, 255, 160))
        BUSY = false
    end)
end, true)
button(pageSteal, "GO HOME", function()
    local target = SavedReturn or HomeAnchor
    if target then travelTo(target.Position) end
end)

section(pageSet, "STEALTH PROFILE")
local profileBtns = {}
local function setProfile(name)
    T.Profile = name
    for n, b in pairs(profileBtns) do
        b.BackgroundColor3 = (n == name) and ACC1 or BG2
    end
    notify("PROFILE", name, ACC2)
end
for i, name in ipairs({ "WALK", "GHOST", "FLASH" }) do
    local b = button(pageSet, name, function() setProfile(name) end)
    b.Size = UDim2.new(0.31, 0, 0, 30)
    b.Position = UDim2.new(0.02 + (i - 1) * 0.33, 0, 0, 0)
    profileBtns[name] = b
end
section(pageSet, "HUMANIZER")
slider(pageSet, "Steals per session", 1, 6, T.StealCap, function(v) T.StealCap = v end)
section(pageSet, "SAFETY")
button(pageSet, "BURN (K) — clean exit", function() burn() end)
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
local espBB, xrayT, fpsT = {}, {}, {}
function clearESP()
    for _, b in pairs(espBB) do pcall(function() b:Destroy() end) end
    espBB = {}
end
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
    if isStealPrompt(prompt) then
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
        local cap = T.Profile == "GHOST" and math.min(T.Speed, 40) or T.Speed
        if T.Velocidad and hum.WalkSpeed ~= cap then hum.WalkSpeed = cap end
        if not T.Velocidad and hum.WalkSpeed ~= ORIG_SPEED then hum.WalkSpeed = ORIG_SPEED end
        if T.WallClimb then
            local r = char:FindFirstChild("HumanoidRootPart")
            if r and hum.MoveDirection.Magnitude > 0 then
                local hit = Workspace:Raycast(r.Position, hum.MoveDirection * 2.5, charRayParams())
                if hit then r.CFrame = r.CFrame + Vector3.new(0, 0.35, 0) end
            end
        end
    end)
end)

task.spawn(function()
    while ALIVE do
        task.wait(1)
        pcall(function()
            if T.ESPPets then
                for _, p in ipairs(scanPets()) do
                    local part = getPetPart(p.model)
                    if part then
                        local key = "pet_" .. p.model:GetDebugId()
                        local b = espBB[key]
                        if not b then
                            b = Instance.new("BillboardGui")
                            b.Size = UDim2.new(0, 150, 0, 26)
                            b.StudsOffset = Vector3.new(0, 3, 0)
                            b.AlwaysOnTop = true
                            local l = Instance.new("TextLabel")
                            l.Size = UDim2.new(1, 0, 1, 0)
                            l.BackgroundTransparency = 1
                            l.Font = Enum.Font.GothamBold
                            l.TextSize = 12
                            l.TextStrokeTransparency = 0.2
                            l.Parent = b
                            b.Parent = part
                            espBB[key] = b
                        end
                        local label = p.model.Name
                        local col = Color3.fromRGB(200, 200, 200)
                        if p.rarity > 0 then
                            label = label .. " " .. fmtRarity(p.rarity)
                            col = p.rarity >= 1e9 and Color3.fromRGB(255, 200, 40) or Color3.fromRGB(120, 255, 160)
                        elseif p.income > 0 then
                            label = label .. " $" .. p.income .. "/s"
                            col = ACC2
                        end
                        b.TextLabel.Text = label
                        b.TextLabel.TextColor3 = col
                    end
                end
            end
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
    clearESP(); resetXray(); applyFPS(false)
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
setProfile("GHOST")
task.spawn(function()
    getRoot(); HomeAnchor = getRoot().CFrame
    notify("VORTEX v4", "ghost mover live · K = burn", Color3.fromRGB(120, 255, 160))
end)
