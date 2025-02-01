local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local canCompile = require("./canCompile")
local fileWatcher = require("./fileWatcher")
local luaModifiers = require("./luaModifiers")

local scheduled: thread? = nil
local function scheduleUpdateSourcemap(sourcemap: string)
	if scheduled then
		task.cancel(scheduled)
	end

	scheduled = task.delay(0.1, function()
		fs.writeFile("sourcemap.json", sourcemap)
		scheduled = nil
	end)
end

local function writeDestinationFile(path: string, source: string)
	local dir = path:match("(.+)/[^/]+$")
	if dir and not fs.isDir(dir) then
		fs.writeDir(dir)
	end

	fs.writeFile(path, source)
end

local function colorText(text: string, color: stdio.Color)
	return `{stdio.color(color)}{text}{stdio.color("reset")}`
end

local function processLuaFile(path: string, destPath: string)
	local source = fs.readFile(path)

	-- Auto convert non-string requires to strings in our source files
	-- Enable if you want to use luau-lsp auto imports, this will automatically convert non string requires to string requires
	-- local nonStringSource = luaModifiers.convertNonStringRequiresToString(source, path)
	-- if nonStringSource then
	-- 	nonStringSource = nonStringSource:gsub("^%s*\n", "")
	-- 	fs.writeFile(path, nonStringSource)
	-- 	stdio.write(`Fixed non-string requires in {colorText(path, "yellow")}\n`)
	-- end

	-- update destination file with applied modifiers
	writeDestinationFile(destPath, luaModifiers.applyModifiers(source, path))
end

local function measure<T...>(message: string, measuredFunction: () -> ())
	local startTime = os.clock()
	measuredFunction()

	local elapsed = (os.clock() - startTime) * 1000
	local ms: string = string.format("%.0f", elapsed)
	local color: string
	if elapsed > 10 then
		color = elapsed > 100 and stdio.color("red") or stdio.color("yellow")
	else
		color = stdio.color("green")
	end

	stdio.write(`{message} in {color}{ms}{stdio.color("reset")} ms\n`)
end

local function fileChanged(path: string, destPath: string)
	if path:match("%.lua[u]?$") == nil then
		writeDestinationFile(destPath, fs.readFile(path))
		return true
	end

	local source = fs.readFile(path)
	local compiled, lineNumber, errorString = canCompile(source)
	if compiled then
		processLuaFile(path, destPath)
		return true
	end

	local pathText = colorText(path, "cyan")
	if lineNumber and errorString then
		local lineNumberText = colorText(tostring(lineNumber), "yellow")
		local errorText = colorText(errorString, "red")

		stdio.write(`Compile error in {pathText}:{lineNumberText}: {errorText}\n`)
		return false
	else
		stdio.write(`{pathText} compile failed.\n`)
		return false
	end
end

--[[
	outputDir: the destination directory name, defaults to ".dev"
	projectFilePath: the path to the project.json file, defaults to "default.project.json"
	watchFolders: these folders are copied and watched for changes, lua files are processed
	noWatchFolders: these folders are processed with darklua, but not watched for changes
	otherFoldersAndFiles: these folders and files are copied as is, no processing, defaults to darklua.json and default.project.json
]]
local function darklune(config: {
	outputDir: string?,
	projectFilePath: string?,
	darkluaConfigPath: string?,
	watchFolders: { string }?,
	noWatchFolders: { string }?,
	otherFoldersAndFiles: { string }?,
	stdio: (process.SpawnOptionsStdioKind | process.SpawnOptionsStdio)?,
})
	local outputDir = config.outputDir or ".dev"
	local projectFilePath = config.projectFilePath or "default.project.json"
	local darkluaConfigPath = config.darkluaConfigPath or "darklua.json"
	local watchFolders = config.watchFolders or {} :: { string }
	local noWatchFolders = config.noWatchFolders or {} :: { string }
	local otherFoldersAndFiles = config.otherFoldersAndFiles or {} :: { string }

	luaModifiers.init(darkluaConfigPath)

	if not table.find(otherFoldersAndFiles, darkluaConfigPath) then
		table.insert(otherFoldersAndFiles, darkluaConfigPath)
	end
	if not table.find(otherFoldersAndFiles, projectFilePath) then
		table.insert(otherFoldersAndFiles, projectFilePath)
	end

	-- recreate the destination directory
	if fs.isDir(outputDir) then
		fs.removeDir(outputDir)
	end
	fs.writeDir(outputDir)

	-- these are files like darklua.json and default.project.json
	for _, folder in otherFoldersAndFiles do
		fs.copy(folder, `{outputDir}/{folder}`, true)
	end

	-- these are folders that are processed with darklua, but not watched for changes
	for _, folder in noWatchFolders do
		task.spawn(function()
			process.spawn("darklua", { "process", folder, `{outputDir}/{folder}` }, {
				stdio = config.stdio,
			})
		end)
	end

	-- build internal file map for non darklua file processing
	luaModifiers.buildFileMap(projectFilePath)

	-- copy folders that process lua files
	for _, folder in watchFolders do
		process.spawn("darklua", { "process", folder, `{outputDir}/{folder}` }, {
			stdio = config.stdio,
		})

		task.spawn(fileWatcher.watch, {
			path = folder,
			onFileCreated = function(path)
				measure(`Created {colorText(path, "cyan")}`, function()
					local sourcemap = luaModifiers.buildFileMap(projectFilePath)
					if sourcemap then
						scheduleUpdateSourcemap(sourcemap)
					end

					fileChanged(path, `{outputDir}/{path}`)
				end)
			end,
			onFileChanged = function(path)
				measure(`Updated {colorText(path, "cyan")}`, function()
					fileChanged(path, `{outputDir}/{path}`)
				end)
			end,
			onFileRemoved = function(path)
				measure(`Removed {colorText(path, "cyan")}`, function()
					if fs.isFile(`{outputDir}/{path}`) then
						fs.removeFile(`{outputDir}/{path}`)
					end
					local sourcemap = luaModifiers.buildFileMap(projectFilePath)
					if sourcemap then
						scheduleUpdateSourcemap(sourcemap)
					end
					return true
				end)
			end,
			onDirectoryCreated = function(path)
				fs.writeDir(`{outputDir}/{path}`)
			end,
			onDirectoryRemoved = function(path)
				fs.removeDir(`{outputDir}/{path}`)
			end,
		})
	end
end

return darklune
