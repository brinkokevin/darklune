local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local pathAliasMap = {} :: { [string]: string }
local globalValues = {} :: { [string]: any }

type Node = {
	name: string,
	className: string,
	children: { Node },
	filePaths: { string },
}

local fileMap = {}

local function buildFileMap(node: Node, robloxPath: string)
	for _, child in node.children do
		local path = robloxPath
		if
			child.className == "ModuleScript"
			or child.className == "Script"
			or child.className == "Folder"
		then
			path = path .. ':FindFirstChild("' .. child.name .. '")'
		elseif child.className == child.name then
			path = path .. ':GetService("' .. child.className .. '")'
		else
			print(child.className)
		end

		if child.filePaths then
			for i, filePath in ipairs(child.filePaths) do
				filePath = filePath:gsub("\\", "/")
				filePath = filePath:gsub("luau$", "lua")
				child.filePaths[i] = filePath
				fileMap[filePath] = path
			end
		end
		if child.children then
			buildFileMap(child, path)
		end
	end
end

local possibleEndings = {
	".lua",
	"/init.lua",
	"/init.server.lua",
	"/init.client.lua",
}

local function resolveNonStringRequire(requirePath: string, sourcePath: string): string?
	local parts = string.split(requirePath, ".")
	local formatedNonStringRequire = ""

	if parts[1] == "script" then
		local sourceParts = string.split(sourcePath, "/")

		table.remove(parts, 1)

		while parts[1] == "Parent" do
			table.remove(parts, 1)
			table.remove(sourceParts)
		end

		local resolvedPath = table.concat(sourceParts, "/") .. "/" .. table.concat(parts, "/")

		for alias, aliasPath in pathAliasMap do
			resolvedPath = resolvedPath:gsub(aliasPath, alias)
		end

		return resolvedPath
	else
		formatedNonStringRequire = `game:GetService("` .. parts[1] .. `")`
		table.remove(parts, 1)

		for _, part in parts do
			formatedNonStringRequire ..= `:FindFirstChild("` .. part .. `")`
		end

		for stringRequire, path in fileMap do
			if path == formatedNonStringRequire then
				local resolvedPath = stringRequire

				-- This is done in reverse to avoid matching .lua when there could be init.lua
				for i = #possibleEndings, 1, -1 do
					resolvedPath = resolvedPath:gsub(possibleEndings[i], "")
				end

				for alias, aliasPath in pathAliasMap do
					resolvedPath = resolvedPath:gsub(aliasPath, alias)
				end

				return resolvedPath
			end
		end

		warn("Unknown require: " .. formatedNonStringRequire)

		return nil
	end
end

local function removeUnusedServices(source: string)
	return source:gsub('local ([%w_]+) = game:GetService%("[%w_]+"%)', function(serviceName)
		local usageCount = 0
		for _ in source:gmatch(serviceName) do
			usageCount += 1
		end

		if usageCount == 2 then
			return ""
		else
			return `local {serviceName} = game:GetService("{serviceName}")`
		end
	end)
end

local function convertNonStringRequiresToString(source: string, sourcePath: string): string?
	local modified = false

	-- Handle non-string requires (e.g. script.Parent.Something)
	source = source:gsub('require%([^"]-([%w%._]+[^%)"]-)%)', function(requirePath)
		local resolvedPath = resolveNonStringRequire(requirePath, sourcePath)
		if resolvedPath then
			modified = true
			return `require("{resolvedPath}")`
		else
			print("Unable to resolve non-string require: " .. requirePath)
			return `require({requirePath})`
		end
	end)

	source = removeUnusedServices(source)

	if modified then
		return source
	else
		return nil
	end
end

local function convertRequire(source: string, sourcePath: string)
	sourcePath = sourcePath:gsub("%.lua$", "")
	sourcePath = sourcePath:gsub("/init$", "")
	sourcePath = sourcePath:gsub("/init.server$", "")
	sourcePath = sourcePath:gsub("/init.client$", "")

	return source:gsub('require%("(.-)"%)', function(stringRequire: string)
		local originalStringRequire = stringRequire

		local packageName = stringRequire:match("^(.-)/")
		if packageName and pathAliasMap[packageName] then
			stringRequire = stringRequire:gsub("^" .. packageName, pathAliasMap[packageName])

			for _, ending in ipairs(possibleEndings) do
				if fileMap[stringRequire .. ending] then
					return `require({fileMap[stringRequire .. ending]})`
				end
			end

			error(`Could not find: {packageName} {pathAliasMap[packageName]} {stringRequire}`)
		else
			stringRequire = stringRequire:gsub("^%./", "")
			stringRequire = stringRequire:gsub("^/", "")

			while stringRequire:match("^%.%./") do
				stringRequire = stringRequire:gsub("^%.%./", "")
				sourcePath = sourcePath:gsub("/[^/]+$", "")
			end

			local parentPath = sourcePath:gsub("/[^/]+$", "")
			local possiblePaths = { sourcePath, parentPath }

			for _, possiblePath in ipairs(possiblePaths) do
				for _, ending in ipairs(possibleEndings) do
					if fileMap[possiblePath .. "/" .. stringRequire .. ending] then
						return `require({fileMap[possiblePath .. "/" .. stringRequire .. ending]})`
					end
				end
			end
		end

		return `error("Could not find: {originalStringRequire} in {sourcePath}")`
	end)
end

local function injectGlobalVariable(source: string, variableName: string, value: any)
	return source:gsub("_G." .. variableName, tostring(value))
end

local function applyModifiers(source: string, sourcePath: string)
	-- Convert string requires to roblox requires
	source = convertRequire(source, sourcePath)

	-- Inject globals
	for variableName, value in globalValues do
		source = injectGlobalVariable(source, variableName, value)
	end

	return source
end

return {
	init = function(darkluaConfigPath: string)
		local darkluaConfig = serde.decode("json", fs.readFile(darkluaConfigPath))

		for _, processConfig in darkluaConfig.process do
			if processConfig.rule == "convert_require" then
				for key, value in processConfig.current.sources do
					pathAliasMap[key] = value:gsub("/$", "")
				end
			elseif processConfig.rule == "inject_global_value" then
				if processConfig.value then
					globalValues[processConfig.identifier] = processConfig.value
				elseif processConfig.env then
					globalValues[processConfig.identifier] = process.env[processConfig.env]
				end
			end
		end
	end,
	applyModifiers = applyModifiers,
	convertRequire = convertRequire,
	convertNonStringRequiresToString = convertNonStringRequiresToString,
	buildFileMap = function(projectPath: string): string?
		local source = process.spawn("rojo", { "sourcemap", projectPath })
		if source.ok then
			buildFileMap(serde.decode("json", source.stdout), "game")
			return source.stdout
		else
			warn("Sometimes this appears because you have to run rokit install")
			error("Failed to update filemap\n" .. source.stderr)
			return nil
		end
	end,
}
