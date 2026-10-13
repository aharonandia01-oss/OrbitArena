-- Discord: TU_DISCORD | Roblox: TU_USUARIO_ROBLOX
-- If your GitHub and Discord are linked, you can use "-- Connected Discord-GitHub" instead.
-- ServerScriptService. The map is made here, no models needed in Workspace.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local DataStoreService = game:GetService("DataStoreService")

-- settings I usually change while testing. 1 player is enough to test the round alone.
-- put MinPlayers at 2 when the place is ready for normal matches.
local Settings = {
    MinPlayers = 1,
    WaitingSeconds = 8,
    RoundSeconds = 40,
    RestSeconds = 6,
    TilesPerSide = 7,
    TileSize = 8.5,
    TileGap = 0.35,
    ArenaHeight = 28,
    LobbyPosition = Vector3.new(0, 4, -105),
    FallLimit = 12,
    CollapseDelay = 0.55,
    LaserSpeed = 0.9,
    LaserKnockback = 68,
    LaserUpForce = 27,
    LaserHitCooldown = 1.5,
    WinnerCoins = 60,
    ParticipationCoins = 10,
    SaveData = not RunService:IsStudio(), -- leave saves off in Studio for now
    StoreName = "OrbitArenaPlayerData_v1",
}

local rng = Random.new()
local store = DataStoreService:GetDataStore(Settings.StoreName)
local state = {
    roundId = 0,
    phase = "Waiting",
    active = {},
    participants = {},
    laserCooldowns = {},
    stats = {},
    loaded = {},
    tiles = {},
    rotation = 0,
    heartbeat = nil,
}

-- get rid of the old generated stuff if this script happens to run again.
-- easier than trying to find 49 old tiles one by one.
local oldArena = Workspace:FindFirstChild("OrbitArenaGenerated")
if oldArena then
    oldArena:Destroy()
end
local arenaFolder = Instance.new("Folder")
arenaFolder.Name = "OrbitArenaGenerated"
arenaFolder.Parent = Workspace

-- used for the floor, tiles and the rotating bar. keeping these defaults here
-- saves repeating the same anchored/smooth setup everywhere.
local function makePart(name, size, cframe, color, material, parent)
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.CFrame = cframe
    part.Color = color
    part.Material = material
    part.Anchored = true
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    part.Parent = parent
    return part
end

local lobbyBase = makePart(
    "LobbyFloor",
    Vector3.new(62, 2, 42),
    CFrame.new(Settings.LobbyPosition - Vector3.new(0, 4, 0)),
    Color3.fromRGB(185, 203, 213),
    Enum.Material.Concrete,
    arenaFolder
)
lobbyBase.CanTouch = false

local spawn = Instance.new("SpawnLocation")
spawn.Name = "OrbitArenaSpawn"
spawn.Size = Vector3.new(8, 1, 8)
spawn.CFrame = CFrame.new(Settings.LobbyPosition - Vector3.new(0, 2.5, 0))
spawn.Neutral = true
spawn.Enabled = true
spawn.Duration = 0
spawn.Anchored = true
spawn.Color = Color3.fromRGB(105, 160, 196)
spawn.Material = Enum.Material.SmoothPlastic
spawn.Parent = arenaFolder

-- plain server-side signs. everyone sees the same round status.
-- I didn't use a ScreenGui since that'd need a client script too.
local function makeSign(name, cframe, width)
    local stand = makePart(name, Vector3.new(1, 1, 1), cframe, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, arenaFolder)
    stand.Transparency = 1
    stand.CanCollide = false
    stand.CanTouch = false
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "Info"
    billboard.Adornee = stand
    billboard.Size = UDim2.fromOffset(width, 110)
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 240
    billboard.Parent = stand
    local label = Instance.new("TextLabel")
    label.Name = "Status"
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundColor3 = Color3.fromRGB(248, 248, 248)
    label.BackgroundTransparency = 0.06
    label.BorderSizePixel = 1
    label.TextColor3 = Color3.fromRGB(30, 30, 30)
    label.TextStrokeTransparency = 1
    label.TextScaled = true
    label.TextWrapped = true
    label.Font = Enum.Font.SourceSansBold
    label.Text = "Orbit Arena"
    label.Parent = billboard
    return label
end

local lobbyLabel = makeSign("LobbySign", CFrame.new(Settings.LobbyPosition + Vector3.new(0, 10, 0)), 300)
local arenaLabel = makeSign("ArenaSign", CFrame.new(0, Settings.ArenaHeight + 19, -40), 340)

local centerPole = makePart(
    "LaserPivot",
    Vector3.new(2.4, 8, 2.4),
    CFrame.new(0, Settings.ArenaHeight + 4, 0),
    Color3.fromRGB(70, 83, 92),
    Enum.Material.Metal,
    arenaFolder
)
centerPole.CanCollide = false
centerPole.CanTouch = false

local laserLength = Settings.TilesPerSide * (Settings.TileSize + Settings.TileGap) - 3
local laser = makePart(
    "RotatingBeam",
    Vector3.new(1.7, 2.4, laserLength),
    CFrame.new(0, Settings.ArenaHeight + 4.0, 0),
    Color3.fromRGB(245, 158, 59),
    Enum.Material.Neon,
    arenaFolder
)
laser.CanCollide = false
laser.CanTouch = false
laser.Transparency = 1

-- each tile needs its own "used" flag, tween and starting position.
-- a metatable is just a convenient way to keep those together.
local Tile = {}
Tile.__index = Tile

function Tile.new(part)
    local self = setmetatable({}, Tile)
    self.part = part
    self.home = part.CFrame
    self.used = false
    self.tween = nil
    self.connection = nil
    return self
end

-- reset this tile for the next round. an old tween may still be changing its color
-- so cancel it first, otherwise a fresh tile can suddenly turn red again.
function Tile:reset()
    self.used = false
    if self.tween then
        self.tween:Cancel()
        self.tween = nil
    end
    self.part.Anchored = true
    self.part.AssemblyLinearVelocity = Vector3.zero
    self.part.AssemblyAngularVelocity = Vector3.zero
    self.part.CFrame = self.home
    self.part.Transparency = 0
    self.part.CanCollide = true
    self.part.CanTouch = true
    self.part.Color = Color3.fromRGB(104, 189, 191)
end

-- a touch starts the warning color first, then the tile actually falls.
-- roundId is checked later because task.delay might wake up during the NEXT match.
function Tile:collapse(roundId)
    if self.used or state.phase ~= "Round" then
        return
    end
    self.used = true
    self.tween = TweenService:Create(
        self.part,
        TweenInfo.new(Settings.CollapseDelay, Enum.EasingStyle.Linear),
        {Color = Color3.fromRGB(239, 83, 79), Transparency = 0.25}
    )
    self.tween:Play()
    task.delay(Settings.CollapseDelay, function()
        if state.roundId ~= roundId or state.phase ~= "Round" then
            return
        end
        self.part.CanCollide = false
        self.part.Anchored = false
        task.delay(1.3, function()
            if state.roundId ~= roundId then
                return
            end
            self.part.Anchored = true
            self.part.CanTouch = false
            self.part.Transparency = 1
        end)
    end)
end

-- Touched fires a lot (legs, accessories, etc), not just once.
-- make sure it's an actual player still in this round before collapsing anything.
function Tile:bind()
    self.connection = self.part.Touched:Connect(function(hit)
        if state.phase ~= "Round" or self.used then
            return
        end
        local character = hit:FindFirstAncestorOfClass("Model")
        if not character then
            return
        end
        local player = Players:GetPlayerFromCharacter(character)
        if not player or not state.active[player] then
            return
        end
        self:collapse(state.roundId)
    end)
end

-- build the tiles once. recreating the whole floor every round is wasteful.
local stride = Settings.TileSize + Settings.TileGap
local offset = (Settings.TilesPerSide - 1) * stride / 2
for column = 1, Settings.TilesPerSide do
    for row = 1, Settings.TilesPerSide do
        local x = (column - 1) * stride - offset
        local z = (row - 1) * stride - offset
        local name = string.format("Tile_%d_%d", column, row)
        local part = makePart(
            name,
            Vector3.new(Settings.TileSize, 2, Settings.TileSize),
            CFrame.new(x, Settings.ArenaHeight, z),
            Color3.fromRGB(104, 189, 191),
            Enum.Material.SmoothPlastic,
            arenaFolder
        )
        local tile = Tile.new(part)
        tile:bind()
        table.insert(state.tiles, tile)
    end
end

print("[Orbit] Arena ready,", #state.tiles, "tiles")

-- small random offset so everyone isn't teleported into the exact same spot.
local function moveToLobby(player)
    local character = player.Character
    if not character then
        return
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then
        return
    end
    local spread = Vector3.new(rng:NextNumber(-12, 12), 0, rng:NextNumber(-8, 8))
    character:PivotTo(CFrame.new(Settings.LobbyPosition + spread))
    root.AssemblyLinearVelocity = Vector3.zero
end

local function updateSigns(message)
    local liveCount = 0
    for player, isActive in pairs(state.active) do
        if isActive and player.Parent == Players then
            liveCount += 1
        end
    end
    local content = string.format("ORBIT ARENA\n%s\nAlive: %d", message, liveCount)
    lobbyLabel.Text = content
    arenaLabel.Text = content
end

-- make the stats before loading. you should still see them in a Studio test.
-- important: if loading fails, I don't let that session save over existing data.
local function attachPlayer(player)
    if state.stats[player] then
        return
    end
    local leaderstats = Instance.new("Folder")
    leaderstats.Name = "leaderstats"
    leaderstats.Parent = player
    local wins = Instance.new("IntValue")
    wins.Name = "Wins"
    wins.Parent = leaderstats
    local coins = Instance.new("IntValue")
    coins.Name = "Coins"
    coins.Parent = leaderstats
    state.stats[player] = {wins = wins, coins = coins}
    state.loaded[player] = false
    player.CharacterAdded:Connect(function(character)
        -- died mid-round? respawn in lobby, don't sneak back into the match.
        if state.phase == "Round" then
            state.active[player] = nil
        end
        character:WaitForChild("HumanoidRootPart", 10)
        task.wait(0.1)
        if player.Parent == Players then
            moveToLobby(player)
        end
    end)
    if player.Character then
        task.defer(moveToLobby, player)
    end
    if Settings.SaveData then
        local ok, result = pcall(function()
            return store:GetAsync("player_" .. player.UserId)
        end)
        if player.Parent ~= Players then
            return
        end
        if ok then
            state.loaded[player] = true
            if typeof(result) == "table" then
                wins.Value = math.max(0, tonumber(result.Wins) or 0)
                coins.Value = math.max(0, tonumber(result.Coins) or 0)
            end
        else
            warn("[Orbit] Couldn't load data for", player.Name, result)
        end
    end
end

-- save on leaving / server shutdown, not after every small reward.
-- fewer data store requests, and the current numbers are read right before saving.
local function savePlayer(player)
    if not Settings.SaveData or not state.loaded[player] then
        return
    end
    local values = state.stats[player]
    if not values then
        return
    end
    local wins = values.wins.Value
    local coins = values.coins.Value
    local success, err = pcall(function()
        store:UpdateAsync("player_" .. player.UserId, function()
            return {Wins = wins, Coins = coins}
        end)
    end)
    if not success then
        warn("[Orbit] Save didn't work for", player.Name, err)
    end
end

-- player might disconnect while standing in the arena.
local function playerLeaving(player)
    state.active[player] = nil
    state.participants[player] = nil
    state.laserCooldowns[player] = nil
    savePlayer(player)
    state.stats[player] = nil
    state.loaded[player] = nil
end

Players.PlayerAdded:Connect(attachPlayer)
Players.PlayerRemoving:Connect(playerLeaving)
for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(attachPlayer, player)
end

-- Players can still be here when Roblox closes the server.
-- give the save calls a little time before shutting down.
game:BindToClose(function()
    local pending = 0
    for _, player in ipairs(Players:GetPlayers()) do
        pending += 1
        task.spawn(function()
            savePlayer(player)
            pending -= 1
        end)
    end
    local started = os.clock()
    while pending > 0 and os.clock() - started < 20 do
        task.wait(0.1)
    end
end)

local function participantCount()
    local count = 0
    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if humanoid and root and humanoid.Health > 0 then
            count += 1
        end
    end
    return count
end

-- shuffle a COPY of the tiles so spawns don't repeat.
-- I leave state.tiles alone because it's also used for resetting the floor.
local function chooseSpawnTiles(count)
    local shuffled = table.clone(state.tiles)
    for index = #shuffled, 2, -1 do
        local other = rng:NextInteger(1, index)
        shuffled[index], shuffled[other] = shuffled[other], shuffled[index]
    end
    local chosen = {}
    for i = 1, math.min(count, #shuffled) do
        chosen[i] = shuffled[i]
    end
    return chosen
end

local function resetTiles()
    for _, tile in ipairs(state.tiles) do
        tile:reset()
    end
end

-- start a fresh round, then move the players to different tiles.
local function beginRound()
    state.roundId += 1
    state.phase = "Round"
    state.active = {}
    state.participants = {}
    state.laserCooldowns = {}
    state.rotation = 0
    resetTiles()
    local eligible = {}
    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if humanoid and root and humanoid.Health > 0 then
            table.insert(eligible, player)
        end
    end
    local positions = chooseSpawnTiles(#eligible)
    local placed = 0
    for index, player in ipairs(eligible) do
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local tile = positions[index]
        if character and root and tile then
            state.active[player] = true
            state.participants[player] = true
            placed += 1
            character:PivotTo(tile.home + Vector3.new(0, 5, 0))
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
    end
    laser.Transparency = 0.1
    print("[Orbit] Round", state.roundId, "started with", placed, "players")
    updateSigns("Avoid the beam and falling tiles")
    return placed
end

-- check both health and height; if somebody falls but hasn't died yet,
-- they should already be out. CharacterAdded takes care of the lobby respawn.
local function alivePlayers()
    local alive = {}
    for player, playing in pairs(state.active) do
        if playing then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if player.Parent ~= Players or not humanoid or not root or humanoid.Health <= 0 then
                state.active[player] = nil
            elseif root.Position.Y < Settings.FallLimit then
                state.active[player] = nil
                humanoid.Health = 0
            else
                table.insert(alive, player)
            end
        end
    end
    return alive
end

-- the beam is anchored and moved with CFrame. Touched isn't reliable for that.
-- I check each player's root in the beam's LOCAL space instead. X is its width,
-- Z is along the beam. The server handles knockback, not a client remote.
local function checkLaserHits()
    local now = os.clock()
    for player, playing in pairs(state.active) do
        if playing then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root and root.Position.Y >= Settings.FallLimit then
                local localPosition = laser.CFrame:PointToObjectSpace(root.Position)
                local withinWidth = math.abs(localPosition.X) < 2.3
                local withinLength = math.abs(localPosition.Z) < laserLength / 2 + 1.5
                local withinHeight = math.abs(localPosition.Y) < 3.7
                local lastHit = state.laserCooldowns[player] or -math.huge
                if withinWidth and withinLength and withinHeight and now - lastHit > Settings.LaserHitCooldown then
                    state.laserCooldowns[player] = now
                    -- push sideways relative to the beam, not in one fixed world direction.
                    local tangent = laser.CFrame.RightVector
                    local boost = tangent * Settings.LaserKnockback
                    root.AssemblyLinearVelocity = boost + Vector3.new(0, Settings.LaserUpForce, 0)
                end
            end
        end
    end
end

-- movement should look smooth, so rotate every Heartbeat.
-- hit checks can run about 10 times/sec, no need to do them every single frame.
local function startLaser()
    local checkAccumulator = 0
    if state.heartbeat then
        state.heartbeat:Disconnect()
    end
    state.heartbeat = RunService.Heartbeat:Connect(function(dt)
        if state.phase ~= "Round" then
            return
        end
        state.rotation += dt * Settings.LaserSpeed
        local pivot = CFrame.new(0, Settings.ArenaHeight + 4, 0)
        laser.CFrame = pivot * CFrame.Angles(0, state.rotation, 0)
        checkAccumulator += dt
        if checkAccumulator >= 0.1 then
            checkAccumulator = 0
            checkLaserHits()
        end
    end)
end

local function stopLaser()
    if state.heartbeat then
        state.heartbeat:Disconnect()
        state.heartbeat = nil
    end
    laser.Transparency = 1
end

-- reward everyone who played; winners get more and a win on the leaderboard.
local function addReward(player, won)
    local values = state.stats[player]
    if not values then
        return
    end
    if won then
        values.wins.Value += 1
        values.coins.Value += Settings.WinnerCoins
    else
        values.coins.Value += Settings.ParticipationCoins
    end
end

local function finishRound(survivors)
    state.phase = "Results"
    print("[Orbit] Round ended - survivors:", #survivors)
    stopLaser()
    local winners = {}
    for _, player in ipairs(survivors) do
        winners[player] = true
    end
    local names = {}
    for player in pairs(winners) do
        addReward(player, true)
        table.insert(names, player.DisplayName)
    end
    for player in pairs(state.participants) do
        if not winners[player] and player.Parent == Players then
            addReward(player, false)
        end
    end
    if #names > 0 then
        updateSigns("Winner: " .. table.concat(names, ", "))
    else
        updateSigns("No survivors this round")
    end
    state.active = {}
    state.participants = {}
    task.wait(Settings.RestSeconds)
    for _, player in ipairs(Players:GetPlayers()) do
        moveToLobby(player)
    end
    resetTiles()
    state.phase = "Waiting"
end

-- main game loop down here. solo testing uses the full timer.
-- with multiple players the round can finish early if only one survives.
-- anyone still alive when time runs out counts as a winner (ties are possible).
task.spawn(function()
    while true do
        while participantCount() < Settings.MinPlayers do
            state.phase = "Waiting"
            updateSigns("Waiting for players")
            task.wait(1)
        end
        state.phase = "Countdown"
        local cancelled = false
        for seconds = Settings.WaitingSeconds, 1, -1 do
            if participantCount() < Settings.MinPlayers then
                cancelled = true
                break
            end
            updateSigns("Starts in " .. seconds .. "s")
            task.wait(1)
        end
        if not cancelled and participantCount() >= Settings.MinPlayers then
            local count = beginRound()
            if count > 0 then
                startLaser()
                local survivors = {}
                for seconds = Settings.RoundSeconds, 1, -1 do
                    survivors = alivePlayers()
                    updateSigns("Survive! " .. seconds .. "s left")
                    if #survivors == 0 then
                        break
                    end
                    if count > 1 and #survivors == 1 then
                        break
                    end
                    task.wait(1)
                end
                -- last check: somebody could've fallen during that final wait.
                survivors = alivePlayers()
                finishRound(survivors)
            else
                state.phase = "Waiting"
            end
        else
            updateSigns("Countdown cancelled")
            task.wait(1)
        end
    end
end)
