--[[
================================================================================
 SCRIPT_PHAN_TICH_GAME.lua
 Roblox Deep Game Analyzer — AI Context Builder (bản chạy trên Xeno / Studio)
--------------------------------------------------------------------------------
 CÁCH DÙNG TRÊN XENO (copy-paste):
   1. Mở Xeno, join game BẠN SỞ HỮU hoặc ĐƯỢC CẤP QUYỀN kiểm tra.
   2. Copy TOÀN BỘ file này, dán vào ô Execute của Xeno, bấm Execute.
   3. Đợi log chạy: [1/4] CONNECT -> [2/4] GET DATA -> [3/4] PROCESS
      -> [4/4] EXPORT. Script tự lưu file + copy Markdown nếu Xeno hỗ trợ.
   4. Muốn DỪNG giữa chừng: dán dòng này vào Xeno rồi Execute:
        _G.STOP_PHANTICH = true
   5. Muốn chạy lại từng bước thủ công:
        _G.PhanTichGame.GET_DATA()
        _G.PhanTichGame.PROCESS()
        _G.PhanTichGame.COPY_FOR_AI()
        _G.PhanTichGame.EXPORT_FILE()

 CHẠY TRÊN ROBLOX STUDIO (khuyến nghị nếu là game của bạn):
   - Mở Studio -> View -> Command Bar, paste toàn bộ file, Enter.
   - Trong Studio mà bạn là owner thì script ĐỌC ĐƯỢC Source
     (SOURCE_CONFIRMED). Trên Xeno/client live thì Source của
     ServerScript bị che -> script tự đánh dấu UNAVAILABLE,
     KHÔNG bịa source, KHÔNG decompile trộm.

 NGUYÊN TẮC BẮT BUỘC (script tự tuân thủ):
   - Chỉ đọc những gì client nhìn thấy (GetDescendants).
   - KHÔNG FireServer / InvokeServer để thử nghiệm.
   - KHÔNG đọc/vượt quyền ServerStorage/ServerScriptService từ client.
   - KHÔNG đánh cắp thông tin xác thực, KHÔNG đọc bộ nhớ trái phép.
   - KHÔNG tuyên bố đã đọc source nếu chỉ có tên object.
   - Mọi kết luận gắn nhãn: SOURCE_CONFIRMED / INFERRED / UNKNOWN / UNAVAILABLE.
   - Nếu thiếu source, script ghi rõ file nào cần bạn bổ sung trong Studio.
================================================================================
]]

--// ============================== 1. CẤU HÌNH ==============================
local CONFIG = {
    MAX_NODES       = 10000,   -- giống file cautruc.txt mẫu (total_nodes)
    MAX_DEPTH       = 7,       -- sâu tối đa của cây structure
    MAX_WORKSPACE   = 2000,    -- giới hạn Workspace để không treo game
    MAX_SOURCE_LEN  = 20000,   -- chỉ parse tối đa từng này ký tự / script (Studio)
    MAX_SNIPPET     = 300,     -- độ dài trích đoạn evidence
    CHUNK_WARN      = 180000,  -- quá số ký tự này thì chia file, không cắt lén
    SCAN_SERVICES   = {        -- service được phép quét từ client
        "Workspace",
        "ReplicatedStorage",
        "ReplicatedFirst",
        "StarterPlayer",
        "StarterGui",
        "StarterPack",
        "Lighting",
        "SoundService",
        "Players",
    },
    SKIP_IN_WORKSPACE = { Terrain = true, Camera = true },
    AUTO_RUN        = true,    -- true = paste vào là chạy full pipeline
    AUTO_COPY       = true,    -- tự setclipboard Markdown nếu được
    AUTO_WRITEFILE  = true,    -- tự writefile JSON + MD nếu executor hỗ trợ
    FILE_JSON       = "phan_tich_game.json",
    FILE_MD         = "AI_CONTEXT.md",
}

--// ============================== 2. STATE / LOG ==============================
_G.STOP_PHANTICH = false
local State = {
    Status = "Idle", -- Idle | Connected | Collecting | Processing | Completed | Failed | Cancelled
    Logs = {},
    Errors = {},
    StartTime = os.clock(),
    Counts = { nodes = 0, scripts = 0, remotes = 0, prompts = 0, tools = 0, funcs = 0, requires = 0 },
    Data = nil,
    Analysis = nil,
    Markdown = "",
}
local function setStatus(s)
    State.Status = s
    print("[PhanTich] Status = " .. s)
end
local function log(msg)
    table.insert(State.Logs, msg)
    print("[PhanTich] " .. msg)
end
local function logErr(msg)
    table.insert(State.Errors, msg)
    warn("[PhanTich][LOI] " .. msg)
end
local function stopped()
    return _G.STOP_PHANTICH == true
end

--// ============================== 3. UTILS ==============================
local function safeFullName(inst)
    local ok, res = pcall(function() return inst:GetFullName() end)
    if ok and type(res) == "string" then return res end
    local ok2, res2 = pcall(function() return inst.Name end)
    return if ok2 then tostring(res2) else "UNKNOWN"
end
local function esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return s
end
local function mdEsc(s)
    s = tostring(s or "")
    s = s:gsub("`", "'"):gsub("|", "/")
    return s
end
local function truncate(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n) .. "...(cat " .. (#s - n) .. " ky tu)" end
    return s
end
local function estimateTokens(s) return math.floor(#tostring(s or "") / 4) end
local function hasFn(fnName)
    return typeof(_G[fnName]) == "function" or typeof(getgenv and getgenv()[fnName] or nil) == "function"
        or (typeof(_G.getgenv) == "function" and false)
end
-- kiểm tra hàm executor an toàn (không lỗi nếu không tồn tại)
local function exFn(name)
    local ok, v = pcall(function() return rawget(getgenv and getgenv() or _G, name) end)
    if ok and type(v) == "function" then return v end
    local ok2, v2 = pcall(function() return _G[name] end)
    if ok2 and type(v2) == "function" then return v2 end
    -- thử global trực tiếp (Xeno thường đặt global writefile/setclipboard)
    local g = getfenv and getfenv(0) or _G
    if type(g[name]) == "function" then return g[name] end
    return nil
end
local function shortProps(inst)
    local props = {}
    local function tryRead(prop)
        local ok, v = pcall(function() return inst[prop] end)
        if ok and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
            local s = tostring(v)
            if #s < 200 then props[prop] = v end
        end
    end
    tryRead("Enabled"); tryRead("Disabled"); tryRead("Value")
    tryRead("Health"); tryRead("MaxHealth"); tryRead("WalkSpeed"); tryRead("JumpPower")
    tryRead("Text"); tryRead("Visible"); tryRead("Image")
    return props
end

--// ============================== 4. CONNECT SOURCE ==============================
local function CONNECT_SOURCE()
    setStatus("Connected")
    log("CONNECT SOURCE OK. Nguon = client hien tai (quyen client).")
    log("Luu y: ServerStorage / ServerScriptService tu client la UNAVAILABLE (Roblox che).")
    local okGS, gs = pcall(function() return game:GetService("ReplicatedStorage") end)
    if not okGS then logErr("Khong truy cap duoc ReplicatedStorage."); setStatus("Failed"); return false end
    return true
end

--// ============================== 5. GET DATA ==============================
local Collected = {
    meta = {}, client_scripts = {}, remotes = {}, prompts = {},
    tools = {}, player = {}, workspace_info = {},
    structure = {}, source_inventory = {},
}
local nodeCount = 0

local function getMeta()
    local meta = {}
    local ok, appInfo = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
    end)
    meta.GameName = (ok and appInfo and appInfo.Name) or game.Name or "UNKNOWN"
    meta.GameId, meta.PlaceId = game.GameId, game.PlaceId
    local okJ, job = pcall(function() return game.JobId end)
    meta.JobId = (okJ and job) or "UNKNOWN"
    meta.Time = os.date("%Y-%m-%d %H:%M")
    local okC, creator = pcall(function()
        local pid = if ok and appInfo then appInfo.Creator and appInfo.Creator.CreatorTargetId else nil
        if pid then return game:GetService("Players"):GetNameFromUserIdAsync(pid) end
        return nil
    end)
    meta.Creator = (okC and creator) or "UNKNOWN (client khong co quyen doc CreatorType)"
    local okS, isStudio = pcall(function() return game:GetService("RunService"):IsStudio() end)
    meta.RunEnv = (okS and isStudio) and "Roblox Studio (co the doc Source neu la owner)"
        or "Live Client / Xeno (chi doc duoc ten + thuoc tinh client thay duoc)"
    meta.AccessScope = "client-visible only. Server source = UNAVAILABLE tu client."
    return meta
end

-- đọc Source CHỈ khi engine cho phép (Studio owner). Client live -> UNAVAILABLE.
local function tryReadSource(inst)
    local ok, src = pcall(function() return inst.Source end)
    if ok and type(src) == "string" and #src > 0 then
        return src, "SOURCE_CONFIRMED"
    end
    return nil, "UNAVAILABLE"
end

local function classifyAndStore(inst, path, depth)
    if stopped() then return "stop" end
    if nodeCount >= CONFIG.MAX_NODES then return "limit" end
    nodeCount += 1
    State.Counts.nodes = nodeCount
    local okClass, className = pcall(function() return inst.ClassName end)
    className = (okClass and className) or "UNKNOWN"
    local okName, iName = pcall(function() return inst.Name end)
    iName = (okName and iName) or "UNKNOWN"

    -- phân loại
    local okIsA = nil
    if className == "Script" or className == "LocalScript" or className == "ModuleScript" then
        table.insert(Collected.client_scripts, { class = className, name = iName, path = path })
        State.Counts.scripts += 1
        -- thử đọc source (Studio mới được)
        local src, level = tryReadSource(inst)
        table.insert(Collected.source_inventory, {
            path = path, class = className, name = iName,
            source_status = level,
            source_len = if src then #src else 0,
            _src = src, -- giữ tạm để PROCESS parse, lúc export sẽ xóa
        })
    elseif className == "RemoteEvent" or className == "RemoteFunction"
        or className == "BindableEvent" or className == "BindableFunction" then
        table.insert(Collected.remotes, { class = className, name = iName, path = path })
        State.Counts.remotes += 1
    elseif className == "ProximityPrompt" then
        local okP, objId = pcall(function() return inst.ObjectText end)
        table.insert(Collected.prompts, { class = className, name = iName, path = path,
            objectText = (okP and tostring(objId)) or "" })
        State.Counts.prompts += 1
    elseif className == "Tool" then
        table.insert(Collected.tools, { class = className, name = iName, path = path })
        State.Counts.tools += 1
    end
    return className
end

-- dựng node structure đệ quy (giới hạn depth để không nổ file)
local function buildNode(inst, path, depth)
    if depth > CONFIG.MAX_DEPTH then
        return { class = inst.ClassName, name = inst.Name, path = path, props = {}, children = "{... sau hon " .. CONFIG.MAX_DEPTH .. " tang: xem client_scripts/remotes}" }
    end
    if nodeCount >= CONFIG.MAX_NODES then return nil end
    local className = classifyAndStore(inst, path, depth)
    if className == "stop" or className == "limit" then return nil end
    local node = { class = className, name = inst.Name, path = path, props = shortProps(inst) }
    -- attributes + tags (nếu source cho phép)
    local okA, attrs = pcall(function() return inst:GetAttributes() end)
    if okA and type(attrs) == "table" and next(attrs) ~= nil then node.props._attr = attrs end
    local okT, tags = pcall(function() return inst:GetTags() end)
    if okT and type(tags) == "table" and #tags > 0 then node.props._tags = tags end
    local okC, children = pcall(function() return inst:GetChildren() end)
    if okC and type(children) == "table" and #children > 0 then
        node.children = {}
        for _, ch in ipairs(children) do
            if stopped() then break end
            if nodeCount >= CONFIG.MAX_NODES then
                table.insert(node.children, { class = "...", name = "TRUNCATED", path = path .. " (da dat gioi han " .. CONFIG.MAX_NODES .. " nodes)" })
                break
            end
            -- bỏ qua Terrain/Camera trong Workspace cho nhẹ
            if path:find("^Workspace") and CONFIG.SKIP_IN_WORKSPACE[ch.Name] then continue end
            local chPath = path .. "." .. ch.Name
            local cn = buildNode(ch, chPath, depth + 1)
            if cn then table.insert(node.children, cn) end
            if nodeCount % 1500 == 0 then task.wait() end
        end
    end
    return node
end

local function GET_DATA()
    if not CONNECT_SOURCE() then return false end
    setStatus("Collecting")
    State.StartTime = os.clock()
    _G.STOP_PHANTICH = false
    log("[2/4] GET DATA: dang quet " .. #CONFIG.SCAN_SERVICES .. " service (gioi han " .. CONFIG.MAX_NODES .. " nodes)...")
    Collected.meta = getMeta()
    local okP, lp = pcall(function() return game:GetService("Players").LocalPlayer end)
    if okP and lp then
        local okB, bp = pcall(function() return lp:FindFirstChildOfClass("Backpack") end)
        local tools = {}
        if okB and bp then
            for _, t in ipairs(bp:GetChildren()) do table.insert(tools, t.Name) end
        end
        Collected.player = { Name = lp.Name, DisplayName = lp.DisplayName, UserId = lp.UserId, Backpack = tools }
    else
        Collected.player = { Name = "UNKNOWN", DisplayName = "UNKNOWN", UserId = 0, Backpack = {} }
    end
    local okW, ws = pcall(function() return game:GetService("Workspace") end)
    if okW then
        local okG, grav = pcall(function() return ws.Gravity end)
        local okS, stream = pcall(function() return ws.StreamingEnabled end)
        Collected.workspace_info = { Gravity = (okG and grav) or "UNKNOWN", Streaming = tostring((okS and stream) or "UNKNOWN") }
    end
    Collected.structure = {}
    for _, svcName in ipairs(CONFIG.SCAN_SERVICES) do
        if stopped() then setStatus("Cancelled"); log("Da STOP theo yeu cau."); return false end
        local okS, svc = pcall(function() return game:GetService(svcName) end)
        if not okS or not svc then
            logErr("Khong truy cap " .. svcName .. " (UNAVAILABLE tu client).")
            continue
        end
        -- Workspace giới hạn riêng
        local hardBefore = nodeCount
        log("  + Quet " .. svcName .. "...")
        local okC, children = pcall(function() return svc:GetChildren() end)
        local svcNode = { class = svcName, name = svcName, children = {} }
        if okC then
            local budget = if svcName == "Workspace" then CONFIG.MAX_WORKSPACE else CONFIG.MAX_NODES
            local scannedThis = 0
            for _, ch in ipairs(children) do
                if stopped() then break end
                if nodeCount >= CONFIG.MAX_NODES or (nodeCount - hardBefore) >= budget then
                    table.insert(svcNode.children, { class = "...", name = "TRUNCATED_" .. svcName, path = svcName .. " (gioi han, con lai xem client_scripts)" })
                    break
                end
                local cn = buildNode(ch, svcName .. "." .. ch.Name, 1)
                if cn then table.insert(svcNode.children, cn) end
                scannedThis += 1
                if scannedThis % 800 == 0 then task.wait() end
            end
        end
        Collected.structure[svcName] = svcNode
        log("    -> " .. svcName .. ": +" .. (nodeCount - hardBefore) .. " nodes (tong " .. nodeCount .. ").")
        task.wait()
    end
    State.Data = Collected
    local dt = math.floor(os.clock() - State.StartTime)
    log(string.format("GET DATA xong: %d nodes | %d scripts | %d remotes | %d prompts | %d tools | %ds",
        nodeCount, #Collected.client_scripts, #Collected.remotes, #Collected.prompts, #Collected.tools, dt))
    if nodeCount >= CONFIG.MAX_NODES then
        log("Luu y: da dat gioi han total_nodes=" .. CONFIG.MAX_NODES .. " (giong file cautruc.txt mau: truncated=true).")
    end
    return true
end

--// ============================== 6. PROCESS (phân tích logic) ==============================
local Analysis = {
    architecture = {}, functions = {}, events = {},
    gameplay = {}, evidence = {}, gaps = {},
}

local function parseSource(path, class, src)
    local funcs, requires, remoteUses = {}, {}, {}
    local lineNo = 0
    for line in (src .. "\n"):gmatch("(.-)\n") do
        lineNo += 1
        -- hàm
        local fn = line:match("^%s*function%s+([%w_%.%:]+)%s*%(")
            or line:match("^%s*local%s+function%s+([%w_]+)%s*%(")
            or line:match("^%s*([%w_%.%:]+)%s*=%s*function%s*%(")
        if fn then
            local params = line:match("%((.-)%)") or ""
            table.insert(funcs, { name = fn, file = path, class = class, line = lineNo,
                params = truncate(params, 200), snippet = truncate(line:gsub("^%s+", ""), CONFIG.MAX_SNIPPET),
                confidence = "SOURCE_CONFIRMED" })
        end
        -- require
        for req in line:gmatch("require%s*%(%s*(.-)%s*%)") do
            table.insert(requires, { file = path, line = lineNo, expr = truncate(req, 150), snippet = truncate(line:gsub("^%s+", ""), 200) })
        end
        -- remote sử dụng (chỉ ghi khi thấy trong source thật)
        if line:find("FireServer") or line:find("InvokeServer") or line:find("FireClient")
            or line:find("OnServerEvent") or line:find("OnClientEvent") or line:find("FireAllClients") then
            table.insert(remoteUses, { file = path, line = lineNo, snippet = truncate(line:gsub("^%s+", ""), 200) })
        end
    end
    return funcs, requires, remoteUses
end

local GAMEPLAY_RULES = {
    { key = "character_lifecycle", label = "Character lifecycle (Spawn/Despawn)",
      kw = { "CharacterAdded", "CharacterRemoving", "LoadCharacter", "PlayerAdded" } },
    { key = "health_damage", label = "Health / Damage",
      kw = { "Humanoid", "Health", "TakeDamage", "BreakJoints", "MaxHealth" } },
    { key = "downed_death_revive", label = "Downed / Death / Revive (CANH BAO: can nhieu bang chung)",
      kw = { "Downed", "Down", "Revive", "Carry", "Drag", "BleedOut" } },
    { key = "carry_rescue", label = "Carry / Rescue",
      kw = { "Carry", "Drag", "Pickup", "Drop", "Carrying" } },
    { key = "movement", label = "Movement (Walk/Jump/Sprint)",
      kw = { "WalkSpeed", "JumpPower", "Sprint", "Stamina", "HumanoidRootPart", "Velocity" } },
    { key = "tools_inventory", label = "Tools / Inventory",
      kw = { "Backpack", "Tool", "Equip", "Unequip", "Activated", "Inventory" } },
    { key = "interaction", label = "Interaction / Distance validation",
      kw = { "ProximityPrompt", "Triggered", "HoldDuration", "MaxActivationDistance", "Magnitude" } },
    { key = "animation", label = "Animation",
      kw = { "Animator", "LoadAnimation", "AnimationTrack", "PlayEmote", "Animate" } },
    { key = "ui_sync", label = "UI / State sync",
      kw = { "ChangedEvent", "GetPropertyChangedSignal", "TweenService", "UpdateClient", "StateRegistry" } },
}

local function PROCESS()
    setStatus("Processing")
    if not State.Data then logErr("Chua GET DATA. Hay chay GET DATA truoc."); setStatus("Failed"); return false end
    log("[3/4] PROCESS: dang phan tich logic (khong Fire remote, chi doc)...")
    local allFuncs, allRequires, allRemoteUses = {}, {}, {}
    local confirmedSrc, unaSrc = 0, 0
    for _, inv in ipairs(Collected.source_inventory) do
        if stopped() then setStatus("Cancelled"); return false end
        if inv._src then
            confirmedSrc += 1
            local f, r, u = parseSource(inv.path, inv.class, inv._src:sub(1, CONFIG.MAX_SOURCE_LEN))
            for _, v in ipairs(f) do table.insert(allFuncs, v) end
            for _, v in ipairs(r) do table.insert(allRequires, v) end
            for _, v in ipairs(u) do table.insert(allRemoteUses, v) end
        else
            unaSrc += 1
        end
        if (#allFuncs + confirmedSrc) % 500 == 0 then task.wait() end
    end
    State.Counts.funcs = #allFuncs
    State.Counts.requires = #allRequires

    -- A. Architecture Map
    local folders, importants, unknowns = {}, {}, {}
    for _, s in ipairs(Collected.client_scripts) do
        local top = s.path:match("^([^%.]+)%.?") or "UNKNOWN"
        folders[top] = (folders[top] or 0) + 1
        if s.name == "Bootstrap" or s.name == "Core" or s.name == "Main" or s.name == "Init"
            or s.name == "GameManager" or s.name:find("Service") then
            table.insert(importants, s)
        end
    end
    if unaSrc > 0 then
        table.insert(unknowns, "Thieu source cua " .. unaSrc .. " scripts (client live khong doc duoc Source). Can mo Studio project goc de bo sung. Trang thai: UNAVAILABLE.")
    end
    if nodeCount >= CONFIG.MAX_NODES then
        table.insert(unknowns, "Cay bi cat o " .. CONFIG.MAX_NODES .. " nodes (truncated=true). Cac nhanh con lai la UNKNOWN.")
    end
    Analysis.architecture = { folders = folders, importants = importants, unknowns = unknowns,
        requires = allRequires, confirmedSrc = confirmedSrc, unaSrc = unaSrc }

    -- B. Function Map (chi khi co source that)
    Analysis.functions = allFuncs

    -- C. Event map (khai bao vs su dung phan biet ro)
    local eventRows = {}
    for _, r in ipairs(Collected.remotes) do
        local uses = {}
        for _, u in ipairs(allRemoteUses) do
            if u.snippet:find(r.name, 1, true) then table.insert(uses, u) end
        end
        table.insert(eventRows, { class = r.class, name = r.name, path = r.path,
            declared_at = r.path .. " (SOURCE_CONFIRMED: thay Instance that)",
            used_at = if #uses > 0 then uses else "UNKNOWN (khong thay noi goi trong source hien co)",
            params = if #uses > 0 then "xem snippet tung dong (SOURCE_CONFIRMED)" else "UNKNOWN (khong bia args)" })
    end
    Analysis.events = eventRows

    -- D. Gameplay map (than trong, co che revive)
    local gameplay = {}
    -- gom text de tim keyword: ten path + snippet source (neu co)
    local haystack = ""
    for _, s in ipairs(Collected.client_scripts) do haystack ..= " " .. s.path .. " " .. s.name end
    for _, r in ipairs(Collected.remotes) do haystack ..= " " .. r.path end
    for _, f in ipairs(allFuncs) do haystack ..= " " .. f.name .. " " .. f.snippet end
    for _, rule in ipairs(GAMEPLAY_RULES) do
        local hits, ev = {}, {}
        for _, k in ipairs(rule.kw) do
            if haystack:find(k, 1, true) then table.insert(hits, k) end
        end
        local status, note
        if #hits == 0 then
            status, note = "UNKNOWN", "Khong thay dau hieu trong du lieu hien co."
        elseif rule.key == "downed_death_revive" then
            -- quy tac chat: khong ket luan revive chi vi thay Carry/Interact
            local hasRevive = haystack:find("Revive", 1, true) ~= nil
            local hasDown = (haystack:find("Downed", 1, true) or haystack:find("Down", 1, true)) ~= nil
            if hasRevive and hasDown and confirmedSrc > 0 then
                status, note = "INFERRED", "Thay ca Revive + Downed nhung can doc source day du moi xac nhan."
            else
                status, note = "INFERRED", "Chi thay le te (" .. table.concat(hits, ", ") .. "). KHONG ket luan co Revive chi vi thay Carry/Interact."
            end
        elseif confirmedSrc > 0 and #hits >= 2 then
            status, note = "INFERRED", "Co " .. #hits .. " dau hieu, can doi chieu source Studio."
        else
            status, note = "INFERRED", "Chi suy tu ten object (" .. table.concat(hits, ", ") .. "), chua co source."
        end
        table.insert(gameplay, { key = rule.key, label = rule.label, hits = hits, status = status, note = note })
    end
    Analysis.gameplay = gameplay

    -- E. Evidence & Gap
    Analysis.evidence = {}
    for i = 1, math.min(40, #allFuncs) do
        local f = allFuncs[i]
        table.insert(Analysis.evidence, { what = "Ham " .. f.name, where = f.file .. ":" .. f.line,
            snippet = f.snippet, level = "SOURCE_CONFIRMED" })
    end
    for _, r in ipairs(Collected.remotes) do
        if #Analysis.evidence >= 80 then break end
        table.insert(Analysis.evidence, { what = r.class .. " " .. r.name, where = r.path,
            snippet = "Instance that, chua ro args (khong bia)", level = "SOURCE_CONFIRMED (ton tai) / UNKNOWN (args)" })
    end
    local gaps = {}
    if unaSrc > 0 then table.insert(gaps, "Can mo Studio project goc de lay Source cua " .. unaSrc .. " scripts (hien UNAVAILABLE).")
    else table.insert(gaps, "Da co Source trong Studio (" .. confirmedSrc .. " files). Van can kiem tra them ServerScriptService.") end
    table.insert(gaps, "Khong tu Fire Remote de test (theo quy tac). Muon biet args phai doc source day du.")
    table.insert(gaps, "ServerStorage/ServerScriptService tu client la UNAVAILABLE — can quyen owner trong Studio.")
    Analysis.gaps = gaps

    State.Analysis = Analysis
    log(string.format("PROCESS xong: %d ham | %d requires | %d events | source that %d / thieu %d.",
        #allFuncs, #allRequires, #eventRows, confirmedSrc, unaSrc))
    return true
end

--// ============================== 7. COPY FOR AI (Markdown 11 mục) ==============================
local function buildMarkdown()
    local D, A = State.Data, State.Analysis
    local L = {}
    local function add(s) table.insert(L, s) end
    local dt = math.floor(os.clock() - State.StartTime)
    add("# ROBLOX PROJECT ANALYSIS CONTEXT")
    add("")
    add("> Goi du lieu co cau truc de dan vao ChatGPT / Claude / AI lap trinh. Nguyen tac: phan biet FACT vs INFERENCE, khong bia source/args.")
    add("")
    add("## 1. Project Metadata")
    add("- Ten project: " .. mdEsc(D.meta.GameName or "UNKNOWN"))
    add("- GameId: `" .. tostring(D.meta.GameId or "?") .. "` | PlaceId: `" .. tostring(D.meta.PlaceId or "?") .. "` | JobId: `" .. tostring(D.meta.JobId or "?") .. "`")
    add("- Creator: " .. mdEsc(D.meta.Creator or "UNKNOWN"))
    add("- Thoi gian phan tich: " .. tostring(D.meta.Time or "?") .. " | Thoi gian chay: " .. dt .. "s")
    add("- Moi truong thu thap: " .. mdEsc(D.meta.RunEnv or "?"))
    add("- Pham vi quyen: " .. mdEsc(D.meta.AccessScope or "client-visible only"))
    add("- Nguon du lieu: Xeno/live client dump (ten + thuoc tinh thay duoc) " .. if Analysis.architecture.confirmedSrc and Analysis.architecture.confirmedSrc > 0 then "+ Studio Source (" .. Analysis.architecture.confirmedSrc .. " files)" else "(khong kem Server Source)")
    add("")
    add("## 2. Executive Summary")
    add("- Tong nodes: **" .. nodeCount .. "** | Scripts: **" .. #D.client_scripts .. "** | Remotes/Bindables: **" .. #D.remotes .. "** | Prompts: **" .. #D.prompts .. "** | Tools: **" .. #D.tools .. "**")
    add("- Ham tim duoc trong source that: **" .. #A.functions .. "** | require: **" .. #A.architecture.requires .. "**")
    local svcList = {}
    for k, _ in pairs(D.structure) do table.insert(svcList, k) end
    add("- Service quet duoc: " .. table.concat(svcList, ", "))
    add("- Module quan trong: " .. if #A.architecture.importants > 0 then (function()
        local t = {} for i = 1, math.min(10, #A.architecture.importants) do table.insert(t, "`" .. A.architecture.importants[i].path .. "`") end return table.concat(t, ", ") end)() else "UNKNOWN (chua xac dinh duoc entry point)"
    )
    add("- Trang thai source: " .. (A.architecture.confirmedSrc or 0) .. " SOURCE_CONFIRMED / " .. (A.architecture.unaSrc or 0) .. " UNAVAILABLE (can bo sung Studio).")
    add("")
    add("## 3. Instance Hierarchy")
    add("```")
    local shown = 0
    for svcName, svcNode in pairs(D.structure) do
        if svcNode.children then
            for _, ch in ipairs(svcNode.children) do
                shown += 1
                if shown > 400 then add("... (con " .. (nodeCount - shown) .. " nodes. Xem file JSON day du)") break end
                add(svcName .. "." .. tostring(ch.name) .. " [" .. tostring(ch.class) .. "] path=" .. tostring(ch.path or ch.name))
            end
        end
        if shown > 400 then break end
    end
    add("```")
    add("_Giu nguyen duong dan va ten object. Cay day du trong file JSON kem theo._")
    add("")
    add("## 4. Source Inventory")
    add("| File/Path | Loai | Trang thai doc source | Do day du |")
    add("|---|---|---|---|")
    for i, inv in ipairs(D.source_inventory) do
        if i > 200 then add("| ... | ... | con " .. (#D.source_inventory - 200) .. " dong trong JSON | |") break end
        add("| `" .. mdEsc(inv.path) .. "` | " .. inv.class .. " | " .. inv.source_status .. " | " .. (if inv._src then tostring(inv.source_len) .. " chars" else "0 (can bo sung)") .. " |")
    end
    add("")
    add("## 5. Module and Dependency Map")
    local fkeys = {}
    for k, v in pairs(A.architecture.folders) do table.insert(fkeys, k .. "(" .. v .. ")") end
    add("- Cay thu muc (top-level): " .. table.concat(fkeys, ", "))
    add("- Entry point du doan (INFERRED): " .. if #A.architecture.importants > 0 then "`" .. A.architecture.importants[1].path .. "`" else "UNKNOWN")
    add("- Quan he require (SOURCE_CONFIRMED, toi da 60):")
    if #A.architecture.requires == 0 then
        add("  - UNKNOWN (khong co source de trich require; khong doan dai)")
    else
        for i, r in ipairs(A.architecture.requires) do
            if i > 60 then add("  - ... con " .. (#A.architecture.requires - 60) .. " requires trong JSON") break end
            add("  - `" .. mdEsc(r.file) .. "`:" .. r.line .. " require(" .. mdEsc(r.expr) .. ")")
        end
    end
    for _, u in ipairs(A.architecture.unknowns) do add("- [UNKNOWN] " .. mdEsc(u)) end
    add("")
    add("## 6. Function Index")
    add("| Ham | File | Tham so | Do tin cay |")
    add("|---|---|---|---|")
    if #A.functions == 0 then
        add("| (khong co) | can mo Studio lay Source | — | UNAVAILABLE |")
    else
        for i, f in ipairs(A.functions) do
            if i > 150 then add("| ... | con " .. (#A.functions - 150) .. " ham trong JSON | | |") break end
            add("| `" .. mdEsc(f.name) .. "` | `" .. mdEsc(f.file) .. "`:" .. f.line .. " | `" .. mdEsc(f.params) .. "` | " .. f.confidence .. " |")
        end
    end
    add("")
    add("## 7. Event and Remote Interface Index")
    add("| Class | Name | Khai bao | Su dung | Tham so |")
    add("|---|---|---|---|---|")
    for i, e in ipairs(A.events) do
        if i > 120 then add("| ... | con " .. (#A.events - 120) .. " remotes trong JSON | | | |") break end
        local used = if type(e.used_at) == "table" then #e.used_at .. " noi goi (xem JSON)" else tostring(e.used_at)
        add("| " .. e.class .. " | `" .. mdEsc(e.name) .. "` | `" .. mdEsc(e.declared_at) .. "` | " .. mdEsc(used) .. " | " .. mdEsc(e.params) .. " |")
    end
    add("_Khong tu Fire Remote de test. Chi ghi args khi source xac nhan._")
    add("")
    add("## 8. Gameplay Systems")
    for _, g in ipairs(A.gameplay) do
        add("### " .. g.label .. " [" .. g.status .. "]")
        add("- Dau hieu: " .. if #g.hits > 0 then "`" .. table.concat(g.hits, "`, `") .. "`" else "(khong thay)")
        add("- Danh gia: " .. mdEsc(g.note))
        add("")
    end
    add("")
    add("## 9. Evidence")
    for _, ev in ipairs(A.evidence) do
        add("- [" .. ev.level .. "] **" .. mdEsc(ev.what) .. "** @ `" .. mdEsc(ev.where) .. "` — `" .. mdEsc(ev.snippet) .. "`")
    end
    if #A.evidence == 0 then add("- (chua co evidence vi thieu source; can bo sung Studio files)") end
    add("")
    add("## 10. Unknowns and Limitations")
    for _, g in ipairs(A.gaps) do add("- " .. mdEsc(g)) end
    for _, u in ipairs(A.architecture.unknowns) do add("- " .. mdEsc(u)) end
    add("- Khong mac dinh co Revive chi vi thay ten Carry/Interact.")
    add("- Server logic (damage, win/lose, save) la UNKNOWN neu khong co Server Source.")
    add("")
    add("## 11. AI Instructions")
    add("1. Doc TOAN BO context truoc khi viet code; khong bo qua muc 10.")
    add("2. KHONG tu gia dinh API noi bo / args remote chua duoc xac nhan (muc 7).")
    add("3. Phan biet FACT (SOURCE_CONFIRMED) vs INFERENCE (INFERRED) vs UNKNOWN/UNAVAILABLE.")
    add("4. Neu thieu du lieu, DE NGHI file can bo sung (muc 4 + 10) thay vi bia code.")
    add("5. Dua KE HOACH trien khai truoc (doi chieu duong dan muc 3), roi moi viet script.")
    add("6. Code phai khop duong dan that trong muc 3/7; neu duong dan khong ton tai thi bao loi thay vi tu che path.")
    add("7. Uu tien do chinh xac + truy xuat bang chung hon tuyen bo '100% game'.")
    add("")
    add("---")
    add("_Token uoc tinh: ~" .. estimateTokens(table.concat(L, "\n")) .. " tokens (chars/4). Neu qua lon, hay chia file theo module (xem file JSON). Khong cat len du lieu._")
    return table.concat(L, "\n")
end

local function COPY_FOR_AI()
    if not State.Analysis then logErr("Chua PROCESS. Hay chay PROCESS truoc."); return nil end
    log("[4/4] COPY FOR AI: dang dong goi Markdown...")
    local md = buildMarkdown()
    State.Markdown = md
    log("Markdown: " .. #md .. " ky tu (~" .. estimateTokens(md) .. " tokens).")
    if #md > CONFIG.CHUNK_WARN then
        log("CANH BAO: du lieu lon (> " .. CONFIG.CHUNK_WARN .. " chars). Se chia nhieu file khi EXPORT, giu index + dependency. Khong cat len.")
    end
    if CONFIG.AUTO_COPY then
        local clip = exFn("setclipboard") or exFn("toClipboard") or exFn("set_clipboard")
        if clip then
            local ok, err = pcall(function() clip(md:sub(1, 200000)) end)
            if ok then log("Da copy Markdown vao clipboard (gioi han 200k chars/lan). Phan con lai trong file export.")
            else logErr("setclipboard that bai: " .. tostring(err)) end
        else
            log("Executor khong ho tro setclipboard -> xem Output / file export.")
        end
    end
    return md
end

--// ============================== 8. EXPORT FILE ==============================
local function toJSON()
    -- build JSON thu cong de khong phu thuoc HttpService (van thu HttpService truoc)
    local okH, hs = pcall(function() return game:GetService("HttpService") end)
    local lite = {
        meta = Collected.meta,
        stats = { scripts = #Collected.client_scripts, remotes = #Collected.remotes,
            prompts = #Collected.prompts, tools = #Collected.tools,
            total_nodes = nodeCount, truncated = nodeCount >= CONFIG.MAX_NODES,
            funcs = #Analysis.functions },
        client_scripts = Collected.client_scripts,
        remotes = Collected.remotes,
        prompts = Collected.prompts,
        tools = Collected.tools,
        player = Collected.player,
        workspace_info = Collected.workspace_info,
        structure = Collected.structure,
        function_index = (function()
            local t = {} for i, f in ipairs(Analysis.functions) do
                if i > 2000 then break end
                table.insert(t, { name = f.name, file = f.file, line = f.line, params = f.params, confidence = f.confidence })
            end return t end)(),
        gameplay = Analysis.gameplay,
        gaps = Analysis.gaps,
        _ai_hint = "Day la dump game Roblox. Dung remotes/prompts/structure de viet script. class=name ClassName, path=GetFullName",
        _schema = "node={class,name,path,props,children}",
    }
    if okH and hs then
        local okJ, j = pcall(function() return hs:JSONEncode(lite) end)
        if okJ then return j end
    end
    return "-- JSONEncode khong kha dung; hay lay file MD + doc truc tiep trong Output."
end

local function EXPORT_FILE()
    if State.Markdown == "" then logErr("Chua COPY FOR AI."); return false end
    local wf = exFn("writefile")
    if not CONFIG.AUTO_WRITEFILE or not wf then
        log("Khong co writefile -> in Markdown ra Output (copy tay).")
        print("===== AI_CONTEXT.md (copy tu day) =====")
        print(State.Markdown:sub(1, 20000))
        print("===== (con tiep " .. (#State.Markdown - math.min(20000, #State.Markdown)) .. " ky tu) =====")
        return true
    end
    local ok1, e1 = pcall(function() wf(CONFIG.FILE_MD, State.Markdown) end)
    if ok1 then log("Da luu " .. CONFIG.FILE_MD .. " (" .. #State.Markdown .. " chars).")
    else logErr("Luu MD that bai: " .. tostring(e1)) end
    local j = toJSON()
    local ok2, e2 = pcall(function() wf(CONFIG.FILE_JSON, j) end)
    if ok2 then log("Da luu " .. CONFIG.FILE_JSON .. " (" .. #j .. " chars).")
    else logErr("Luu JSON that bai: " .. tostring(e2)) end
    -- chia nho neu qua lon
    if #State.Markdown > CONFIG.CHUNK_WARN then
        local idx = 1
        for i = 1, #State.Markdown, CONFIG.CHUNK_WARN do
            local part = State.Markdown:sub(i, i + CONFIG.CHUNK_WARN - 1)
            pcall(function() wf("AI_CONTEXT_part" .. idx .. ".md", part) end)
            idx += 1
        end
        log("Da chia " .. (idx - 1) .. " parts (AI_CONTEXT_partN.md). Giua index + dependency o part 1.")
    end
    -- CSV inventory
    local csv = { "path,class,source_status,source_len" }
    for _, inv in ipairs(Collected.source_inventory) do
        table.insert(csv, '"' .. (inv.path:gsub('"', '""')) .. '",' .. inv.class .. "," .. inv.source_status .. "," .. inv.source_len)
    end
    pcall(function() wf("source_inventory.csv", table.concat(csv, "\n")) end)
    log("Da luu source_inventory.csv (" .. #Collected.source_inventory .. " dong).")
    return true
end

--// ============================== 9. STOP / CLEAR ==============================
local function STOP()
    _G.STOP_PHANTICH = true
    setStatus("Cancelled")
    log("STOP: da yeu cau huy. Vong quet se dung o checkpoint ke tiep.")
end
local function CLEAR_RESULTS()
    _G.STOP_PHANTICH = false
    State.Logs, State.Errors = {}, {}
    State.Data, State.Analysis, State.Markdown = nil, nil, ""
    nodeCount = 0
    Collected = { meta = {}, client_scripts = {}, remotes = {}, prompts = {},
        tools = {}, player = {}, workspace_info = {}, structure = {}, source_inventory = {} }
    Analysis = { architecture = {}, functions = {}, events = {}, gameplay = {}, evidence = {}, gaps = {} }
    setStatus("Idle")
    log("CLEAR RESULTS: da xoa ket qua, ve Idle.")
end

--// ============================== 10. PUBLIC API + AUTO RUN ==============================
_G.PhanTichGame = {
    CONNECT = CONNECT_SOURCE,
    GET_DATA = GET_DATA,
    PROCESS = PROCESS,
    COPY_FOR_AI = COPY_FOR_AI,
    EXPORT_FILE = EXPORT_FILE,
    STOP = STOP,
    CLEAR = CLEAR_RESULTS,
    STATUS = function() return State.Status end,
}

local function pipeline()
    local t0 = os.clock()
    local ok, err = pcall(function()
        if not GET_DATA() then return end
        if stopped() then setStatus("Cancelled"); return end
        if not PROCESS() then return end
        if stopped() then setStatus("Cancelled"); return end
        COPY_FOR_AI()
        EXPORT_FILE()
        if not stopped() then
            setStatus("Completed")
            log(string.format("HOAN TAT in %.1fs. Dan file %s vao ChatGPT/Claude de viet script.", os.clock() - t0, CONFIG.FILE_MD))
            log("Quy tac: AI phai doc het context, khong bia args, hoi them file Studio neu thieu.")
        end
    end)
    if not ok then
        setStatus("Failed")
        logErr("Pipeline loi: " .. tostring(err))
    end
end

if CONFIG.AUTO_RUN then
    task.spawn(pipeline)
else
    log("Da nap script. Chay tay: _G.PhanTichGame.GET_DATA() -> PROCESS() -> COPY_FOR_AI() -> EXPORT_FILE()")
end
