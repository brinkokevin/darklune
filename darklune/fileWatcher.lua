local fs = require("@lune/fs")
local task = require("@lune/task")

local fileWatcher = {}

local function getModifiedAt(path: string): number
	local modifiedAt = fs.metadata(path).modifiedAt
	return modifiedAt and modifiedAt.unixTimestamp or 0
end

local function scanDirectory(dir: string, pattern: string)
	local files, directories = {}, {}
	local function scan(path: string)
		for _, entry in ipairs(fs.readDir(path)) do
			local fullPath = `{path}/{entry}`
			if fs.isDir(fullPath) then
				directories[fullPath] = true
				scan(fullPath)
			elseif entry:match(pattern) then
				files[fullPath] = getModifiedAt(fullPath)
			end
		end
	end
	scan(dir)
	return files, directories
end

export type FileWatchOptions = {
	path: string?,
	pattern: string?,
	onFileCreated: ((string) -> ())?,
	onFileChanged: ((string) -> ())?,
	onFileRemoved: ((string) -> ())?,
	onDirectoryCreated: ((string) -> ())?,
	onDirectoryRemoved: ((string) -> ())?,
	checkInterval: number?,
}

local function noop() end

function fileWatcher.watch(options: FileWatchOptions)
	local dir = options.path or "."
	local pattern = options.pattern or ".*"
	local checkInterval = options.checkInterval or 0.2

	local onFileCreated = options.onFileCreated or noop
	local onFileChanged = options.onFileChanged or noop
	local onFileRemoved = options.onFileRemoved or noop
	local onDirectoryCreated = options.onDirectoryCreated or noop
	local onDirectoryRemoved = options.onDirectoryRemoved or noop

	local fileStates, directoryStates = scanDirectory(dir, pattern)
	local lastScanTime = os.clock()

	local function updateStates()
		local currentTime = os.clock()
		if currentTime - lastScanTime < checkInterval then
			return
		end
		lastScanTime = currentTime

		local currentFiles, currentDirectories = scanDirectory(dir, pattern)

		for fullPath, modifiedAt in pairs(currentFiles) do
			if not fileStates[fullPath] then
				task.spawn(onFileCreated, fullPath)
			elseif modifiedAt ~= fileStates[fullPath] then
				task.spawn(onFileChanged, fullPath)
			end
		end

		for fullPath in pairs(fileStates) do
			if not currentFiles[fullPath] then
				task.spawn(onFileRemoved, fullPath)
			end
		end

		for fullPath in pairs(currentDirectories) do
			if not directoryStates[fullPath] then
				task.spawn(onDirectoryCreated, fullPath)
			end
		end

		for fullPath in pairs(directoryStates) do
			if not currentDirectories[fullPath] then
				task.spawn(onDirectoryRemoved, fullPath)
			end
		end

		fileStates, directoryStates = currentFiles, currentDirectories
	end

	while true do
		updateStates()
		task.wait()
	end
end

function fileWatcher.watchDirectory(
	watchPath: string,
	onChange: (
		action: "create" | "change" | "remove" | "directoryCreate" | "directoryRemove",
		path: string
	) -> ()
)
	fileWatcher.watch({
		path = watchPath,
		onFileCreated = function(path)
			onChange("create", path)
		end,
		onFileChanged = function(path)
			onChange("change", path)
		end,
		onFileRemoved = function(path)
			onChange("remove", path)
		end,
		onDirectoryCreated = function(path)
			onChange("directoryCreate", path)
		end,
		onDirectoryRemoved = function(path)
			onChange("directoryRemove", path)
		end,
	})
end

function fileWatcher.watchFile(filePath: string, onFileChanged: (string) -> ())
	local lastModified = getModifiedAt(filePath)

	while true do
		local latestModifiedAt = getModifiedAt(filePath)
		if latestModifiedAt ~= lastModified then
			onFileChanged(filePath)
			lastModified = latestModifiedAt
		end
		task.wait()
	end
end

return fileWatcher
