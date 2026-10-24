--[[
Renders single photos in nested LrExportSessions (start/await for RenderQueue).

The publish settings are copied without the service-provider and publish keys, so the
nested export is a plain "export to folder" and never re-enters this plugin.
]]

local LrDate = import("LrDate")
local LrExportSession = import("LrExportSession")
local LrFileUtils = import("LrFileUtils")
local LrPathUtils = import("LrPathUtils")
local LrTasks = import("LrTasks")

local M = {}

-- Keys that would turn the nested export into a publish/plugin export.
local DROP_PREFIXES = { "LR_exportServiceProvider", "LR_publish", "LR_export_postProcessing" }

local function dropped(key)
	for _, prefix in ipairs(DROP_PREFIXES) do
		if key:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

--[[
Copy LR_* keys from the export property table. Returns settings, method, count.
Property tables are not plain tables, so try pairs() first and the raw contents second.
]]
function M.copySettings(propertyTable)
	local sources = {
		{
			"pairs",
			function()
				return propertyTable
			end,
		},
		{
			"contents",
			function()
				return propertyTable["< contents >"]
			end,
		},
	}
	for _, source in ipairs(sources) do
		local settings, count = {}, 0
		local ok = pcall(function()
			for k, v in pairs(source[2]()) do
				if type(k) == "string" and k:sub(1, 3) == "LR_" and not dropped(k) then
					settings[k] = v
					count = count + 1
				end
			end
		end)
		if ok and count > 0 then
			return settings, source[1], count
		end
	end
	return nil, "none", 0
end

--- Fresh temp folder for one publish run.
function M.makeFolder()
	local folder = LrPathUtils.child(
		LrPathUtils.getStandardFilePath("temp"),
		string.format("lrflickr-%d", math.floor(LrDate.currentTime() * 1000))
	)
	LrFileUtils.createAllDirectories(folder)
	return folder
end

--- Returns start, await functions for RenderQueue.
function M.renderer(baseSettings, folder)
	local settings = {}
	for k, v in pairs(baseSettings) do
		settings[k] = v
	end
	settings.LR_export_destinationType = "specificFolder"
	settings.LR_export_destinationPathPrefix = folder
	settings.LR_export_useSubfolder = false
	settings.LR_collisionHandling = "rename"
	settings.LR_reimportExportedPhoto = false

	-- One background task owns each session: iterating renditions() starts its rendering
	-- exactly once. (doExportOnNewTask + renditions() raced: "startRendering: can not call
	-- twice on same session".)
	local function start(photo)
		local job = { started = LrDate.currentTime() }
		LrTasks.startAsyncTask(function()
			local ok, err = LrTasks.pcall(function()
				local session = LrExportSession({ photosToExport = { photo }, exportSettings = settings })
				for _, rendition in session:renditions() do
					job.ok, job.result = rendition:waitForRender()
				end
			end)
			if not ok then
				job.ok, job.result = false, "render task failed: " .. tostring(err)
			elseif job.ok == nil then
				job.ok, job.result = false, "no rendition produced"
			end
			job.done = true
		end, "lrflickr render")
		return job
	end

	local function await(job)
		while not job.done do
			LrTasks.sleep(0.05)
		end
		return job.ok, job.result
	end

	return start, await
end

return M
