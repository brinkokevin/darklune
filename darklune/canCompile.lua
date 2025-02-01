local luau = require("@lune/luau")

local function extractErrorInfo(errorMessage): (string?, string?)
	-- Pattern to match the line number and error message
	local pattern = ":(%d+): (.+)"

	-- Find the first line that matches our pattern
	for line in errorMessage:gmatch("[^\r\n]+") do
		local lineNumber, errorString = line:match(pattern)
		if lineNumber and errorString then
			return lineNumber, errorString
		end
	end

	-- If no match found, return nil
	return nil
end

local function canCompile(source: string)
	local success, err = pcall(luau.compile, source)
	if not success then
		return false, extractErrorInfo(tostring(err))
	end
	return success
end

return canCompile
