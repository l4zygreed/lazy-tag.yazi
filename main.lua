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
-- Search domain of the synthetic tag-ordered listing; also how we recognise our
-- own folder when a `cd` comes back to us.
local VIEW_DOMAIN = "lazy-tag"
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
		return info("Nothing to prune, every tagged file is still there")
	end
	drop_paths(gone)
	info("Pruned %d of %d tags", #gone, #paths)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                          Views                          │
--          ╰─────────────────────────────────────────────────────────╯

-- Yazi has no hook for custom sorting, so a tag-ordered listing has to be fed
-- to it as a synthetic `search://` folder. Two things make that work: file ops
-- are keyed by URL, so `search://lazy-tag//x` is never clobbered by a reload of
-- `/x`; and yazi re-sorts after every `update_files` unless the tab's sort is
-- `none`, which is why the "first" mode has to borrow that setting while it is
-- on. The "only" mode needs no ordering, so it leaves sorting alone.

--- Pref field -> the option name the `sort` command expects.
local SORT_OPTS = {
	sort_by = "by",
	sort_reverse = "reverse",
	sort_dir_first = "dir_first",
	sort_sensitive = "sensitive",
	sort_translit = "translit",
	sort_fallback = "fallback",
}

--- `ChaMode::T_DIR`. The synthetic folder never comes from disk, so a bare
--- directory `Cha` is all `update_files`'s `done` needs.
local DIR_CHA = { kind = 0, mode = 0x4000 }

-- `Id` has no `__tostring`, and its userdata is rebuilt per scope, so the
-- numeric value is the only stable key. The `cd` payload reports it as a plain
-- integer, which keeps both sides in agreement.
local active_tab = ya.sync(function() return cx.active.id.value end)

local view_mode = ya.sync(function(st, tab)
	local view = st.views[tab]
	return view and view.mode or nil
end)

--- The current listing, tagged files hoisted to the front. Order within each
--- group is left alone, and since `cx.active.current.files` already arrives in
--- the user's sort order, that is the configured order for free.
---@return table files, integer tagged
local function ordered_files(st, mode)
	local cur = cx.active.current
	local tagged, rest = {}, {}
	for i = 1, #cur.files do
		local f = cur.files[i]
		if st.db[key_of(f.url)] then
			tagged[#tagged + 1] = f.bare
		elseif mode == "first" then
			rest[#rest + 1] = f.bare
		end
	end

	local n = #tagged
	for _, f in ipairs(rest) do
		tagged[#tagged + 1] = f
	end
	return tagged, n
end

local function push_listing(cwd, files)
	local id = ya.id("ft") -- a fresh files ticket, so our part/done pair matches
	-- Every emit consumes the Url it is given, so hand each one its own.
	local function target() return Url(cwd):into_search(VIEW_DOMAIN) end

	ya.emit("cd", { target(), source = "search" })
	-- An empty part resets the folder and claims the ticket; the next one fills
	-- it in our order.
	ya.emit("update_files", { op = fs.op("part", { id = id, url = target(), files = {} }) })
	ya.emit("update_files", { op = fs.op("part", { id = id, url = target(), files = files }) })
	ya.emit("update_files", { op = fs.op("done", { id = id, url = target(), cha = Cha(DIR_CHA) }) })
end

local function emit_sort(saved)
	local opts = {}
	for field, name in pairs(SORT_OPTS) do
		opts[name] = saved[field]
	end
	ya.emit("sort", opts)
end

local function restore_sort(st, tab)
	local saved = st.sorts[tab]
	if saved then
		st.sorts[tab] = nil
		emit_sort(saved)
	end
end

---@param rebuild boolean? true when following the user into a new directory
local enter_view = ya.sync(function(st, tab, mode, rebuild)
	local files, tagged = ordered_files(st, mode)
	if tagged == 0 and not rebuild then
		return fail("Nothing is tagged here")
	end

	if mode ~= "first" then
		restore_sort(st, tab)
	else
		if not st.sorts[tab] then
			local pref = cx.active.pref
			st.sorts[tab] = {
				sort_by = pref.sort_by,
				sort_reverse = pref.sort_reverse,
				sort_dir_first = pref.sort_dir_first,
				sort_sensitive = pref.sort_sensitive,
				sort_translit = pref.sort_translit,
				sort_fallback = pref.sort_fallback,
			}
		end
		-- Borrow the sort setting, otherwise `update_files` would immediately
		-- re-sort the listing we are about to push.
		ya.emit("sort", { by = "none" })
	end

	local cwd = tostring(cx.active.current.cwd.path)
	st.views[tab] = { mode = mode, cwd = cwd }
	if tagged > 0 then
		push_listing(cwd, files)
	end
end)

--- Give the sort setting back so the directory we just entered gets ordered
--- properly; `enter_view` borrows it again on the way through.
local rearm_view = ya.sync(function(st, tab)
	if st.sorts[tab] then
		emit_sort(st.sorts[tab])
	end
end)

local leave_view = ya.sync(function(st, tab)
	if not st.views[tab] then
		return
	end

	st.views[tab] = nil
	if cx.active.current.cwd.is_search then
		-- Escaping produces a `cd` back to the directory the view was built for,
		-- which is byte-for-byte what the user pressing <Esc> looks like. Mark it
		-- so the handler lets that one event through untouched.
		st.skips[tab] = (st.skips[tab] or 0) + 1
		ya.emit("escape", { search = true })
	end
	restore_sort(st, tab)
end)

--          ╭─────────────────────────────────────────────────────────╮
--          │                          Setup                          │
--          ╰─────────────────────────────────────────────────────────╯

function M:setup(opts)
	local st = self
	opts = opts or {}

	st.db = {}
	st.color = opts.color or DEFAULT_COLOR
	st.key = opts.key or DEFAULT_KEY
	-- Both keyed by tab id: sorting is a per-tab preference, so the view has to
	-- be too.
	st.views = {}
	st.sorts = {}
	st.skips = {}

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
	-- Keep a view alive across navigation. Landing back on the directory the
	-- view was built for means the user escaped out of it; landing anywhere else
	-- means they navigated, so rebuild there.
	ps.sub("cd", function(body)
		local tab = body.tab
		-- Checked before anything else, so the count can never be left stranded.
		if (st.skips[tab] or 0) > 0 then
			st.skips[tab] = st.skips[tab] - 1
			return
		end

		local view = st.views[tab]
		if not view or tab ~= cx.active.id.value then
			return
		end

		-- The local `cd` payload carries only a tab id -- `EmberCd::owned` drops
		-- the url for in-process subscribers -- so read the destination from the
		-- context. A search cwd is our own listing landing; ignore it.
		local cwd = cx.active.current.cwd
		if cwd.is_search then
			return
		end

		if tostring(cwd.path) == view.cwd then
			return leave_view(tab)
		end

		-- A directory loaded while we hold `sort=none` arrives in raw readdir
		-- order, so hand the setting back first and let yazi sort it. Both emits
		-- are queued, so by the time we are re-entered the listing is in the
		-- user's order and ready to snapshot.
		rearm_view(tab)
		ya.emit("plugin", { PKG, ya.quote("view") .. " --rebuild" })
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

local ACTIONS = { toggle = true, clear = true, select = true, jump = true, prune = true, view = true }

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
	elseif action == "view" then
		local tab = active_tab()
		local mode = job.args.only and "only" or "first"

		if job.args.off or (not job.args.rebuild and view_mode(tab) == mode) then
			leave_view(tab)
		elseif job.args.rebuild then
			enter_view(tab, view_mode(tab), true)
		elseif view_mode(tab) then
			-- Switching modes: the listing we are standing in no longer holds the
			-- untagged files, so drop back to the real directory first and come
			-- through the queue again once it has reloaded.
			leave_view(tab)
			ya.emit("plugin", { PKG, ya.quote("view") .. (job.args.only and " --only" or "") })
		else
			enter_view(tab, mode)
		end
	end
end

return M
