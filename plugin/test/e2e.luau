--[[
	End-to-end test: several mock Studio places run the real plugin modules
	(src/*.luau) against a real uncreate-server and must converge.
	Run via test/run_e2e.sh (it builds and starts the server).

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local task = require("@lune/task")
local net = require("@lune/net")
local serde = require("@lune/serde")
local mock = require("./rbxmock")

local URL = process.env.UNCREATE_URL or "127.0.0.1:7878"
local KEY = process.env.UNCREATE_KEY or "test"
local SRC = process.env.UNCREATE_SRC or "../src/"

local Instance, Vector3, Color3, CFrame = mock.Instance, mock.Vector3, mock.Color3, mock.CFrame

-- Loads the plugin's modules into a sandbox whose `game` is this place.
local function loadSession(game)
	local loaded = {}
	local env
	local parent = setmetatable({}, {
		__index = function(_, name)
			return { __module = name }
		end,
	})
	local function req(token)
		local name = token.__module
		if loaded[name] == nil then
			local fn = luau.load(fs.readFile(SRC .. name .. ".luau"), {
				debugName = game.Name .. "/" .. name,
				environment = env,
			})
			loaded[name] = { value = fn() }
		end
		return loaded[name].value
	end
	env = {
		game = game,
		script = { Parent = parent },
		require = req,
		typeof = mock.typeof,
		task = task,
		Instance = Instance,
		Vector3 = Vector3,
		CFrame = CFrame,
		Color3 = Color3,
		UDim2 = mock.UDim2,
		TweenInfo = mock.TweenInfo,
		Vector2 = mock.Vector2,
		Enum = mock.Enum,
	}
	return req({ __module = "Session" })
end

local failures = 0
local function check(cond, what)
	if cond then
		print("  ok   " .. what)
	else
		failures += 1
		print("  FAIL " .. what)
	end
end

local function waitUntil(cond, timeout)
	local deadline = os.clock() + (timeout or 10)
	while os.clock() < deadline do
		if cond() then
			return true
		end
		task.wait(0.05)
	end
	return cond()
end

local ROOTS = { "Workspace", "Lighting", "ReplicatedStorage", "ServerScriptService", "StarterPlayer" }

-- Canonical text of everything sync should make identical, ids included.
local function dump(game)
	local lines = {}
	local function fmt(v)
		local t = mock.typeof(v)
		if t == "Vector3" or t == "Color3" then
			return t .. "(" .. (v.X or v.R) .. "," .. (v.Y or v.G) .. "," .. (v.Z or v.B) .. ")"
		elseif t == "CFrame" then
			return "CF(" .. table.concat({ v:GetComponents() }, ",") .. ")"
		elseif t == "Instance" then
			return "->" .. tostring(v:GetAttribute("UncreateId") or v.Name)
		end
		return tostring(v)
	end
	local function walk(node, path)
		local children = node:GetChildren()
		table.sort(children, function(a, b)
			return tostring(a:GetAttribute("UncreateId") or a.Name) < tostring(b:GetAttribute("UncreateId") or b.Name)
		end)
		for _, c in children do
			if c.Archivable and c.ClassName ~= "Terrain" and c.ClassName ~= "Camera" then
				local p = path .. "/" .. c.Name
				local props = {}
				for k, v in c._props do
					table.insert(props, k .. "=" .. fmt(v))
				end
				table.sort(props)
				local attrs = {}
				for k, v in c._attrs do
					table.insert(attrs, k .. "=" .. fmt(v))
				end
				table.sort(attrs)
				table.insert(
					lines,
					p
						.. " ["
						.. c.ClassName
						.. "] "
						.. table.concat(props, " ")
						.. " | "
						.. table.concat(attrs, " ")
						.. " | tags="
						.. table.concat(c:GetTags(), ",")
				)
				walk(c, p)
			end
		end
	end
	for _, r in ROOTS do
		local s = game:GetService(r)
		table.insert(lines, "#" .. r .. " ClockTime=" .. tostring(rawget(s._props, "ClockTime")))
		walk(s, r)
	end
	return table.concat(lines, "\n")
end

local function diff(a, b)
	local la, lb = string.split(a, "\n"), string.split(b, "\n")
	for i = 1, math.max(#la, #lb) do
		if la[i] ~= lb[i] then
			return ("line %d:\n    A: %s\n    B: %s"):format(i, tostring(la[i]), tostring(lb[i]))
		end
	end
	return "(equal)"
end

local function connect(game, name)
	local Session = loadSession(game)
	local state = { status = "Idle", logs = {} }
	local session = Session.new(URL, KEY, name, {
		OnStatus = function(status, text)
			state.status = status
			state.text = text
			if status == "Error" then
				print(("    [%s] ERROR %s"):format(name, text))
			end
		end,
		OnLog = function(text)
			table.insert(state.logs, text)
			print(("    [%s] %s"):format(name, text))
		end,
		OnPeers = function(peers)
			state.peers = peers
		end,
		Confirm = function()
			return true
		end,
	})
	session:Start()
	state.session = session
	return state
end

local function converge(a, b, what, timeout)
	local ok = waitUntil(function()
		return dump(a) == dump(b)
	end, timeout or 8)
	check(ok, what)
	if not ok then
		print("    " .. diff(dump(a), dump(b)))
	end
	return ok
end

local function main()
-------------------------------------------------------------------------------
print("1. host uploads a place")
local gameA = mock.newGame("A")
do
	local ws = gameA:GetService("Workspace")
	local map = Instance.new("Model", ws)
	map.Name = "Map"
	for i = 1, 30 do
		local p = Instance.new("Part", map)
		p.Name = "P" .. i
		p.CFrame = CFrame.new(i, 0, 0)
	end
	local weld = Instance.new("ObjectValue", gameA:GetService("ReplicatedStorage"))
	weld.Name = "PointsAtP1"
	weld.Value = map.P1 -- crosses roots: must survive via manifest.refs
	map.P2:AddTag("Spawn") -- travels inside the snapshot
	local s = Instance.new("Script", gameA:GetService("ServerScriptService"))
	s.Name = "Main"
	s.Source = "print('hello')"
	local sps = gameA:GetService("StarterPlayer").StarterPlayerScripts
	local ls = Instance.new("LocalScript", sps)
	ls.Name = "Client"
	ls.Source = "-- client"
	gameA:GetService("Lighting").ClockTime = 6
	local hidden = Instance.new("Part", ws)
	hidden.Name = "NotArchivable"
	hidden.Archivable = false
end
local A = connect(gameA, "Alice")
check(waitUntil(function()
	return A.status == "Live"
end, 15), "A is live as host")

-------------------------------------------------------------------------------
print("2. joiner replaces its place with the project")
local gameB = mock.newGame("B")
Instance.new("Part", gameB:GetService("Workspace")).Name = "Baseplate"
local B = connect(gameB, "Bob")
check(waitUntil(function()
	return B.status == "Live"
end, 15), "B is live")
converge(gameA, gameB, "B matches A after join")
check(gameB:GetService("Workspace"):FindFirstChild("Baseplate") == nil, "B's own content was replaced")
check(gameB:GetService("ReplicatedStorage").PointsAtP1.Value == gameB:GetService("Workspace").Map.P1, "cross-root reference restored")
check(gameB:GetService("Lighting").ClockTime == 6, "service property synced")

print("2b. flying heads: B sees where A's camera is")
gameA:GetService("Workspace").CurrentCamera.CFrame = CFrame.lookAt(Vector3.new(50, 20, -30), Vector3.new(0, 0, 0))
local function headOf(game, name)
	local folder = game:GetService("CoreGui"):FindFirstChild("UncreatePresence")
	local group = folder and folder:FindFirstChild(name)
	return group and group:FindFirstChild("Head")
end
check(waitUntil(function()
	local head = headOf(gameB, "Alice")
	return head ~= nil and (head.CFrame.Position - Vector3.new(50, 20, -30)).Magnitude < 0.05
end, 6), "B shows Alice's head at her camera (after gliding there)")
check(waitUntil(function()
	return headOf(gameA, "Bob") ~= nil
end, 6), "A shows Bob's head")
check(headOf(gameA, "Alice") == nil, "nobody sees their own head")
check(gameB:GetService("Workspace"):FindFirstChild("UncreatePresence") == nil, "heads are not part of the place")
do
	local gameE = mock.newGame("E")
	local E = connect(gameE, "Eve")
	check(waitUntil(function()
		return headOf(gameA, "Eve") ~= nil
	end, 15), "A shows Eve's head")
	E.session:Stop()
	check(waitUntil(function()
		return headOf(gameA, "Eve") == nil
	end, 4), "Eve's head disappears as soon as she disconnects")
	local reconnected = connect(gameE, "Eve")
	check(waitUntil(function()
		return reconnected.status == "Live" and headOf(gameA, "Eve") ~= nil
	end, 15), "Eve reconnects")
	task.wait(2)
	check(headOf(gameE, "Eve") == nil, "after reconnecting, Eve does not see a ghost of herself")
	reconnected.session:Stop()
end

-------------------------------------------------------------------------------
print("3. property, name, attribute, source edits")
local mapA = gameA:GetService("Workspace").Map
mapA.P1.CFrame = CFrame.new(100, 5, 0)
mapA.P2.Color = Color3.new(1, 0, 0)
mapA.P3.Name = "Renamed"
mapA.P4:SetAttribute("Health", 50)
gameA:GetService("ServerScriptService").Main.Source = "print('edited by A')"
converge(gameA, gameB, "edits reach B")

local mapB = gameB:GetService("Workspace").Map
mapB.P5.Anchored = true
mapB.P4:SetAttribute("Health", nil)
gameB:GetService("Lighting").ClockTime = 20
converge(gameA, gameB, "edits from B reach A")

-------------------------------------------------------------------------------
print("3b. tags")
check(mapB.P2:HasTag("Spawn"), "tags arrive with the snapshot")
mapA.P1:AddTag("Lava") -- a tag new to the whole place: the TagAdded path
mapA.P2:AddTag("Lava") -- an existing tag on another part
converge(gameA, gameB, "tags added on A reach B")
mapB.P2:RemoveTag("Spawn")
mapB.P14:AddTag("Coin")
converge(gameA, gameB, "tag removed / added on B reach A")
check(not mapA.P2:HasTag("Spawn") and mapA.P14:HasTag("Coin"), "A has B's tag edits")
local tagged = Instance.new("Part")
tagged.Name = "TaggedNew"
tagged:AddTag("Lava")
tagged.Parent = gameB:GetService("Workspace")
converge(gameA, gameB, "a new tagged part arrives tagged")

-------------------------------------------------------------------------------
print("4. create, duplicate, move, delete")
local folder = Instance.new("Folder")
folder.Name = "NewStuff"
for i = 1, 3 do
	local p = Instance.new("Part", folder)
	p.Name = "N" .. i
end
folder.Parent = gameB:GetService("Workspace")
converge(gameA, gameB, "new subtree from B reaches A")
local copy = mapA.P6:Clone() -- carries P6's UncreateId
copy.Name = "P6copy"
copy.Parent = mapA
converge(gameA, gameB, "duplicate gets its own id")
check(copy:GetAttribute("UncreateId") ~= mapA.P6:GetAttribute("UncreateId"), "copy was re-stamped")
mapA.P7.Parent = gameA:GetService("ReplicatedStorage")
converge(gameA, gameB, "move across roots")
mapB.P8:Destroy()
gameB:GetService("Workspace").NewStuff.N1:Destroy()
converge(gameA, gameB, "deletes from B reach A")

-------------------------------------------------------------------------------
print("5. cut & paste (delete + copy with same id in one flush)")
local p9 = mapA.P9
local pasted = p9:Clone()
p9.Parent = nil
pasted.Parent = gameA:GetService("Workspace")
converge(gameA, gameB, "cut/paste converges")

-------------------------------------------------------------------------------
print("6. concurrent writes to one property converge")
for round = 1, 5 do
	mapA.P10.CFrame = CFrame.new(round, 1, 1)
	mapB.P10.CFrame = CFrame.new(round, 2, 2)
	task.wait(0.03 * round)
end
converge(gameA, gameB, "same-key race settles to one value", 10)
mapA.P11.Transparency = 0.5
mapB.P11.Name = "BothTouched"
converge(gameA, gameB, "different keys on one instance both survive")
check(mapA.BothTouched and mapA.BothTouched.Transparency == 0.5, "both edits kept")

-------------------------------------------------------------------------------
print("7. bursts coalesce (dragging)")
local before = 0
for i = 1, 200 do
	mapA.P12.CFrame = CFrame.new(i, i, i)
	if i % 20 == 0 then
		task.wait()
	end
end
converge(gameA, gameB, "drag burst arrives as final value")
local _ = before

-------------------------------------------------------------------------------
print("7b. no echo loops: an idle project produces no traffic")
local function serverRev()
	local r = net.request({ url = "http://" .. URL .. "/status", headers = { ["X-Key"] = KEY } })
	return serde.decode("json", r.body).rev
end
task.wait(0.5)
local revIdle = serverRev()
task.wait(1.5)
check(serverRev() == revIdle, ("rev stable while idle (%d)"):format(revIdle))

-------------------------------------------------------------------------------
print("7c. scale: 3000-part model, then move all of it")
local t0 = os.clock()
local big = Instance.new("Model")
big.Name = "City"
for i = 1, 3000 do
	local p = Instance.new("Part", big)
	p.Name = "B" .. i
	p.CFrame = CFrame.new(i, 0, 0)
end
big.Parent = gameA:GetService("Workspace")
converge(gameA, gameB, "3000-part model arrives", 30)
print(("    create+deliver: %.2f s"):format(os.clock() - t0))
t0 = os.clock()
local revBefore = serverRev()
for _, p in big:GetChildren() do
	p.CFrame = CFrame.new(p.CFrame.Position.X, 10, 0)
end
converge(gameA, gameB, "moving 3000 parts arrives", 30)
print(("    move+deliver: %.2f s, batches used: %d"):format(os.clock() - t0, serverRev() - revBefore))
big:Destroy()
converge(gameA, gameB, "deleting it arrives")

-------------------------------------------------------------------------------
print("8. late joiner, then compaction, then another joiner")
task.wait(0.5)
local revBeforeC = serverRev()
local gameC = mock.newGame("C")
local C = connect(gameC, "Chi")
check(waitUntil(function()
	return C.status == "Live"
end, 15), "C is live")
converge(gameA, gameC, "late joiner C matches A (snapshot + log replay)")
task.wait(1)
check(serverRev() == revBeforeC, "joining sends nothing (no tag or property echoes)")
A.session:UploadSnapshot()
check(waitUntil(function()
	for _, line in A.logs do
		if string.find(line, "Snapshot @", 1, true) then
			return true
		end
	end
	return false
end, 10), "A uploaded a compacted snapshot")
mapB.P13.Name = "AfterSnapshot"
converge(gameA, gameB, "edits continue after compaction")
local gameD = mock.newGame("D")
local D = connect(gameD, "Dan")
check(waitUntil(function()
	return D.status == "Live"
end, 15), "D is live")
converge(gameA, gameD, "joiner after compaction matches")
converge(gameC, gameD, "all four places agree")
check(A.peers ~= nil and #A.peers == 4, "presence lists 4 people")

for _, s in { A, B, C, D } do
	s.session:Stop()
end
end

local ok, err = pcall(main)
if not ok then
	failures += 1
	print("  FAIL crashed: " .. tostring(err))
end
print(failures == 0 and "E2E PASSED" or ("E2E FAILED: " .. failures))
process.exit(failures == 0 and 0 or 1)
