-- module_quote.lua — Simple UI
-- Quote of the Day module. Three source modes:
--   "quotes"     — random quote from quotes.lua (default)
--   "highlights" — random highlight from the user's books
--   "mixed"      — random pick between both sources

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local Screen         = Device.screen
local _              = require("gettext")
local logger         = require("logger")

local UI           = require("ui")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _CLR_TEXT_QUOTE = Blitbuffer.COLOR_BLACK

local QUOTE_FS      = Screen:scaleBySize(11)
local QUOTE_ATTR_FS = Screen:scaleBySize(9)
local QUOTE_GAP     = Screen:scaleBySize(4)
local QUOTE_ATTR_H  = Screen:scaleBySize(11)
local QUOTE_H       = PAD + QUOTE_FS * 4 + QUOTE_GAP + QUOTE_ATTR_H + PAD2

local _FACE_QUOTE = Font:getFace("cfont", QUOTE_FS)
local _FACE_ATTR  = Font:getFace("cfont", QUOTE_ATTR_FS)
local _VSPAN_GAP  = VerticalSpan:new{ width = QUOTE_GAP }

local SETTING_SOURCE = "quote_source"

local function getSource(pfx)
    return G_reader_settings:readSetting((pfx or "") .. SETTING_SOURCE) or "quotes"
end

-- ---------------------------------------------------------------------------
-- Default quotes engine
-- ---------------------------------------------------------------------------

local _qpath          = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
local _quotes_cache   = nil
local _last_quote_idx = nil

local function loadQuotes()
    if _quotes_cache then return _quotes_cache end
    local ok, data = pcall(dofile, _qpath .. "quotes.lua")
    if ok and type(data) == "table" and #data > 0 then
        _quotes_cache = data
    else
        _quotes_cache = {
            { q = "A reader lives a thousand lives before he dies.",                   a = "George R.R. Martin" },
            { q = "So many books, so little time.",                                    a = "Frank Zappa" },
            { q = "I have always imagined that Paradise will be a kind of library.",   a = "Jorge Luis Borges" },
            { q = "Sleep is good, he said, and books are better.",                     a = "George R.R. Martin", b = "A Clash of Kings" },
        }
    end
    return _quotes_cache
end

local function pickQuote()
    local quotes = loadQuotes()
    local n = #quotes
    if n == 0 then return nil end
    if n == 1 then _last_quote_idx = 1; return quotes[1] end
    local idx = math.random(1, n - 1)
    if _last_quote_idx and idx >= _last_quote_idx then idx = idx + 1 end
    _last_quote_idx = idx
    return quotes[idx]
end

-- ---------------------------------------------------------------------------
-- Highlights engine
--
-- Reads each sidecar as raw text. dump() uses string.format("%q") for strings,
-- so each value is on a single line and special chars are escaped (\", \n, \\).
--
-- Key ordering in dump() is alphabetical, which means in the sidecar:
--   annotations  → comes first
--   doc_props    → comes after annotations (d > a)
--   stats        → comes after doc_props
--
-- Strategy: single pass through the whole file, collecting annotation texts
-- and doc metadata simultaneously. File is read line by line so only what is
-- needed is in memory at any time. Sidecar files without annotations are small
-- and exit the inner loop early (no annotations key found).
--
-- The pool is rebuilt once per session (on invalidateCache from onResume).
-- Within a session, pickHighlight() is O(1) with no I/O.
-- ---------------------------------------------------------------------------

local _hl_pool     = nil
local _last_hl_idx = nil

-- Extract a string value from a dump()-serialised line.
-- ["key"] = "value",  →  value (unescaped)
-- Returns nil if the key is not on this line.
local function _extractStr(line, key)
    -- Quick plain-string check before regex (cheap early exit)
    if not line:find(key, 1, true) then return nil end
    -- Greedy match: grab everything between the outer quotes.
    -- This correctly handles escaped quotes inside the value (\" stays as \").
    local val = line:match('%["' .. key .. '"%]%s*=%s*"(.*)"')
    if not val or val == "" then return nil end
    -- Unescape %q sequences: \" → "   \n → space   \\ → \
    val = val:gsub('\\"', '"'):gsub('\\n', ' '):gsub('\\\\', '\\')
    return val
end

local function _buildPool()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return {} end
    local ok_DS, DocSettings = pcall(require, "docsettings")
    if not ok_DS then return {} end

    local ReadHistory = package.loaded["readhistory"]
    if not ReadHistory or not ReadHistory.hist then return {} end

    local pool = {}

    for _, entry in ipairs(ReadHistory.hist) do
        local fp = entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local sidecar = DocSettings:findSidecarFile(fp)
            if sidecar then
                local f = io.open(sidecar, "r")
                if f then
                    -- Collect annotation texts and metadata in one pass.
                    -- Since doc_props/stats come AFTER annotations in dump() order,
                    -- we must read the whole file; we cannot stop at annotations end.
                    local texts   = {}
                    local title   = nil
                    local authors = nil

                    for line in f:lines() do
                        -- Annotation text lines are indented 8 spaces (2 levels deep)
                        if line:find('["text"]', 1, true) then
                            local t = _extractStr(line, "text")
                            if t and #t > 10 then
                                texts[#texts + 1] = t
                            end
                        -- doc_props and stats are at indent 4 (1 level deep)
                        elseif not title and line:find('["title"]', 1, true) then
                            title = _extractStr(line, "title")
                        elseif not authors and line:find('["authors"]', 1, true) then
                            authors = _extractStr(line, "authors")
                        end
                    end
                    f:close()

                    if #texts > 0 then
                        local book_title   = title or fp:match("([^/]+)%.[^%.]+$") or "?"
                        local book_authors = authors
                        for _, t in ipairs(texts) do
                            pool[#pool + 1] = { text = t, title = book_title, authors = book_authors }
                        end
                    end
                end
            end
        end
    end

    logger.warn("simpleui: quote: _buildPool: scanned " .. #pool .. " highlights from " .. #ReadHistory.hist .. " history entries")
    return pool
end

local function getPool()
    if not _hl_pool then
        _hl_pool = _buildPool()
        _last_hl_idx = nil
    end
    return _hl_pool
end

local function pickHighlight()
    local pool = getPool()
    local n = #pool
    if n == 0 then return nil end
    if n == 1 then _last_hl_idx = 1; return pool[1] end
    local idx = math.random(1, n - 1)
    if _last_hl_idx and idx >= _last_hl_idx then idx = idx + 1 end
    _last_hl_idx = idx
    return pool[idx]
end

-- ---------------------------------------------------------------------------
-- Widget builders
-- ---------------------------------------------------------------------------

local function buildWidget(inner_w, text_str, attr_str)
    local vg = VerticalGroup:new{ align = "center" }
    vg[#vg+1] = TextBoxWidget:new{
        text      = text_str,
        face      = _FACE_QUOTE,
        fgcolor   = _CLR_TEXT_QUOTE,
        width     = inner_w,
        alignment = "center",
    }
    vg[#vg+1] = _VSPAN_GAP
    vg[#vg+1] = TextBoxWidget:new{
        text      = attr_str,
        face      = _FACE_ATTR,
        fgcolor   = CLR_TEXT_SUB,
        bold      = true,
        width     = inner_w,
        alignment = "center",
    }
    return vg
end

local function buildFromQuote(inner_w)
    local q = pickQuote()
    if not q then
        return TextBoxWidget:new{
            text    = _("No quotes found."),
            face    = _FACE_QUOTE,
            fgcolor = CLR_TEXT_SUB,
            width   = inner_w,
        }
    end
    local attr = "— " .. (q.a or "?")
    if q.b and q.b ~= "" then attr = attr .. ",  " .. q.b end
    return buildWidget(inner_w, "\u{201C}" .. q.q .. "\u{201D}", attr)
end

local function buildFromHighlight(inner_w)
    local h = pickHighlight()
    if not h then
        logger.warn("simpleui: quote: buildFromHighlight: pool empty, showing fallback")
        return buildWidget(
            inner_w,
            _("No highlights found. Open a book and highlight some passages."),
            _("Your highlights")
        )
    end
    logger.warn("simpleui: quote: showing highlight from '" .. tostring(h.title) .. "': " .. tostring(h.text):sub(1, 60))
    local attr = "— " .. h.title
    if h.authors and h.authors ~= "" then attr = attr .. ",  " .. h.authors end
    return buildWidget(inner_w, "\u{201C}" .. h.text .. "\u{201D}", attr)
end

local function buildFromMixed(inner_w)
    local has_highlights = #getPool() > 0
    local has_quotes     = #loadQuotes() > 0
    if has_highlights and has_quotes then
        if math.random(2) == 1 then
            return buildFromHighlight(inner_w)
        else
            return buildFromQuote(inner_w)
        end
    elseif has_highlights then
        return buildFromHighlight(inner_w)
    else
        return buildFromQuote(inner_w)
    end
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "quote"
M.name        = _("Quote of the Day")
M.label       = nil
M.enabled_key = "quote_enabled"
M.default_on  = false
M.getCountLabel = nil

function M.invalidateCache()
    _hl_pool     = nil
    _last_hl_idx = nil
end

function M.build(w, ctx)
    local inner_w = w - PAD * 2
    local source  = getSource(ctx and ctx.pfx)
    logger.warn("simpleui: quote: build source=" .. source)
    local content
    if source == "highlights" then
        content = buildFromHighlight(inner_w)
    elseif source == "mixed" then
        content = buildFromMixed(inner_w)
    else
        content = buildFromQuote(inner_w)
    end
    return FrameContainer:new{
        bordersize     = 0,
        padding        = PAD,
        padding_bottom = PAD2,
        content,
    }
end

function M.getHeight(_ctx)
    return QUOTE_H
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    return {
        {
            text           = _lc("Source"),
            sub_item_table = {
                {
                    text           = _lc("Default Quotes"),
                    radio          = true,
                    checked_func   = function() return getSource(pfx) == "quotes" end,
                    keep_menu_open = true,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. SETTING_SOURCE, "quotes")
                        refresh()
                    end,
                },
                {
                    text           = _lc("My Highlights"),
                    radio          = true,
                    checked_func   = function() return getSource(pfx) == "highlights" end,
                    keep_menu_open = true,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. SETTING_SOURCE, "highlights")
                        M.invalidateCache()
                        refresh()
                    end,
                },
                {
                    text           = _lc("Quotes + My Highlights"),
                    radio          = true,
                    checked_func   = function() return getSource(pfx) == "mixed" end,
                    keep_menu_open = true,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. SETTING_SOURCE, "mixed")
                        M.invalidateCache()
                        refresh()
                    end,
                },
            },
        },
    }
end

return M