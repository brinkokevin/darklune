# DarkLune

DarkLune is a lune script that watches for file changes and applies `convert_require` and `inject_global_value` generators to the files.

## Usage

1. Copy the `darklune` folder to your `.lune` folder.
2. Create a new lune script `.lune/dev.lua` with the following code
3. Run `lune run dev` to start working

```lua
-- .lune/dev.lua
local darklune = require("./darklune")
local process = require("darklua.process")

local OUTPUT_DIR = "dev"
local PROJECT_FILE_PATH = "default.project.json"
local DARKLUA_CONFIG_PATH = "darklua.json"

-- Start darklune
darklune({
    outputDir = OUTPUT_DIR,
    projectFilePath = PROJECT_FILE_PATH,
    darkluaConfigPath = DARKLUA_CONFIG_PATH,
    watchFolders = { "src" },
    noWatchFolders = { "Packages", "ServerPackages" },
    otherFoldersAndFiles = {},
    stdio = "inherit",
})

-- Start the Rojo server
process.spawn("rojo", { "serve", PROJECT_FILE_PATH }, {
    cwd = OUTPUT_DIR,
    stdio = "inherit",
})
```

## How it works

When darklune starts, it will:

- Delete the old outputDir folder if it exists.
- Create a new outputDir folder.
- Copy over the necessary files like `darklua.json` and `default.project.json`
- Run `darklua process` to copy over the necessary folders defined in `watchFolders` and `noWatchFolders`
- It will then watch for file changes in the watchFolders directories
- When a file is changed, it will apply the `convert_require` and `inject_global_value` generators to the file and save them to the outputDir
- It will also automatically regenerate `sourcemap.json` as files are changed.
