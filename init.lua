-- Claude Session HUD
-- Persistent overlay showing which Claude sessions are in which Warp tabs
-- Auto-learns tab names by watching Cmd+number keystrokes
-- Uses fullScreenAuxiliary to render over full-screen apps

require("hs.ipc")  -- enable CLI communication

-- Globals for debugging via hs CLI
hudCanvas = nil
hudVisible = false
hudEnabled = true
currentTab = nil  -- tracks the active tab number
hoveredTab = nil  -- tracks which tab the cursor is over
sessionWatcher = nil
appWatcher = nil
spaceWatcher = nil
tabWatcher = nil
debounceTimer = nil
clickWatcher = nil
hoverWatcher = nil
tabHitZones = {}      -- maps tab digit -> {x1, x2} in screen coords
tooltipCanvas = nil   -- lightweight canvas for hover tooltip
leftIndicatorCanvas = nil  -- left-side selected tab indicator (near typing area)
tabFullLabels = {}    -- maps tab digit -> full untruncated label string
local showTooltip     -- forward-declared; defined near hover watcher
local hideTooltip     -- forward-declared; defined near hover watcher
local hideLeftIndicator   -- forward-declared; defined near left indicator
local updateLeftIndicator -- forward-declared; defined near left indicator
local autoSyncTTYs        -- forward-declared; defined near TTY sync
hudScreenFrame = nil   -- {x, y, w, h} of the HUD on screen
flashingTabs = {}      -- set of tab numbers currently flashing (red/waiting)
doneFlashingTabs = {}  -- set of tab numbers flashing cyan (done/unseen)
flashState = true      -- toggles every 0.5s (true = bright, false = dim)
animTick = 0          -- incremented by animTimer; drives both flash toggle and smooth pulse

-- Session cache: avoid re-reading files on every updateHud()
local cachedSessions = nil
local sessionsDirty = true  -- force initial read

-- State cache: avoid file I/O on animation frames
local cachedStates = { waiting = {}, active = {}, done = {} }
local statesDirty = true

-- Single unified animation timer (replaces separate flash + spinner timers)
local animTimer = nil
local animNeeded = false  -- true when any tab needs animation (flash or spinner)

-- Animation index map: card tab number → canvas element indices for border/bg
-- Allows animation ticks to update only colors without full rebuild
local cardElementMap = {}  -- { [tabNum] = { bgIdx=N, borderIdx=N } }

-- Self-monitoring: CPU% and RAM of Hammerspoon process (sampled every 5s)
local selfCpu = "–"
local selfRam = "–"
local selfStatsTimer = nil

-- CWD cache: maps TTY string → last-known working directory
local cachedCWDs = {}
local cwdRefreshTimer = nil

-- Layout config
local HUD_WIDTH = 700         -- fixed width
local HUD_HEIGHT = 38         -- two-line height (folder name + tab name)
local HUD_RIGHT_MARGIN = 200   -- gap from right edge of Warp window
local HUD_BOTTOM_OFFSET = 62  -- from bottom of Warp window (below status line notices)
local HUD_FONT_SIZE = 11
local HUD_FOLDER_FONT_SIZE = 10
local HUD_FOLDER_COLOR = { red = 0.65, green = 0.65, blue = 0.72, alpha = 0.9 }
local HUD_BG_ALPHA = 0.85
local LEFT_INDICATOR_LEFT_MARGIN = 420  -- distance from left edge of Warp window
local LEFT_INDICATOR_BOTTOM_OFFSET = 82  -- from bottom of Warp window (higher than HUD)
local HUD_CORNER_RADIUS = 5
local MAX_NAME_LENGTH = 10
local SESSION_DIR = os.getenv("HOME") .. "/.claude-hud"

-- Shell names to filter out (Warp returns process name, not custom tab name)
local SHELL_NAMES = { zsh = true, bash = true, fish = true, sh = true, [""] = true }
local function isMeaningfulTitle(title)
    if not title or title == "" then return false end
    local first = title:lower():match("^(%S+)")
    return first and not SHELL_NAMES[first]
end

-- Generic app titles that shouldn't overwrite more specific session names
local function isGenericAppTitle(title)
    if not title then return false end
    local clean = title:gsub("^[^%w]+", ""):lower()
    return clean == "claude code" or clean == "claude"
end

-- macOS key codes for digit keys 1-9
local DIGIT_KEYCODES = {
    [18] = 1, [19] = 2, [20] = 3, [21] = 4,
    [23] = 5, [22] = 6, [26] = 7, [28] = 8, [25] = 9,
}
local KEYCODE_T = 17  -- Cmd+T (new tab)
local KEYCODE_W = 13  -- Cmd+W (close tab)

-- Write a session entry
local function writeSession(num, name)
    local f = io.open(SESSION_DIR .. "/" .. tostring(num), "w")
    if f then
        f:write(name)
        f:close()
    end
    sessionsDirty = true
end

-- Persist currentTab to file so hook scripts can read it
-- IMPORTANT: Only write when value changes to avoid pathwatcher feedback loop
-- (updateHud → writeCurrentTab → pathwatcher → updateHud → ∞)
local lastWrittenTab = nil
local function writeCurrentTab()
    if currentTab == lastWrittenTab then return end
    lastWrittenTab = currentTab
    local f = io.open(SESSION_DIR .. "/current", "w")
    if f then
        f:write(tostring(currentTab or ""))
        f:close()
    end
end

-- Lock/unlock: manually named tabs are protected from auto-overwrite
local function isLocked(num)
    local f = io.open(SESSION_DIR .. "/" .. tostring(num) .. ".lock", "r")
    if f then f:close(); return true end
    return false
end

local function setLock(num, locked)
    local path = SESSION_DIR .. "/" .. tostring(num) .. ".lock"
    if locked then
        local f = io.open(path, "w"); if f then f:write("1"); f:close() end
    else
        os.remove(path)
    end
end

-- Read TTY string for a tab (helper used by multiple functions)
local function readTTY(num)
    local f = io.open(SESSION_DIR .. "/" .. tostring(num) .. ".tty", "r")
    if f then
        local tty = f:read("*l")
        f:close()
        return (tty and tty ~= "") and tty or nil
    end
    return nil
end

-- Refresh CWD cache for all known TTYs (async — no blocking I/O)
local function refreshCWDs()
    local ttys = {}
    for i = 1, 9 do
        local tty = readTTY(i)
        if tty then ttys[#ttys + 1] = tty end
    end
    if #ttys == 0 then return end

    -- Build a single bash script that finds CWD for each TTY's shell
    local cmds = {}
    for _, tty in ipairs(ttys) do
        cmds[#cmds + 1] = string.format(
            'pid=$(ps -t %s -o pid=,comm= 2>/dev/null | awk \'$2~/-?(zsh|bash|fish)$/{print $1; exit}\'); '
            .. 'if [ -n "$pid" ]; then cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk \'/^n/{print substr($0,2)}\'); '
            .. 'echo "%s:$cwd"; fi',
            tty, tty
        )
    end
    local script = table.concat(cmds, "\n")

    hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
        if exitCode ~= 0 or not stdout then return end
        local changed = false
        for line in stdout:gmatch("[^\n]+") do
            local tty, cwd = line:match("^([^:]+):(.+)$")
            if tty and cwd and cwd ~= "" then
                if cachedCWDs[tty] ~= cwd then
                    cachedCWDs[tty] = cwd
                    changed = true
                end
            end
        end

        -- Override with hook-written .cwd files (Claude's actual project dir)
        -- Claude Code's Bash sandbox uses a different CWD than the shell process;
        -- the hook writes the real project dir to {tty}.cwd on each prompt.
        local now = os.time()
        for _, tty in ipairs(ttys) do
            local cwdFile = SESSION_DIR .. "/" .. tty .. ".cwd"
            local info = hs.fs.attributes(cwdFile)
            if info and (now - info.modification) < 3600 then
                local f = io.open(cwdFile, "r")
                if f then
                    local hookCwd = f:read("*l")
                    f:close()
                    if hookCwd and hookCwd ~= "" and cachedCWDs[tty] ~= hookCwd then
                        cachedCWDs[tty] = hookCwd
                        changed = true
                    end
                end
            end
        end

        if changed and hudVisible then
            sessionsDirty = true  -- force card rebuild with new folder names
            updateHud()
        end
    end, { "-c", script }):start()
end

-- Remove TTY-keyed signal files for a given TTY string
local function removeTTYSignals(tty)
    if not tty then return end
    os.remove(SESSION_DIR .. "/" .. tty .. ".active")
    os.remove(SESSION_DIR .. "/" .. tty .. ".waiting")
    os.remove(SESSION_DIR .. "/" .. tty .. ".done")
    os.remove(SESSION_DIR .. "/" .. tty .. ".cwd")
end

-- Clear all session entries
local function clearSessions()
    hideTooltip()
    hideLeftIndicator()
    tabFullLabels = {}
    for i = 1, 9 do
        -- Clean TTY-keyed signals before removing the .tty mapping
        removeTTYSignals(readTTY(i))
        os.remove(SESSION_DIR .. "/" .. tostring(i))
        os.remove(SESSION_DIR .. "/" .. tostring(i) .. ".lock")
        os.remove(SESSION_DIR .. "/" .. tostring(i) .. ".tty")
    end
    -- Glob-clean any leftover TTY-keyed signal files
    local p = io.popen('ls "' .. SESSION_DIR .. '/" 2>/dev/null')
    if p then
        for name in p:lines() do
            if name:match("^ttys%d+%.active$") or name:match("^ttys%d+%.waiting$") or name:match("^ttys%d+%.done$") then
                os.remove(SESSION_DIR .. "/" .. name)
            end
        end
        p:close()
    end
    os.remove(SESSION_DIR .. "/current")
    sessionsDirty = true
    statesDirty = true
end

-- Read consecutive session files from ~/.claude-hud/ (stops at first gap, cleans orphans)
function readSessions()
    local sessions = {}
    local gapFound = false
    for i = 1, 9 do
        if gapFound then
            -- Clean TTY-keyed signals before removing the .tty mapping
            removeTTYSignals(readTTY(i))
            os.remove(SESSION_DIR .. "/" .. tostring(i))
            os.remove(SESSION_DIR .. "/" .. tostring(i) .. ".tty")
        else
            local path = SESSION_DIR .. "/" .. tostring(i)
            local f = io.open(path, "r")
            if f then
                local name = f:read("*l")
                f:close()
                if name and name ~= "" then
                    sessions[i] = name
                else
                    gapFound = true
                    os.remove(path)
                end
            else
                gapFound = true
            end
        end
    end
    return sessions
end

-- Truncate long names
local function truncate(str)
    local clean = str:gsub("^[^%w]+", "")
    if #clean > MAX_NAME_LENGTH then
        return clean:sub(1, MAX_NAME_LENGTH - 1) .. "…"
    end
    return clean
end

-- Session state colors (traffic light)
local COLOR_WORKING = { red = 1.0, green = 0.8, blue = 0.2, alpha = 1 }    -- amber (busy, in progress)
local COLOR_IDLE    = { red = 0.3, green = 0.9, blue = 0.4, alpha = 1 }    -- green (available, come on in)
local COLOR_DONE    = { red = 0.3, green = 0.85, blue = 0.95, alpha = 1 }  -- cyan (finished, check me)
local COLOR_WAITING = { red = 1.0, green = 0.3, blue = 0.3, alpha = 1 }    -- red (needs input)
local HOVER_COLOR   = { red = 1.0, green = 0.6, blue = 0.2, alpha = 1 }    -- orange (mouse hover)

-- Read session states: maps TTY-keyed signal files → tab numbers via .tty mapping
-- Returns { waiting = {}, active = {}, done = {} } keyed by tab number
-- Uses cache; only hits disk when statesDirty is set (pathwatcher fired)
local function readSessionStates()
    if not statesDirty then return cachedStates end
    local waiting = {}
    local active = {}
    local done = {}
    for i = 1, 9 do
        local tty = readTTY(i)
        if tty then
            local fw = io.open(SESSION_DIR .. "/" .. tty .. ".waiting", "r")
            if fw then fw:close(); waiting[i] = true end
            local fa = io.open(SESSION_DIR .. "/" .. tty .. ".active", "r")
            if fa then fa:close(); active[i] = true end
            local fd = io.open(SESSION_DIR .. "/" .. tty .. ".done", "r")
            if fd then
                fd:close()
                -- Auto-clear done if user is looking at this tab
                if i == currentTab then
                    os.remove(SESSION_DIR .. "/" .. tty .. ".done")
                else
                    done[i] = true
                end
            end
        end
    end
    cachedStates = { waiting = waiting, active = active, done = done }
    statesDirty = false
    return cachedStates
end

-- Text size cache: measures once per unique (text, font, fontSize), reuses forever
-- Avoids expensive CoreText boundingRectWithSize calls on every render
local textSizeCache = {}
local function cachedTextSize(text, fontName, fontSize)
    local key = fontName .. ":" .. fontSize .. ":" .. text
    local cached = textSizeCache[key]
    if cached then return cached end
    local styled = hs.styledtext.new(text, {
        font = { name = fontName, size = fontSize },
        color = { red = 1, green = 1, blue = 1, alpha = 1 },
    })
    local size = hs.drawing.getTextDrawingSize(styled)
    textSizeCache[key] = size
    return size
end

-- Get Warp window frame (position + size)
local function getWarpFrame()
    local app = hs.application.find("Warp")
    if not app then return nil end
    local win = app:focusedWindow()
    if not win then return nil end
    return win:frame()
end

-- Apps that should keep the HUD visible
local ALLOWED_APPS = { Warp = true, Hammerspoon = true, Simulator = true }

-- Check if an allowed app is frontmost
function isAllowedAppFocused()
    local app = hs.application.frontmostApplication()
    return app and ALLOWED_APPS[app:name()] or false
end

-- Check if Warp is the frontmost app
function isWarpFocused()
    local app = hs.application.frontmostApplication()
    return app and app:name() == "Warp"
end

-- Check if Warp has a visible window on the currently focused space
-- Prevents HUD from showing on desktops where Warp isn't present
function isWarpOnCurrentSpace()
    local app = hs.application.find("Warp")
    if not app then return false end
    local currentSpace = hs.spaces.focusedSpace()
    if not currentSpace then return false end
    for _, win in ipairs(app:allWindows()) do
        local spaces = hs.spaces.windowSpaces(win)
        if spaces then
            for _, sp in ipairs(spaces) do
                if sp == currentSpace then return true end
            end
        end
    end
    return false
end

-- Read the current Warp window title
local function getWarpTitle()
    local app = hs.application.find("Warp")
    if not app then return nil end
    local win = app:focusedWindow()
    if not win then return nil end
    return win:title()
end

-- Card layout constants
local CARD_PAD_H = 10        -- horizontal padding inside card
local CARD_PAD_V = 3         -- vertical padding inside card
local CARD_GAP = 5           -- gap between cards
local CARD_RADIUS = 4        -- card corner radius
local HUD_PAD = 5            -- padding around all cards inside HUD

-- Card background colors by session state (traffic light)
local CARD_BG_WORKING  = { red = 0.18, green = 0.16, blue = 0.08, alpha = 0.6 }   -- warm dark amber tint
local CARD_BG_IDLE     = { red = 0.06, green = 0.16, blue = 0.08, alpha = 0.55 }   -- dark green tint
local CARD_BG_DONE     = { red = 0.08, green = 0.14, blue = 0.18, alpha = 0.55 }   -- dark cyan tint
local CARD_BG_WAITING  = { red = 0.28, green = 0.08, blue = 0.08, alpha = 0.7 }   -- dark red tint
local CARD_BG_HOVER    = { red = 0.22, green = 0.16, blue = 0.1,  alpha = 0.6 }   -- orange tint
local CARD_BORDER_DIM  = { red = 0.3,  green = 0.3,  blue = 0.35, alpha = 0.25 }

-- Create or update the HUD canvas
function updateHud()
    writeCurrentTab()
    if sessionsDirty then
        cachedSessions = readSessions()
        sessionsDirty = false
    end
    local sessions = cachedSessions or {}

    -- Check if we have any sessions
    local hasAny = false
    for i = 1, 9 do if sessions[i] then hasAny = true; break end end

    if not hasAny then
        if hudCanvas then hudCanvas:hide(); hudVisible = false end
        hideTooltip()
        tabHitZones = {}
        hudScreenFrame = nil
        return
    end

    -- Read session states (waiting/active signal files)
    local states = readSessionStates()

    -- Build card data
    local cards = {}
    for i = 1, 9 do
        if sessions[i] then
            local hasClaude = readTTY(i) ~= nil
            local displayName
            if hasClaude then
                displayName = sessions[i]
                local firstWord = displayName:lower():match("^(%S+)") or ""
                if SHELL_NAMES[firstWord] then displayName = "Tab " .. i end
            else
                displayName = "terminal"
            end
            tabFullLabels[i] = displayName
            local label = truncate(displayName)

            local isSelected = (i == currentTab)
            local isHovered = (i == hoveredTab) and not isSelected
            local isFlashing = flashingTabs[i] and flashState
            local isWorking = states.active[i]
            local isWaiting = states.waiting[i]
            local isDone = doneFlashingTabs[i]
            local isDoneFlashing = isDone and flashState

            -- Session state color: hover > waiting(flash) > working(amber) > done(flash) > idle(green)
            local textColor, borderColor, bgColor
            if isHovered then
                textColor = HOVER_COLOR; borderColor = HOVER_COLOR; bgColor = CARD_BG_HOVER
            elseif isWaiting and isFlashing then
                textColor = COLOR_WAITING; borderColor = COLOR_WAITING; bgColor = CARD_BG_WAITING
            elseif isWaiting then
                -- Red but dim phase of flash cycle
                textColor = { red = 0.6, green = 0.2, blue = 0.2, alpha = 0.7 }
                borderColor = { red = 0.7, green = 0.2, blue = 0.2, alpha = 0.6 }
                bgColor = CARD_BG_WAITING
            elseif isWorking then
                -- Breathing border: sine pulse in amber, capped at ~60% to not rival selected tab
                local pulse = (math.sin(animTick * 0.083) + 1) / 2  -- 0→1→0 smoothly
                local bAlpha = 0.25 + pulse * 0.35  -- 0.25→0.60
                textColor = COLOR_WORKING
                borderColor = { red = 0.6 + pulse * 0.2, green = 0.45 + pulse * 0.2, blue = 0.1, alpha = bAlpha }
                bgColor = CARD_BG_WORKING
            elseif isDone and isDoneFlashing then
                -- Bright cyan flash phase (unseen done)
                textColor = COLOR_DONE; borderColor = COLOR_DONE; bgColor = CARD_BG_DONE
            elseif isDone then
                -- Dim cyan flash phase (unseen done)
                textColor = { red = 0.2, green = 0.5, blue = 0.6, alpha = 0.7 }
                borderColor = { red = 0.2, green = 0.55, blue = 0.65, alpha = 0.6 }
                bgColor = { red = 0.06, green = 0.10, blue = 0.12, alpha = 0.4 }
            else
                -- Idle (green) — no border unless selected
                textColor = COLOR_IDLE
                borderColor = { red = 0, green = 0, blue = 0, alpha = 0 }
                bgColor = CARD_BG_IDLE
            end

            -- Boost selected tab: intensify bg + restore border color
            if isSelected then
                borderColor = textColor
                bgColor = {
                    red = math.min(bgColor.red * 1.6, 1.0),
                    green = math.min(bgColor.green * 1.6, 1.0),
                    blue = math.min(bgColor.blue * 1.6, 1.0),
                    alpha = 0.85,
                }
            end

            local fontName = isSelected and "Menlo-Bold" or "Menlo"
            local labelStyled = hs.styledtext.new(label, {
                font = { name = fontName, size = HUD_FONT_SIZE }, color = textColor,
            })
            local labelSize = cachedTextSize(label, fontName, HUD_FONT_SIZE)

            -- Tab number (separate left column)
            local numStr = tostring(i)
            local numStyled = hs.styledtext.new(numStr, {
                font = { name = fontName, size = HUD_FONT_SIZE }, color = textColor,
            })
            local numSize = cachedTextSize(numStr, fontName, HUD_FONT_SIZE)
            local NUM_GAP = 4  -- gap between number and content area

            -- Folder name (from CWD of the TTY's shell)
            local tty = readTTY(i)
            local cwd = tty and cachedCWDs[tty]
            local folderName = cwd and cwd:match("([^/]+)$") or nil
            local folderSize = folderName and cachedTextSize(folderName, "Menlo", HUD_FOLDER_FONT_SIZE) or nil
            local folderStyled = folderName and hs.styledtext.new(folderName, {
                font = { name = "Menlo", size = HUD_FOLDER_FONT_SIZE }, color = HUD_FOLDER_COLOR,
            }) or nil

            local contentW = math.max(labelSize.w, folderSize and folderSize.w or 0)
            local cardW = numSize.w + NUM_GAP + contentW + 2 * CARD_PAD_H
            local cardH = labelSize.h + 2 * CARD_PAD_V + (folderSize and (folderSize.h + 3) or 0)

            cards[#cards + 1] = {
                num = i, label = labelStyled, labelSize = labelSize,
                numStyled = numStyled, numSize = numSize, numGap = NUM_GAP,
                contentW = contentW,
                folderStyled = folderStyled, folderSize = folderSize,
                cardW = cardW, cardH = cardH,
                borderColor = borderColor, bgColor = bgColor,
                borderWidth = isSelected and 2.5 or isWaiting and 1.5
                    or isWorking and (0.5 + ((math.sin(animTick * 0.083) + 1) / 2) * 0.8) or 0.5,
            }
        end
    end

    -- Build self-monitor stats badge (two lines, stacked vertically)
    local statsFontSize = HUD_FONT_SIZE - 2
    local statsColor = { red = 0.45, green = 0.45, blue = 0.5, alpha = 0.7 }
    local cpuNum = tonumber(selfCpu:match("([%d.]+)"))
    if cpuNum and cpuNum >= 20 then
        statsColor = { red = 1.0, green = 0.3, blue = 0.3, alpha = 0.9 }
    elseif cpuNum and cpuNum >= 10 then
        statsColor = { red = 1.0, green = 0.6, blue = 0.2, alpha = 0.85 }
    end
    local cpuStyled = hs.styledtext.new(selfCpu .. " CPU", {
        font = { name = "Menlo", size = statsFontSize }, color = statsColor,
    })
    local ramStyled = hs.styledtext.new(selfRam .. " RAM", {
        font = { name = "Menlo", size = statsFontSize }, color = { red = 0.4, green = 0.4, blue = 0.45, alpha = 0.6 },
    })
    local cpuSize = cachedTextSize(selfCpu .. " CPU", "Menlo", statsFontSize)
    local ramSize = cachedTextSize(selfRam .. " RAM", "Menlo", statsFontSize)
    local STATS_PAD = 6

    -- Calculate dynamic HUD dimensions
    local maxCardH = 0
    local totalW = HUD_PAD * 2 + CARD_GAP * math.max(#cards - 1, 0)
    for _, c in ipairs(cards) do
        totalW = totalW + c.cardW
        if c.cardH > maxCardH then maxCardH = c.cardH end
    end
    -- Add space for stats badge on the right (no background — just floating text)
    local statsBadgeW = math.max(cpuSize.w, ramSize.w) + STATS_PAD * 2
    local cardsOnlyW = totalW  -- width of tab cards area (before stats)
    totalW = totalW + CARD_GAP + statsBadgeW
    local hudW = totalW
    local hudH = maxCardH + HUD_PAD * 2

    -- Position relative to Warp window (right-aligned)
    local warpFrame = getWarpFrame()
    local hudX, hudY
    if warpFrame then
        hudX = warpFrame.x + warpFrame.w - hudW - HUD_RIGHT_MARGIN
        hudY = warpFrame.y + warpFrame.h - HUD_BOTTOM_OFFSET
        if hudX < warpFrame.x then hudX = warpFrame.x end
    else
        local screen = hs.screen.mainScreen():frame()
        hudX = screen.x + screen.w - hudW - HUD_RIGHT_MARGIN
        hudY = screen.y + screen.h - HUD_BOTTOM_OFFSET
    end

    hudScreenFrame = { x = hudX, y = hudY, w = hudW, h = hudH }

    -- Reuse existing canvas to avoid expensive NSWindow dealloc (60% of CPU was here!)
    -- Only create a new canvas if one doesn't exist yet
    if not hudCanvas then
        hudCanvas = hs.canvas.new({ x = hudX, y = hudY, w = hudW, h = hudH })
        hudCanvas:behavior({ "fullScreenAuxiliary" })
        hudCanvas:level(hs.canvas.windowLevels.floating)
        hudCanvas:canvasMouseEvents(false)
    else
        hudCanvas:frame({ x = hudX, y = hudY, w = hudW, h = hudH })
    end

    -- Build flat element list, then assign by index (overwrite existing, trim extras)
    local elements = {}

    -- HUD outer background (covers tab cards only, not stats badge)
    elements[1] = {
        type = "rectangle", action = "fill",
        frame = { x = 0, y = 0, w = cardsOnlyW, h = hudH },
        roundedRectRadii = { xRadius = HUD_CORNER_RADIUS, yRadius = HUD_CORNER_RADIUS },
        fillColor = { red = 0.06, green = 0.06, blue = 0.08, alpha = HUD_BG_ALPHA },
    }
    elements[2] = {
        type = "rectangle", action = "stroke",
        frame = { x = 0, y = 0, w = cardsOnlyW, h = hudH },
        roundedRectRadii = { xRadius = HUD_CORNER_RADIUS, yRadius = HUD_CORNER_RADIUS },
        strokeColor = { red = 0.25, green = 0.25, blue = 0.3, alpha = 0.3 },
        strokeWidth = 0.5,
    }

    -- Render each card
    local canvasIdx = 3
    local xPos = HUD_PAD
    tabHitZones = {}
    cardElementMap = {}

    for _, card in ipairs(cards) do
        local cardY = HUD_PAD

        -- Card background
        local bgIdx = canvasIdx
        elements[canvasIdx] = {
            type = "rectangle", action = "fill",
            frame = { x = xPos, y = cardY, w = card.cardW, h = maxCardH },
            roundedRectRadii = { xRadius = CARD_RADIUS, yRadius = CARD_RADIUS },
            fillColor = card.bgColor,
        }
        canvasIdx = canvasIdx + 1

        -- Card border
        local borderIdx = canvasIdx
        elements[canvasIdx] = {
            type = "rectangle", action = "stroke",
            frame = { x = xPos, y = cardY, w = card.cardW, h = maxCardH },
            roundedRectRadii = { xRadius = CARD_RADIUS, yRadius = CARD_RADIUS },
            strokeColor = card.borderColor, strokeWidth = card.borderWidth,
        }
        canvasIdx = canvasIdx + 1

        -- Record element indices for lightweight animation updates
        cardElementMap[card.num] = { bgIdx = bgIdx, borderIdx = borderIdx }

        -- Content area starts after number column
        local contentX = xPos + CARD_PAD_H + card.numSize.w + card.numGap

        -- Tab number (left column, vertically centered)
        local numY = cardY + (maxCardH - card.numSize.h) / 2
        elements[canvasIdx] = {
            type = "text", text = card.numStyled,
            frame = { x = xPos + CARD_PAD_H, y = numY, w = card.numSize.w + 2, h = card.numSize.h + 2 },
        }
        canvasIdx = canvasIdx + 1

        -- Folder name (top line, if available)
        local labelYOffset = CARD_PAD_V
        if card.folderStyled then
            local folderX = contentX + (card.contentW - card.folderSize.w) / 2
            local folderY = cardY + CARD_PAD_V
            elements[canvasIdx] = {
                type = "text", text = card.folderStyled,
                frame = { x = folderX, y = folderY, w = card.folderSize.w + 2, h = card.folderSize.h + 2 },
            }
            canvasIdx = canvasIdx + 1
            labelYOffset = CARD_PAD_V + card.folderSize.h + 3
        end

        -- Label text (bottom line, or sole line if no folder)
        local labelX = contentX + (card.contentW - card.labelSize.w) / 2
        local labelY = cardY + labelYOffset
        elements[canvasIdx] = {
            type = "text", text = card.label,
            frame = { x = labelX, y = labelY, w = card.labelSize.w + 2, h = card.labelSize.h + 2 },
        }
        canvasIdx = canvasIdx + 1

        -- Hit zone (screen coordinates)
        tabHitZones[card.num] = { x1 = hudX + xPos, x2 = hudX + xPos + card.cardW }
        xPos = xPos + card.cardW + CARD_GAP
    end

    -- Stats badge (right side of HUD, two lines stacked)
    local statsX = xPos
    local statsY = HUD_PAD
    local totalStatsH = cpuSize.h + ramSize.h + 2
    local statsTopY = statsY + (maxCardH - totalStatsH) / 2

    -- No background rectangle for stats — just floating text (avoids looking like a tab card)
    -- CPU line
    elements[canvasIdx] = {
        type = "text", text = cpuStyled,
        frame = {
            x = statsX + (statsBadgeW - cpuSize.w) / 2,
            y = statsTopY,
            w = cpuSize.w + 2, h = cpuSize.h + 2,
        },
    }
    canvasIdx = canvasIdx + 1
    -- RAM line
    elements[canvasIdx] = {
        type = "text", text = ramStyled,
        frame = {
            x = statsX + (statsBadgeW - ramSize.w) / 2,
            y = statsTopY + cpuSize.h + 2,
            w = ramSize.w + 2, h = ramSize.h + 2,
        },
    }
    canvasIdx = canvasIdx + 1

    -- Apply elements: overwrite existing, remove extras
    local newCount = canvasIdx - 1
    for i = 1, newCount do
        hudCanvas[i] = elements[i]
    end
    -- Remove stale elements from previous render (e.g. tab was closed)
    while hudCanvas:elementCount() > newCount do
        hudCanvas:removeElement(hudCanvas:elementCount())
    end

    if hudEnabled and isWarpOnCurrentSpace() and isAllowedAppFocused() then
        hudCanvas:show()
        hudVisible = true
        -- Always show selected tab's full name tooltip
        if currentTab and not hoveredTab then showTooltip(currentTab) end
        updateLeftIndicator()
    else
        hudCanvas:hide()
        hudVisible = false
        hideTooltip()
        hideLeftIndicator()
    end
end

-- Auto-learn tab names by watching Cmd+digit keystrokes
local function startTabWatcher()
    tabWatcher = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
        if not isWarpFocused() then return false end

        local flags = event:getFlags()
        local keyCode = event:getKeyCode()

        if not flags.cmd or flags.shift or flags.alt or flags.ctrl then
            return false
        end

        local digit = DIGIT_KEYCODES[keyCode]

        if digit then
            local existing = readSessions()
            if existing[digit] then
                -- Registered tab: highlight + refresh title (skip if manually named)
                currentTab = digit
                -- Clear waiting/done state — user is now looking at this tab (TTY-keyed)
                local switchTTY = readTTY(digit)
                if switchTTY then
                    os.remove(SESSION_DIR .. "/" .. switchTTY .. ".waiting")
                    os.remove(SESSION_DIR .. "/" .. switchTTY .. ".done")
                end
                flashingTabs[digit] = nil
                doneFlashingTabs[digit] = nil
                updateHud()
                hs.timer.doAfter(0.2, function()
                    if isLocked(digit) then return end
                    local title = getWarpTitle()
                    if isMeaningfulTitle(title) then
                        local current = readSessions()[digit]
                        if current ~= title then
                            -- Don't overwrite a specific name with a generic one like "Claude Code"
                            if isGenericAppTitle(title) and current
                               and not isGenericAppTitle(current)
                               and not current:match("^Tab %d+$") then
                                return
                            end
                            writeSession(digit, title)
                            updateHud()
                        end
                    end
                end)
            else
                -- Unregistered digit: set currentTab IMMEDIATELY so the "current"
                -- file is accurate when UserPromptSubmit fires (TTY registration)
                currentTab = digit
                writeCurrentTab()
                local titleBefore = getWarpTitle()
                hs.timer.doAfter(0.2, function()
                    local titleAfter = getWarpTitle()
                    if titleAfter and titleAfter ~= titleBefore then
                        -- Warp responded — real tab exists. Fill consecutive gaps.
                        local sessions = readSessions()
                        for g = 1, digit do
                            if not sessions[g] then
                                writeSession(g, "Tab " .. g)
                            end
                        end
                        if isMeaningfulTitle(titleAfter) then
                            writeSession(digit, titleAfter)
                        else
                            writeSession(digit, "Tab " .. digit)
                        end
                        currentTab = digit
                        updateHud()
                    else
                        -- Title unchanged — no such tab, revert currentTab
                        currentTab = nil
                        writeCurrentTab()
                    end
                end)
            end
        elseif keyCode == KEYCODE_T then
            -- New tab: Warp inserts AFTER the current tab, not at the end.
            -- We must shift higher tabs up by one to keep TTY mappings correct.
            local sessions = readSessions()
            local maxNum = 0
            for i = 1, 9 do if sessions[i] then maxNum = i end end
            -- Insert after currentTab when mid-list, otherwise append
            local insertAt = (currentTab and currentTab < maxNum) and (currentTab + 1) or (maxNum + 1)
            if insertAt <= 9 then
                -- Shift tabs from maxNum down to insertAt up by one (mirror of Cmd+W shift-down)
                if insertAt <= maxNum and maxNum < 9 then
                    for i = maxNum, insertAt, -1 do
                        -- Shift session name
                        local name = sessions[i]
                        if name then writeSession(i + 1, name) end
                        -- Shift TTY mapping
                        local tty = readTTY(i)
                        if tty then
                            local tf = io.open(SESSION_DIR .. "/" .. (i + 1) .. ".tty", "w")
                            if tf then tf:write(tty); tf:close() end
                        else
                            os.remove(SESSION_DIR .. "/" .. (i + 1) .. ".tty")
                        end
                        -- Shift lock
                        setLock(i + 1, isLocked(i))
                    end
                end

                -- Register new tab at insertAt (no TTY yet — hook will set it)
                writeSession(insertAt, "Tab " .. insertAt)
                setLock(insertAt, false)
                os.remove(SESSION_DIR .. "/" .. insertAt .. ".tty")
                currentTab = insertAt
                statesDirty = true  -- TTY→tab mapping changed
                updateHud()  -- writes currentTab to "current" file

                -- Poll to update title if Warp provides a meaningful one
                local titleBefore = getWarpTitle()
                local attempts = 0
                local poller
                poller = hs.timer.doEvery(0.1, function()
                    attempts = attempts + 1
                    local title = getWarpTitle()
                    local changed = title and title ~= "" and title ~= titleBefore
                    local meaningful = isMeaningfulTitle(title)
                    if (changed and meaningful) or attempts >= 30 then
                        poller:stop()
                        if meaningful and title then
                            writeSession(insertAt, title)
                            updateHud()
                        end
                    end
                end)
            end
        elseif keyCode == KEYCODE_W then
            local closedTab = currentTab
            hs.timer.doAfter(0.08, function()
                if closedTab then
                    -- Clean TTY-keyed signals for the closed tab's process
                    removeTTYSignals(readTTY(closedTab))
                    -- Shift higher tabs down by one
                    -- Only shift: session name, .tty, .lock
                    -- Signal files (.active/.waiting/.done) are TTY-keyed — they follow the process automatically
                    for i = closedTab, 8 do
                        local nextPath = SESSION_DIR .. "/" .. (i + 1)
                        local f = io.open(nextPath, "r")
                        if f then
                            local name = f:read("*l")
                            f:close()
                            writeSession(i, name)
                            setLock(i, isLocked(i + 1))
                            -- Shift TTY mapping
                            local nextTTY = readTTY(i + 1)
                            if nextTTY then
                                local tf = io.open(SESSION_DIR .. "/" .. i .. ".tty", "w")
                                if tf then tf:write(nextTTY); tf:close() end
                            else
                                os.remove(SESSION_DIR .. "/" .. i .. ".tty")
                            end
                        else
                            os.remove(SESSION_DIR .. "/" .. i)
                            setLock(i, false)
                            os.remove(SESSION_DIR .. "/" .. i .. ".tty")
                        end
                    end
                    os.remove(SESSION_DIR .. "/9")
                    setLock(9, false)
                    os.remove(SESSION_DIR .. "/9.tty")
                    -- Update current tab (Warp focuses same position or one before)
                    local sessions = readSessions()
                    if not sessions[closedTab] and closedTab > 1 then
                        currentTab = closedTab - 1
                    end
                end
                statesDirty = true  -- TTY→tab mapping changed
                updateHud()
            end)
        end

        return false
    end)
    tabWatcher:start()
end

-- Show/hide HUD based on which app is focused
-- CRITICAL: Start/stop mouse eventtaps to avoid burning CPU when Warp is not focused
local function onAppEvent(appName, eventType, appObject)
    if not hudEnabled then return end

    if eventType == hs.application.watcher.launched then
        if appName == "Warp" then
            clearSessions()
            sessionsDirty = true
            currentTab = nil
        end
    elseif eventType == hs.application.watcher.activated then
        if ALLOWED_APPS[appName] then
            -- Resume mouse tracking only when Warp is visible
            if hoverWatcher and not hoverWatcher:running() then hoverWatcher:start() end
            if clickWatcher and not clickWatcher:isEnabled() then clickWatcher:start() end
            sessionsDirty = true  -- re-read in case files changed while away
            updateHud()
        else
            -- STOP mouse eventtaps — this is the #1 CPU saver
            if hoverWatcher and hoverWatcher:running() then hoverWatcher:stop() end
            if clickWatcher and clickWatcher:isEnabled() then clickWatcher:stop() end
            if hudCanvas then
                hudCanvas:hide()
                hudVisible = false
            end
            hideTooltip()
            hideLeftIndicator()
            hoveredTab = nil
        end
    end
end

-- Compute border/bg/width for a tab given its state (shared by animation + hover paths)
local function computeCardVisuals(tabNum)
    local states = cachedStates
    local isWaiting = states.waiting[tabNum]
    local isWorking = states.active[tabNum]
    local isDone = doneFlashingTabs[tabNum]
    local isHover = (tabNum == hoveredTab)

    local borderColor, bgColor, borderWidth
    if isHover then
        borderColor = HOVER_COLOR; bgColor = CARD_BG_HOVER; borderWidth = 1.0
    elseif isWaiting and flashState then
        borderColor = COLOR_WAITING; bgColor = CARD_BG_WAITING; borderWidth = 1.5
    elseif isWaiting then
        borderColor = { red = 0.7, green = 0.2, blue = 0.2, alpha = 0.6 }
        bgColor = CARD_BG_WAITING; borderWidth = 1.5
    elseif isWorking then
        local pulse = (math.sin(animTick * 0.083) + 1) / 2
        local bAlpha = 0.25 + pulse * 0.35
        borderColor = { red = 0.1 + pulse * 0.1, green = 0.35 + pulse * 0.25, blue = 0.15 + pulse * 0.1, alpha = bAlpha }
        bgColor = CARD_BG_WORKING; borderWidth = 0.5 + pulse * 0.8
    elseif isDone and flashState then
        borderColor = COLOR_IDLE; bgColor = CARD_BG_IDLE; borderWidth = 0.5
    elseif isDone then
        borderColor = { red = 0.7, green = 0.55, blue = 0.15, alpha = 0.6 }
        bgColor = { red = 0.12, green = 0.10, blue = 0.05, alpha = 0.4 }; borderWidth = 0.5
    else
        borderColor = { red = 0, green = 0, blue = 0, alpha = 0 }
        bgColor = CARD_BG_IDLE; borderWidth = 0.5
    end

    if tabNum == currentTab then
        if not isHover then borderColor = isWorking and borderColor or COLOR_IDLE end
        bgColor = {
            red = math.min(bgColor.red * 1.6, 1.0),
            green = math.min(bgColor.green * 1.6, 1.0),
            blue = math.min(bgColor.blue * 1.6, 1.0),
            alpha = 0.85,
        }
        borderWidth = 2.5
    end

    return borderColor, bgColor, borderWidth
end

-- Patch a single card's border/bg on the canvas (no text rebuild)
local function patchCard(tabNum)
    if not hudCanvas or not hudVisible then return end
    local map = cardElementMap[tabNum]
    if not map then return end
    local borderColor, bgColor, borderWidth = computeCardVisuals(tabNum)
    hudCanvas[map.bgIdx].fillColor = bgColor
    hudCanvas[map.borderIdx].strokeColor = borderColor
    hudCanvas[map.borderIdx].strokeWidth = borderWidth
end

-- Lightweight animation update: only touch animated cards' border/bg on existing canvas
local function animUpdateOnly()
    if not hudCanvas or not hudVisible then return end
    for tabNum, _ in pairs(cardElementMap) do
        local states = cachedStates
        local isWaiting = states.waiting[tabNum]
        local isWorking = states.active[tabNum]
        local isDone = doneFlashingTabs[tabNum]
        -- Only touch cards that actually animate; skip hovered/selected tabs
        if (isWaiting or isWorking or isDone) and tabNum ~= hoveredTab and tabNum ~= currentTab then
            patchCard(tabNum)
        end
    end
end

-- Manage the single animation timer: start when animations needed, stop when not
-- Runs at 500ms (2fps); only updates animated cards' border/bg colors
local function updateAnimTimer()
    local states = readSessionStates()
    local oldFlashing = flashingTabs
    local oldDone = doneFlashingTabs
    flashingTabs = states.waiting
    doneFlashingTabs = states.done

    -- Patch cards that left animated state → restore to idle visuals
    for tabNum, _ in pairs(oldFlashing) do
        if not flashingTabs[tabNum] then patchCard(tabNum) end
    end
    for tabNum, _ in pairs(oldDone) do
        if not doneFlashingTabs[tabNum] then patchCard(tabNum) end
    end

    local needsAnim = next(flashingTabs) or next(doneFlashingTabs) or next(states.active)

    if needsAnim then
        if not animTimer then
            animTimer = hs.timer.doEvery(0.033, function()
                animTick = animTick + 1
                flashState = (animTick % 15) < 8  -- ~0.5s cycle: bright for 8 frames, dim for 7
                animUpdateOnly()
            end)
        end
    else
        if animTimer then
            animTimer:stop()
            animTimer = nil
            flashState = true
            animTick = 0
        end
    end
end

-- Watch session directory for changes (debounced)
-- Distinguishes state-only changes (.active/.waiting/.done) from structural changes (session files)
local function onSessionFileChange(paths)
    statesDirty = true  -- always invalidate state cache

    -- Check if any structural file changed (not just state files)
    local structuralChange = false
    if paths then
        for _, p in ipairs(paths) do
            local base = p:match("([^/]+)$") or ""
            if not base:match("%.active$") and not base:match("%.waiting$")
               and not base:match("%.done$") and not base:match("%.tty$")
               and base ~= "current" then
                structuralChange = true
                break
            end
        end
    else
        structuralChange = true
    end

    if structuralChange then
        sessionsDirty = true
    end

    if debounceTimer then debounceTimer:stop() end
    debounceTimer = hs.timer.doAfter(0.5, function()
        updateAnimTimer()
        refreshCWDs()  -- CWD may have changed (user cd'd)
        if structuralChange then
            updateHud()
            -- Auto-sync TTYs for newly created tabs that may be unmapped
            autoSyncTTYs()
        end
    end)
end

-- Toggle HUD visibility
local function toggleHud()
    hudEnabled = not hudEnabled
    if hudEnabled then
        updateHud()
        hs.alert.show("HUD enabled")
    else
        if hudCanvas then
            hudCanvas:hide()
            hudVisible = false
        end
        hideTooltip()
        hideLeftIndicator()
        hs.alert.show("HUD disabled")
    end
end

-- Tooltip: show full tab name below HUD on hover
showTooltip = function(digit)
    local fullLabel = tabFullLabels[digit]
    if not fullLabel or not hudScreenFrame or not tabHitZones[digit] then return end

    -- Hide existing tooltip
    if tooltipCanvas then tooltipCanvas:delete(); tooltipCanvas = nil end

    local tipFontName = "Menlo"
    local tipFontSize = 11
    local tipSize = cachedTextSize(fullLabel, tipFontName, tipFontSize)
    local padH, padV = 8, 4
    local tipW = tipSize.w + 2 * padH
    local tipH = tipSize.h + 2 * padV

    -- Center on the hovered card's hit zone, just below HUD
    local zone = tabHitZones[digit]
    local tabCenter = (zone.x1 + zone.x2) / 2
    local tipX = tabCenter - tipW / 2
    local tipY = hudScreenFrame.y + hudScreenFrame.h + 2

    tooltipCanvas = hs.canvas.new({ x = tipX, y = tipY, w = tipW, h = tipH })
    tooltipCanvas:level(hs.canvas.windowLevels.popUpMenu)
    tooltipCanvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    tooltipCanvas[1] = {
        type = "rectangle",
        frame = { x = 0, y = 0, w = tipW, h = tipH },
        roundedRectRadii = { xRadius = 4, yRadius = 4 },
        fillColor = { red = 0.1, green = 0.1, blue = 0.12, alpha = 0.92 },
        strokeColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 0.6 },
        strokeWidth = 0.5,
        action = "strokeAndFill",
    }
    tooltipCanvas[2] = {
        type = "text",
        text = hs.styledtext.new(fullLabel, {
            font = { name = tipFontName, size = tipFontSize },
            color = { red = 0.95, green = 0.95, blue = 0.95, alpha = 1.0 },
        }),
        frame = { x = padH, y = padV, w = tipSize.w + 2, h = tipSize.h + 2 },
    }
    tooltipCanvas:show()
end

hideTooltip = function()
    if tooltipCanvas then tooltipCanvas:delete(); tooltipCanvas = nil end
end

-- Left-side indicator: shows selected tab's folder + name near the typing area
hideLeftIndicator = function()
    if leftIndicatorCanvas then leftIndicatorCanvas:delete(); leftIndicatorCanvas = nil end
end

updateLeftIndicator = function()
    if not currentTab or not hudVisible then
        hideLeftIndicator()
        return
    end

    local fullLabel = tabFullLabels[currentTab]
    if not fullLabel then hideLeftIndicator(); return end

    -- Get folder name for the selected tab
    local tty = readTTY(currentTab)
    local cwd = tty and cachedCWDs[tty]
    local folderName = cwd and cwd:match("([^/]+)$") or nil

    -- Build display text: "folder  name" or just "name"
    local tipFontSize = 11
    local folderFontSize = 10
    local padH, padV = 8, 4

    -- Measure text sizes
    local labelSize = cachedTextSize(fullLabel, "Menlo-Bold", tipFontSize)
    local folderSize = folderName and cachedTextSize(folderName, "Menlo", folderFontSize) or nil

    -- Calculate canvas dimensions
    local innerW, innerH
    if folderSize then
        local gap = 6  -- gap between folder and label
        innerW = folderSize.w + gap + labelSize.w
        innerH = math.max(labelSize.h, folderSize.h)
    else
        innerW = labelSize.w
        innerH = labelSize.h
    end
    local tipW = innerW + 2 * padH
    local tipH = innerH + 2 * padV

    -- Position: left side of Warp window, same vertical line as HUD
    local warpFrame = getWarpFrame()
    if not warpFrame then hideLeftIndicator(); return end
    local tipX = warpFrame.x + LEFT_INDICATOR_LEFT_MARGIN
    local tipY = warpFrame.y + warpFrame.h - LEFT_INDICATOR_BOTTOM_OFFSET

    -- Get state color for the selected tab's label
    local states = cachedStates
    local labelColor
    if states.waiting[currentTab] then
        labelColor = COLOR_WAITING
    elseif states.active[currentTab] then
        labelColor = COLOR_WORKING
    elseif doneFlashingTabs[currentTab] then
        labelColor = COLOR_DONE
    else
        labelColor = COLOR_IDLE
    end

    -- Recreate canvas (lightweight — only 3-4 elements)
    if leftIndicatorCanvas then leftIndicatorCanvas:delete() end
    leftIndicatorCanvas = hs.canvas.new({ x = tipX, y = tipY, w = tipW, h = tipH })
    leftIndicatorCanvas:level(hs.canvas.windowLevels.floating)
    leftIndicatorCanvas:behavior({ "fullScreenAuxiliary" })
    leftIndicatorCanvas:canvasMouseEvents(false)

    -- Background
    leftIndicatorCanvas[1] = {
        type = "rectangle", action = "strokeAndFill",
        frame = { x = 0, y = 0, w = tipW, h = tipH },
        roundedRectRadii = { xRadius = 4, yRadius = 4 },
        fillColor = { red = 0.06, green = 0.06, blue = 0.08, alpha = 0.88 },
        strokeColor = { red = 0.25, green = 0.25, blue = 0.3, alpha = 0.4 },
        strokeWidth = 0.5,
    }

    local elemIdx = 2
    local textX = padH

    -- Folder name (gray, regular weight)
    if folderName and folderSize then
        local folderY = padV + (innerH - folderSize.h) / 2
        leftIndicatorCanvas[elemIdx] = {
            type = "text",
            text = hs.styledtext.new(folderName, {
                font = { name = "Menlo", size = folderFontSize },
                color = HUD_FOLDER_COLOR,
            }),
            frame = { x = textX, y = folderY, w = folderSize.w + 2, h = folderSize.h + 2 },
        }
        elemIdx = elemIdx + 1
        textX = textX + folderSize.w + 6
    end

    -- Session name (state-colored, bold)
    local labelY = padV + (innerH - labelSize.h) / 2
    leftIndicatorCanvas[elemIdx] = {
        type = "text",
        text = hs.styledtext.new(fullLabel, {
            font = { name = "Menlo-Bold", size = tipFontSize },
            color = labelColor,
        }),
        frame = { x = textX, y = labelY, w = labelSize.w + 2, h = labelSize.h + 2 },
    }

    leftIndicatorCanvas:show()
end

-- Hover detection: poll mouse position 10x/sec instead of global mouseMoved eventtap
-- A mouseMoved eventtap fires hundreds of times/sec and burns CPU even with bounds checks.
-- Polling at 100ms is imperceptible for hover effects and uses ~0.1% CPU instead of 25%+.
-- NOTE: Started/stopped by onAppEvent — only runs when Warp is focused.
local function startHoverWatcher()
    hoverWatcher = hs.timer.new(0.25, function()
        if not hudVisible or not hudScreenFrame then
            if hoveredTab then hoveredTab = nil; hideTooltip() end
            return
        end

        local pos = hs.mouse.absolutePosition()

        -- Quick bounds check: is cursor within HUD rectangle?
        if pos.x < hudScreenFrame.x or pos.x > hudScreenFrame.x + hudScreenFrame.w
           or pos.y < hudScreenFrame.y or pos.y > hudScreenFrame.y + hudScreenFrame.h then
            if hoveredTab then
                local oldHover = hoveredTab
                hoveredTab = nil
                if currentTab then showTooltip(currentTab) else hideTooltip() end
                patchCard(oldHover)  -- restore old tab's state colors
            end
            return
        end

        -- Check which tab the cursor is over
        local newHover = nil
        for digit, zone in pairs(tabHitZones) do
            if pos.x >= zone.x1 and pos.x <= zone.x2 then
                newHover = digit
                break
            end
        end

        if newHover ~= hoveredTab then
            local oldHover = hoveredTab
            hoveredTab = newHover
            if oldHover then patchCard(oldHover) end   -- restore old
            if newHover then
                patchCard(newHover)    -- apply hover
                showTooltip(newHover)  -- show full name tooltip
            else
                if currentTab then showTooltip(currentTab) else hideTooltip() end
            end
        end
    end)
    -- Don't start immediately — onAppEvent will start it when Warp is focused
end

-- Inline rename webview (positioned above HUD)
local renameWebview = nil

local function showRenameInput(digit, currentName)
    -- Position above the HUD, centered on the tab's hit zone
    local inputW = 220
    local inputH = 38
    local inputX, inputY

    if hudScreenFrame and tabHitZones[digit] then
        local zone = tabHitZones[digit]
        local tabCenter = (zone.x1 + zone.x2) / 2
        inputX = tabCenter - inputW / 2
        inputY = hudScreenFrame.y - inputH - 6
    else
        -- Fallback: center of screen
        local screen = hs.screen.mainScreen():frame()
        inputX = screen.x + (screen.w - inputW) / 2
        inputY = screen.y + (screen.h - inputH) / 2
    end

    -- Clean up any existing rename webview
    if renameWebview then
        renameWebview:delete()
        renameWebview = nil
    end

    local escaped = currentName:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub('"', '\\"')

    local html = [[
    <html><head><style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        background: rgba(20, 20, 24, 0.95);
        display: flex; align-items: center; justify-content: center;
        height: 100vh; padding: 4px;
    }
    input {
        width: 100%; height: 30px;
        background: #1a1a20; color: #e8c840;
        border: 1px solid #e8c840; border-radius: 4px;
        font: 13px/30px Menlo; padding: 0 8px;
        outline: none; text-align: center;
    }
    input::selection { background: #e8c84040; }
    </style></head><body>
    <input id="inp" type="text" value="]] .. escaped .. [[" placeholder="empty = auto-name"
        spellcheck="false" autocomplete="off" />
    <script>
    var inp = document.getElementById('inp');
    inp.focus(); inp.select();
    inp.addEventListener('keydown', function(e) {
        if (e.key === 'Enter') {
            window.webkit.messageHandlers.hammerspoon.postMessage('OK:' + inp.value);
        } else if (e.key === 'Escape') {
            window.webkit.messageHandlers.hammerspoon.postMessage('CANCEL');
        }
    });
    </script></body></html>
    ]]

    -- Create a usercontent controller to receive JS postMessage calls
    local uc = hs.webview.usercontent.new("hammerspoon")
    uc:setCallback(function(msg)
        local body = msg.body or ""

        if body:sub(1, 3) == "OK:" then
            local newName = body:sub(4)
            if newName and newName ~= "" then
                writeSession(digit, newName)
                setLock(digit, true)
            else
                setLock(digit, false)
                local title = getWarpTitle()
                if isMeaningfulTitle(title) then
                    writeSession(digit, title)
                else
                    writeSession(digit, "Tab " .. digit)
                end
            end
            updateHud()
        end

        if renameWebview then
            renameWebview:delete()
            renameWebview = nil
        end
        local warp = hs.application.find("Warp")
        if warp then warp:activate() end
    end)

    renameWebview = hs.webview.new(
        { x = inputX, y = inputY, w = inputW, h = inputH },
        { developerExtrasEnabled = false },
        uc
    )
    renameWebview:windowStyle({"borderless", "utility", "nonactivating"})
    renameWebview:level(hs.canvas.windowLevels.floating + 1)
    renameWebview:behaviorAsLabels({"fullScreenAuxiliary"})
    renameWebview:allowTextEntry(true)
    renameWebview:transparent(true)
    renameWebview:html(html)
    renameWebview:show()
    local win = renameWebview:hswindow()
    if win then win:focus() end
end

-- Click-to-switch + double-click-to-rename
-- NOTE: This eventtap is started/stopped by onAppEvent — only runs when Warp is focused
local pendingClickTimer = nil
local pendingClickDigit = nil

local function startClickWatcher()
    clickWatcher = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function(event)
        if not hudVisible or not hudScreenFrame then
            return false
        end

        local pos = event:location()

        -- Bounds check
        if pos.x < hudScreenFrame.x or pos.x > hudScreenFrame.x + hudScreenFrame.w
           or pos.y < hudScreenFrame.y or pos.y > hudScreenFrame.y + hudScreenFrame.h then
            return false
        end

        -- Find which tab was hit
        local hitDigit = nil
        for digit, zone in pairs(tabHitZones) do
            if pos.x >= zone.x1 and pos.x <= zone.x2 then
                hitDigit = digit
                break
            end
        end

        if not hitDigit then return false end

        local clickState = event:getProperty(hs.eventtap.event.properties.mouseEventClickState)

        if clickState == 2 and pendingClickDigit == hitDigit then
            -- Double-click: cancel pending single-click, show rename dialog
            if pendingClickTimer then
                pendingClickTimer:stop()
                pendingClickTimer = nil
            end
            pendingClickDigit = nil

            local sessions = readSessions()
            local currentName = sessions[hitDigit] or ("Tab " .. hitDigit)
            -- Clean display name same as truncate does
            currentName = currentName:gsub("^[^%w]+", "")

            hs.timer.doAfter(0.01, function()
                showRenameInput(hitDigit, currentName)
            end)
            return true
        else
            -- First click: delay to distinguish from double-click
            pendingClickDigit = hitDigit
            if pendingClickTimer then pendingClickTimer:stop() end
            pendingClickTimer = hs.timer.doAfter(0.25, function()
                -- Single click: switch tab
                if pendingClickDigit then
                    hs.eventtap.keyStroke({"cmd"}, tostring(pendingClickDigit), 0)
                end
                pendingClickDigit = nil
                pendingClickTimer = nil
            end)
            return true
        end
    end)
    -- Don't start immediately — onAppEvent will start it when Warp is focused
end

-- TTY auto-sync: comprehensive TTY↔tab mapping repair
-- Detects and fixes: stale mappings (dead TTYs), duplicates, orphan .tty files,
-- and unmapped sessions. Runs async via hs.task.
local ttyAutoSyncTimer = nil
autoSyncTTYs = function()
    local sessions = cachedSessions or readSessions()

    -- Collect current TTY mappings for active tabs
    local tabToTTY = {}  -- tab# → tty string
    for i = 1, 9 do
        if sessions[i] then
            local f = io.open(SESSION_DIR .. "/" .. i .. ".tty", "r")
            if f then
                local tty = f:read("*l")
                f:close()
                if tty and tty ~= "" then tabToTTY[i] = tty end
            end
        end
    end

    -- Also clean orphan .tty files (tab has no session file)
    for i = 1, 9 do
        if not sessions[i] then
            os.remove(SESSION_DIR .. "/" .. i .. ".tty")
        end
    end

    -- Async: find all live Claude TTYs
    hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
        if exitCode ~= 0 or not stdout then return end
        local liveTTYs = {}
        for tty in stdout:gmatch("(%S+)") do
            liveTTYs[tty] = true
        end

        local changed = false

        -- Step 1: Remove stale mappings (tab → dead TTY with no Claude process)
        for tab, tty in pairs(tabToTTY) do
            if not liveTTYs[tty] then
                os.remove(SESSION_DIR .. "/" .. tab .. ".tty")
                -- Also clear stale TTY-keyed signal files
                removeTTYSignals(tty)
                tabToTTY[tab] = nil
                changed = true
            end
        end

        -- Step 2: Remove duplicate mappings (same TTY in multiple tabs — keep lowest)
        local seen = {}  -- tty → lowest tab#
        for i = 1, 9 do
            if tabToTTY[i] then
                if seen[tabToTTY[i]] then
                    os.remove(SESSION_DIR .. "/" .. i .. ".tty")
                    tabToTTY[i] = nil
                    changed = true
                else
                    seen[tabToTTY[i]] = i
                end
            end
        end

        -- Step 3: Find unmapped tabs and unmapped live Claude TTYs
        local ttyToTab = {}
        for tab, tty in pairs(tabToTTY) do ttyToTab[tty] = tab end

        local unmappedTabs = {}
        for i = 1, 9 do
            if sessions[i] and not tabToTTY[i] then
                unmappedTabs[#unmappedTabs + 1] = i
            end
        end

        local unmappedTTYs = {}
        for tty, _ in pairs(liveTTYs) do
            if not ttyToTab[tty] then
                unmappedTTYs[#unmappedTTYs + 1] = tty
            end
        end

        -- Step 4: Auto-assign unmapped TTYs to unmapped tabs
        -- Sort both lists so lowest TTY maps to lowest tab (TTYs are sequential)
        if #unmappedTTYs > 0 and #unmappedTabs > 0 then
            table.sort(unmappedTTYs)
            table.sort(unmappedTabs)
            local count = math.min(#unmappedTTYs, #unmappedTabs)
            for idx = 1, count do
                local f = io.open(SESSION_DIR .. "/" .. unmappedTabs[idx] .. ".tty", "w")
                if f then f:write(unmappedTTYs[idx]); f:close() end
            end
            changed = true
        end

        if changed then
            statesDirty = true
            sessionsDirty = true
            updateAnimTimer()
            updateHud()
        end
    end, {"-c", "ps -eo tty=,comm= 2>/dev/null | awk '$2 == \"claude\" {print $1}' | sort -u"}):start()
end

-- Sample Hammerspoon's own CPU% and RAM (async — no fork overhead)
local function sampleSelfStats()
    local pid = tostring(hs.processInfo.processID)
    hs.task.new("/bin/ps", function(exitCode, stdout, stderr)
        if exitCode ~= 0 or not stdout then return end
        local cpu, rss = stdout:match("([%d.]+)%s+(%d+)")
        if cpu and rss then
            selfCpu = string.format("%%%.0f", tonumber(cpu))
            local mb = tonumber(rss) / 1024
            selfRam = mb >= 1024
                and string.format("%.1fG", mb / 1024)
                or string.format("%.0fM", mb)
            -- Redraw HUD so stats badge updates visually
            if hudVisible then updateHud() end
        end
    end, { "-o", "pcpu=,rss=", "-p", pid }):start()
end

-- Initialize
local function init()
    math.randomseed(os.time())
    os.execute("mkdir -p " .. SESSION_DIR)

    -- One-time cleanup: remove legacy N-keyed signal files (now TTY-keyed)
    for i = 1, 9 do
        os.remove(SESSION_DIR .. "/" .. i .. ".active")
        os.remove(SESSION_DIR .. "/" .. i .. ".waiting")
        os.remove(SESSION_DIR .. "/" .. i .. ".done")
    end

    appWatcher = hs.application.watcher.new(onAppEvent)
    appWatcher:start()

    -- Hide/show HUD when switching spaces (desktops)
    spaceWatcher = hs.spaces.watcher.new(function()
        if not hudEnabled then return end
        -- Hide IMMEDIATELY to prevent HUD lingering on wrong desktop
        if hudCanvas then hudCanvas:hide(); hudVisible = false end
        hideTooltip()
        hideLeftIndicator()
        hoveredTab = nil
        if hoverWatcher and hoverWatcher:running() then hoverWatcher:stop() end
        if clickWatcher and clickWatcher:isEnabled() then clickWatcher:stop() end
        -- After space transition settles, re-evaluate
        hs.timer.doAfter(0.3, function()
            if not hudEnabled then return end
            if isWarpOnCurrentSpace() and isAllowedAppFocused() then
                if hoverWatcher and not hoverWatcher:running() then hoverWatcher:start() end
                if clickWatcher and not clickWatcher:isEnabled() then clickWatcher:start() end
                sessionsDirty = true
                updateHud()
            end
        end)
    end)
    spaceWatcher:start()

    sessionWatcher = hs.pathwatcher.new(SESSION_DIR, onSessionFileChange)
    sessionWatcher:start()

    startTabWatcher()
    startClickWatcher()
    startHoverWatcher()

    -- Only start mouse eventtaps if an allowed app is already focused
    if isAllowedAppFocused() then
        if hoverWatcher then hoverWatcher:start() end
        if clickWatcher then clickWatcher:start() end
    end

    hs.hotkey.bind({ "cmd", "ctrl" }, "h", toggleHud)

    -- Self-monitoring: sample CPU/RAM every 30 seconds (async hs.task, not io.popen)
    sampleSelfStats()  -- initial reading
    selfStatsTimer = hs.timer.doEvery(30, sampleSelfStats)

    -- TTY auto-sync: catch missed registrations every 5 seconds
    autoSyncTTYs()  -- initial sync
    ttyAutoSyncTimer = hs.timer.doEvery(5, autoSyncTTYs)

    -- CWD refresh: update folder names every 5 seconds
    refreshCWDs()  -- initial reading
    cwdRefreshTimer = hs.timer.doEvery(5, refreshCWDs)

    hs.timer.doAfter(1, function()
        updateHud()
        if hudCanvas and not hudCanvas:isShowing() and next(readSessions()) then
            hudCanvas:show()
            hudVisible = true
        end
        -- Re-check focus after init settles (reload may briefly focus Hammerspoon)
        if isAllowedAppFocused() or isWarpOnCurrentSpace() then
            if hoverWatcher and not hoverWatcher:running() then hoverWatcher:start() end
            if clickWatcher and not clickWatcher:isEnabled() then clickWatcher:start() end
        end
    end)
end

hs.hotkey.bind({ "cmd", "ctrl" }, "w", function()
    clearSessions()
    currentTab = nil
    cachedCWDs = {}
    flashingTabs = {}
    doneFlashingTabs = {}
    if animTimer then animTimer:stop(); animTimer = nil end
    flashState = true
    animTick = 0
    sessionsDirty = true
    statesDirty = true
    updateHud()
    hs.alert.show("HUD sessions cleared")
end)

hs.hotkey.bind({ "cmd", "ctrl" }, "r", function()
    hs.reload()
end)

hs.alert.show("Hammerspoon loaded")
init()
