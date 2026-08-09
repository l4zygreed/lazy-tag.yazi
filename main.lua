--- @since 26.5.6
--- @sync entry

local PKG = "lazy-tag"

-- Tags live in a DDS static message. Yazi's DDS server keeps the latest value
-- of every `@`-prefixed kind, replays it to each instance that connects, and
-- flushes it to `~/.local/state/yazi/.dds` when the last instance exits. That
-- gives cross-instance sync and persistence without ever touching the disk here.
local KIND = "@lazy-tag"

local DEFAULT_KEY = "*"
local DEFAULT_COLOR = "red"
-- `Entity` draws the file name at order 4000, so anything below that lands in
-- front of it. 3500 sits between the search prefix (3000) and the name.
local DEFAULT_ORDER = 3500

local SEP = package.config:sub(1, 1)

-- Offered when `--pick` waits for a keypress: every printable ASCII character.
local PICK_CANDS = {}
for b = 0x21, 0x7e do
	PICK_CANDS[#PICK_CANDS + 1] = { on = string.char(b) }
end

local M = {}

local function fail(s, ...)
	ya.notify { title = PKG, content = string.format(s, ...), timeout = 5, level = "error" }
end

local function info(s, ...)
	ya.notify { title = PKG, content = string.format(s, ...), timeout = 3, level = "info" }
end

--- The database key of a file: its plain filesystem path, so a tag set while
--- browsing normally is still visible on the same file inside search results.
---
--- Paths are used verbatim rather than nested per-directory because yazi turns
--- a JSON object key that parses as an integer back into an integer, which
--- would lose the tags of any file named e.g. `2024`. Absolute paths never
--- parse as integers.
---@param url Url
---@return string
local function key_of(url) return tostring(url.path) end

local function publish(st)
	-- Publishing `nil` drops the kind from the DDS state entirely, so an empty
	-- database doesn't leave a stale line behind in `.dds`.
	ps.pub_to(0, KIND, next(st.db) ~= nil and st.db or nil)
	ui.render()
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                        Rendering                        │
--          ╰─────────────────────────────────────────────────────────╯

local function draw(entity, st)
	local tag = st.db[key_of(entity._file.url)]
	if not tag then
		return ""
	end

	-- The hovered line is normally drawn reversed, which would turn a red
	-- foreground into a red background; swap them so the tag stays red.
	local style
	if entity._file.is_hovered and entity:style():raw().reversed then
		style = ui.Style():bg(st.color)
	else
		style = ui.Style():fg(st.color)
	end
	return ui.Span(tag .. " "):style(style)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                        Mutations                        │
--          ╰─────────────────────────────────────────────────────────╯

---@return Url[] the selected files, or the hovered one when nothing is selected
local function targets()
	local tab, urls = cx.active, {}
	for _, u in pairs(tab.selected) do
		urls[#urls + 1] = u
	end
	if #urls == 0 and tab.current.hovered then
		urls[1] = tab.current.hovered.url
	end
	return urls
end

--- Toggle `key` on the selected (or hovered) files, or remove their tags when
--- `key` is nil. A file only ever carries one tag, so tagging with a different
--- key replaces whatever was there.
local apply = ya.sync(function(st, key)
	local paths = {}
	for _, url in ipairs(targets()) do
		if not (url.is_regular or url.is_search) then
			return fail("`%s` lives on a virtual filesystem and cannot be tagged", tostring(url))
		end
		paths[#paths + 1] = key_of(url)
	end
	if #paths == 0 then
		return
	end

	-- Ranger-style group toggle: if every target already carries this exact tag
	-- the whole group is untagged, otherwise the whole group gets it.
	local tag = key
	if key then
		local all = true
		for _, p in ipairs(paths) do
			if st.db[p] ~= key then
				all = false
				break
			end
		end
		if all then
			tag = nil
		end
	end

	for _, p in ipairs(paths) do
		st.db[p] = tag
	end
	publish(st)
end)

--          ╭─────────────────────────────────────────────────────────╮
--          │                       Navigation                        │
--          ╰─────────────────────────────────────────────────────────╯

local select_tagged = ya.sync(function(st, key)
	local files, urls = cx.active.current.files, {}
	for i = 1, #files do
		local tag = st.db[key_of(files[i].url)]
		if tag and (not key or tag == key) then
			urls[#urls + 1] = tostring(files[i].url)
		end
	end

	ya.emit("escape", { select = true })
	if #urls > 0 then
		urls.state = "on"
		ya.emit("toggle_all", urls)
	end
end)

local jump_tagged = ya.sync(function(st, key, first)
	local files, target = cx.active.current.files, nil
	for i = 1, #files do
		local tag = st.db[key_of(files[i].url)]
		if tag and (not key or tag == key) then
			target = i
			if first then
				break
			end
		end
	end

	if target then
		-- `cursor` is 0-based, `files` is 1-based.
		ya.emit("arrow", { target - 1 - cx.active.current.cursor })
	end
end)

--          ╭─────────────────────────────────────────────────────────╮
--          │                     Following files                     │
--          ╰─────────────────────────────────────────────────────────╯

--- Yield `path` itself, then each of its ancestor directories, along with the
--- part of `path` that hangs below them. Lets a directory that was moved or
--- deleted take the tags of everything under it along, in one pass over the
--- database and without scanning it once per change.
local function lineage(path)
	local i = 1
	return function()
		if i == 1 then
			i = 2
			return path, ""
		end

		local at = path:find(SEP, i, true)
		if not at then
			return
		end
		i = at + 1
		return path:sub(1, at - 1), path:sub(at)
	end
end

---@return string? the new path of `path` after the `from -> to` moves in `map`
local function remap(map, path)
	for ancestor, below in lineage(path) do
		if map[ancestor] then
			return map[ancestor] .. below
		end
	end
end

---@param changes { from: Url, to: Url }[]
local function transfer(st, changes, keep)
	local map = {}
	for _, c in ipairs(changes) do
		map[key_of(c.from)] = key_of(c.to)
	end

	local moved, gone = {}, {}
	for path, tag in pairs(st.db) do
		local dest = remap(map, path)
		if dest then
			moved[dest] = tag
			gone[#gone + 1] = path
		end
	end
	if not next(moved) then
		return
	end

	if not keep then
		for _, path in ipairs(gone) do
			st.db[path] = nil
		end
	end
	for path, tag in pairs(moved) do
		st.db[path] = tag
	end
	publish(st)
end

local function forget(st, urls)
	-- `remap` concatenates the destination, so an empty one makes every hit an
	-- empty string, which is still truthy in Lua.
	local map = {}
	for _, url in ipairs(urls) do
		map[key_of(url)] = ""
	end

	local gone = {}
	for path in pairs(st.db) do
		if remap(map, path) then
			gone[#gone + 1] = path
		end
	end
	if #gone == 0 then
		return
	end

	for _, path in ipairs(gone) do
		st.db[path] = nil
	end
	publish(st)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                         Pruning                         │
--          ╰─────────────────────────────────────────────────────────╯

local tagged_paths = ya.sync(function(st)
	local paths = {}
	for path in pairs(st.db) do
		paths[#paths + 1] = path
	end
	return paths
end)

local drop_paths = ya.sync(function(st, paths)
	for _, path in ipairs(paths) do
		st.db[path] = nil
	end
	publish(st)
end)

--- Drop the tags of files that are no longer there. Only reachable from an
--- async run, because `fs.cha` cannot stat from yazi's main thread.
local function prune()
	local paths = tagged_paths()
	local gone = {}
	for _, path in ipairs(paths) do
		-- Without following symlinks: a dangling symlink is still a file that
		-- exists, and its tag should survive.
		if not fs.cha(Url(path), false) then
			gone[#gone + 1] = path
		end
	end

	if #gone == 0 then
		return info("Nothing to prune, all %d tagged files are still there", #paths)
	end
	drop_paths(gone)
	info("Pruned %d of %d tags", #gone, #paths)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                          Setup                          │
--          ╰─────────────────────────────────────────────────────────╯

function M:setup(opts)
	local st = self
	opts = opts or {}

	st.db = {}
	st.color = opts.color or DEFAULT_COLOR
	st.key = opts.key or DEFAULT_KEY

	Entity:children_add(
		function(entity) return draw(entity, st) end,
		tonumber(opts.order) or DEFAULT_ORDER
	)

	-- The DDS server only records a static message while at least one client is
	-- subscribed to that kind, so this subscription is what makes tags persist.
	-- It also replays the stored database right after yazi starts.
	ps.sub_remote(KIND, function(body)
		st.db = body or {}
		ui.render()
	end)

	-- Local subscriptions: only this instance's own file operations are handled.
	-- Other instances run their own copy of the plugin and share the result.
	ps.sub("rename", function(body) transfer(st, { body }) end)
	ps.sub("bulk", function(body)
		local changes = {}
		for from, to in pairs(body) do
			changes[#changes + 1] = { from = from, to = to }
		end
		transfer(st, changes)
	end)
	ps.sub("move", function(body) transfer(st, body.items) end)
	ps.sub("duplicate", function(body) transfer(st, body.items, true) end)
	ps.sub("delete", function(body) forget(st, body.urls) end)
	ps.sub("trash", function(body) forget(st, body.urls) end)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                          Entry                          │
--          ╰─────────────────────────────────────────────────────────╯

local default_key = ya.sync(function(st) return st.key end)

--- Wait for a single keypress, ranger-style: no popup, no input field.
---@return string?
local function pick()
	local idx = ya.which { cands = PICK_CANDS, silent = true }
	return idx and PICK_CANDS[idx].on
end

local ACTIONS = { toggle = true, clear = true, select = true, jump = true, prune = true }

--- Two things cannot happen on yazi's main thread, which is where a `@sync
--- entry` runs: `ya.which` waiting for a key, and `fs.cha` stat-ing a file. An
--- invocation that needs either hands itself to the scheduler once, so bindings
--- never have to mention `--mode=async`.
local function needs_async(job) return job.args.pick or job.args[1] == "prune" end

local function reenter(job)
	local args = { ya.quote(job.args[1]), "--async" }
	for _, flag in ipairs { "pick", "first" } do
		if job.args[flag] then
			args[#args + 1] = "--" .. flag
		end
	end
	if job.args.key then
		args[#args + 1] = ya.quote("--key=" .. tostring(job.args.key))
	end
	ya.emit("plugin", { PKG, table.concat(args, " "), mode = "async" })
end

---@param job { args: table }
function M:entry(job)
	local action = job.args[1]
	if not ACTIONS[action] then
		return fail("Unknown action: `%s`", tostring(action))
	end
	if needs_async(job) and not job.args.async then
		return reenter(job)
	end

	local key = job.args.key and tostring(job.args.key) or nil
	if job.args.pick then
		key = pick()
		if not key then
			return
		end
	end
	if key and utf8.len(key) ~= 1 then
		return fail("A tag is a single character, but `%s` was given", key)
	end

	if action == "toggle" then
		apply(key or default_key())
	elseif action == "clear" then
		apply(nil)
	elseif action == "select" then
		select_tagged(key)
	elseif action == "jump" then
		jump_tagged(key, job.args.first)
	elseif action == "prune" then
		prune()
	end
end

return M
