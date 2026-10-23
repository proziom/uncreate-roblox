--!strict
--[[
	Net — the only place that talks HTTP. Wraps HttpService:RequestAsync with
	the server base URL and shared key, and decodes JSON replies.

		local net = Net.new("http://1.2.3.4:7878", "secret")
		local ok, reply, status = net:Json("POST", "/hello?name=Ann", "")

	Every call yields and never throws: failures come back as ok = false with
	the HTTP status (0 when the request never reached the server). Requests
	are paced to stay under HttpService's budget of 500 per minute.

	[ @Claude | 23.10.2026 ]
]]

local HttpService = game:GetService("HttpService")

local BUDGET_PER_MINUTE = 400 -- below HttpService's 500/min, with headroom

local Net = {}
Net.__index = Net

export type Net = typeof(setmetatable(
	{} :: {
		_base: string,
		_key: string,
		_sent: { number }, -- os.clock() of recent requests, oldest first
	},
	Net
))

local function normalizeBase(url: string): string
	local trimmed = string.gsub(url, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	trimmed = string.gsub(trimmed, "/+$", "")
	if not string.find(trimmed, "^https?://") then
		trimmed = "http://" .. trimmed
	end
	return trimmed
end

function Net.new(baseUrl: string, key: string): Net
	return setmetatable({ _base = normalizeBase(baseUrl), _key = key, _sent = {} }, Net)
end

function Net.Base(self: Net): string
	return self._base
end

function Net.Encode(text: string): string
	return HttpService:UrlEncode(text)
end

-- Yields while the last minute already holds a full budget of requests.
function Net._pace(self: Net)
	local sent = self._sent
	while true do
		local now = os.clock()
		while #sent > 0 and now - sent[1] > 60 do
			table.remove(sent, 1)
		end
		if #sent < BUDGET_PER_MINUTE then
			table.insert(sent, now)
			return
		end
		task.wait(60 - (now - sent[1]) + 0.05)
	end
end

-- Requests made in the last minute (lets low-priority traffic step aside).
function Net.RecentRequests(self: Net): number
	local sent, now = self._sent, os.clock()
	while #sent > 0 and now - sent[1] > 60 do
		table.remove(sent, 1)
	end
	return #sent
end

-- Raw request. Returns (ok, status, body).
function Net.Request(self: Net, method: "GET" | "POST", path: string, body: string?): (boolean, number, string)
	self:_pace()
	local options: { [string]: any } = {
		Url = self._base .. path,
		Method = method,
		Headers = { ["X-Key"] = self._key },
	}
	if method == "POST" then
		options.Body = body or ""
		options.Headers["Content-Type"] = "text/plain"
	end
	local ok, result = pcall(function(): any
		return HttpService:RequestAsync(options :: any)
	end)
	if not ok then
		return false, 0, tostring(result)
	end
	local response: { Success: boolean, StatusCode: number, Body: string } = result
	return response.StatusCode == 200, response.StatusCode, response.Body
end

-- JSON request. Returns (ok, decoded or error text, status).
function Net.Json(self: Net, method: "GET" | "POST", path: string, body: string?): (boolean, any, number)
	local ok, status, text = self:Request(method, path, body)
	local decodedOk, decoded = pcall(function(): any
		return HttpService:JSONDecode(text)
	end)
	if not ok then
		if decodedOk and type(decoded) == "table" and type(decoded.error) == "string" then
			return false, decoded.error, status
		end
		return false, text, status
	end
	if not decodedOk then
		return false, "bad JSON from server", status
	end
	return true, decoded, status
end

function Net.ToJson(value: any): string
	return HttpService:JSONEncode(value)
end

return Net
