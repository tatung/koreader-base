--[[--
Framebuffer API.

This will be extended by implementations of this API.

@module ffi.framebuffer
--]]

local Blitbuffer = require("ffi/blitbuffer")

local fb = {
    device = nil, -- points to a device object
    debug = function(...) --[[ NOP ]] end,

    bb = nil, -- should be set by implementations
    full_bb = nil, -- will hold a saved reference when a viewport is set
    viewport = nil,
    screen_size = nil,
    native_rotation_mode = nil,
    cur_rotation_mode = nil,
    blitbuffer_rotation_mode = nil,
}

--[[
Codes for rotation modes:

1 for no rotation,
2 for landscape with bottom on the right side of screen, etc.

           2
   +--------------+
   | +----------+ |
   | |          | |
   | | Freedom! | |
   | |          | |
   | |          | |
 3 | |          | | 1
   | |          | |
   | |          | |
   | +----------+ |
   |              |
   |              |
   +--------------+
          0
--]]
fb.ORIENTATION_PORTRAIT = 0
fb.ORIENTATION_LANDSCAPE = 1
fb.ORIENTATION_PORTRAIT_ROTATED = 2
fb.ORIENTATION_LANDSCAPE_ROTATED = 3

local EMULATE_READER_DPI = tonumber(os.getenv("EMULATE_READER_DPI"))

function fb:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.parent = self
    return o
end

function fb:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end

-- you can do the setup here, but remember to call this from
-- implementations!
function fb:init()
    self.blitbuffer_rotation_mode = self.bb:getRotation()
    -- asking the framebuffer for orientation is error prone,
    -- so we do this simple heuristic (for now)
    self.screen_size = self:getSize()
    if self.screen_size.w > self.screen_size.h then
        self.native_rotation_mode = self.ORIENTATION_LANDSCAPE
        self.screen_size.w, self.screen_size.h = self.screen_size.h, self.screen_size.w
        if self.device:isAlwaysPortrait() then
            -- some framebuffers need to be rotated counter-clockwise (they start in landscape mode)
            self.debug("enforcing portrait mode by doing an initial rotation")
            self.bb:rotate(-90)
            self.blitbuffer_rotation_mode = self.bb:getRotation()
            self.native_rotation_mode = self.ORIENTATION_PORTRAIT
        end
    else
        self.native_rotation_mode = self.ORIENTATION_PORTRAIT
    end
    self.cur_rotation_mode = self.native_rotation_mode
end

-- the ...Imp methods may be overridden to implement refresh
function fb:refreshFullImp(x, y, w, h)
    -- the simplest form of refresh implements only this method.
    -- the others default to fall back to this.
end
function fb:refreshPartialImp(x, y, w, h)
    -- default is fallback
    return self:refreshFullImp(x, y, w, h)
end
function fb:refreshUIImp(x, y, w, h)
    -- default is fallback
    return self:refreshPartialImp(x, y, w, h)
end
function fb:refreshFastImp(x, y, w, h)
    -- default is fallback
    return self:refreshPartialImp(x, y, w, h)
end

-- these should not be overridden, they provide the external refresh API:
function fb:refreshFull(x, y, w, h)
    x, y = self:calculateRealCoordinates(x, y)
    return self:refreshFullImp(x, y, w, h)
end
function fb:refreshPartial(x, y, w, h)
    x, y = self:calculateRealCoordinates(x, y)
    return self:refreshPartialImp(x, y, w, h)
end
function fb:refreshUI(x, y, w, h)
    x, y = self:calculateRealCoordinates(x, y)
    return self:refreshUIImp(x, y, w, h)
end
function fb:refreshFast(x, y, w, h)
    x, y = self:calculateRealCoordinates(x, y)
    return self:refreshFastImp(x, y, w, h)
end

-- should be overridden to free resources
function fb:close()
end

-- you probably do not need to override any of the following functions:

--[[
set a rectangle that represents the area of the screen we are working on
--]]
function fb:setViewport(viewport)
    if viewport.x < 0 or viewport.x > self.screen_size.w
    or viewport.y < 0 or viewport.y > self.screen_size.h
    or viewport.w < 0 or viewport.x+viewport.w > self.screen_size.w
    or viewport.h < 0 or viewport.y+viewport.h > self.screen_size.h
    then
        error("fb:setViewport() bad viewport")
    end
    -- we might be switching the viewport on the fly, so don't overwrite self.full_bb
    if not self.full_bb then
        self.full_bb = self.bb
    end
    self.debug("fb:setViewport() setting viewport to",
               viewport.x, viewport.y,
               viewport.w, viewport.h)
    self.bb = self.full_bb:viewport(
        viewport.x, viewport.y,
        viewport.w, viewport.h)
    self.viewport = viewport
    self.full_bb:fill(Blitbuffer.COLOR_WHITE)
    self:refreshFull()
end

function fb:calculateRealCoordinates(x, y)

    if not (x and y) then return end
    if not self.viewport then return x, y end

    --[[
        we need to adapt the coordinates when we have a viewport.
        this adaptation depends on the rotation:

      0,0               fb.w
        +---+---------------------------+---+
        |   |v.y                     v.y|   |
        |v.x|                           |vx2|
        +---+---------------------------+---+
        |   |           v.w             |   |
        |   |                           |   |
        |   |                           |   |
        |   |v.h     (viewport)         |   |
        |   |                           |   | fb.h
        |   |                           |   |
        |   |                           |   |
        |   |                           |   |
        +---+---------------------------+---+
        |v.x|                           |vx2|
        |   |vy2                     vy2|   |
        +---+---------------------------+---+

        The viewport offset v.y/v.x only applies when rotation is 0 degrees.
        For other rotations (0,0 is in one of the other edges), we need to
        recalculate the offsets.
    --]]

    local vx2 = self.screen_size.w - (self.viewport.x + self.viewport.w)
    local vy2 = self.screen_size.h - (self.viewport.y + self.viewport.h)

    if self.cur_rotation_mode == self.ORIENTATION_PORTRAIT then
        -- (0,0) is at top left of screen
        x = x + self.viewport.x
        y = y + self.viewport.y
    elseif self.cur_rotation_mode == self.ORIENTATION_LANDSCAPE then
        -- (0,0) is at bottom left of screen
        x = x + vy2
        y = y + self.viewport.x
    elseif self.cur_rotation_mode == self.ORIENTATION_PORTRAIT_ROTATED then
        -- (0,0) is at bottom right of screen
        x = x + vx2
        y = y + vy2
    else -- self.ORIENTATION_LANDSCAPE_ROTATED
        -- (0,0) is at top right of screen
        x = x + self.viewport.y
        y = y + vx2
    end

    return x, y
end

function fb:getSize()
    return {w = self.bb:getWidth(), h = self.bb:getHeight()}
end

function fb:getWidth()
    return self.bb:getWidth()
end

function fb:getHeight()
    return self.bb:getHeight()
end

function fb:getScreenWidth()
    return self.screen_size.w
end

function fb:getScreenHeight()
    return self.screen_size.h
end

function fb:getDPI()
    if self.dpi == nil then
        self.dpi = EMULATE_READER_DPI or G_reader_settings:readSetting("screen_dpi")
    end
    if self.dpi == nil and self.device then
        self.dpi = self.device.display_dpi
    end
    if self.dpi == nil then
        self.dpi = 160
    end
    return self.dpi
end

function fb:setDPI(dpi)
    G_reader_settings:saveSetting("screen_dpi", dpi)
end

function fb:scaleByDPI(px)
    -- scaled positive px should also be positive
    return math.ceil(px * self:getDPI()/167)
end

function fb:scaleBySize(px)
    -- larger screen needs larger scale
    local size_scale = math.min(self:getWidth(), self:getHeight())/600
    -- if users custom screen dpi, also scale by dpi
    local dpi_scale = size_scale

    local custom_dpi = EMULATE_READER_DPI or G_reader_settings:readSetting("screen_dpi")
    if custom_dpi and self.device and self.device.display_dpi ~= self.dpi then
        dpi_scale = self.dpi / 167
    end
    -- scaled positive px should also be positive
    return math.ceil(px * (size_scale + dpi_scale) / 2)
end

function fb:getRotationMode()
    return self.cur_rotation_mode
end

function fb:getScreenMode()
    if self:getWidth() > self:getHeight() then
        return "landscape"
    else
        return "portrait"
    end
end

function fb:setRotationMode(mode)
    self.bb:rotateAbsolute(-90 * (mode - self.native_rotation_mode - self.blitbuffer_rotation_mode))
    if self.viewport then
        self.full_bb:setRotation(self.bb:getRotation())
    end
    self.cur_rotation_mode = mode
end

function fb:setScreenMode(mode)
    if mode == "portrait" then
        if self.cur_rotation_mode ~= 0 then
            self:setRotationMode(self.ORIENTATION_PORTRAIT)
        end
    elseif mode == "landscape" then
        if self.cur_rotation_mode == self.ORIENTATION_PORTRAIT
        or self.cur_rotation_mode == self.ORIENTATION_PORTRAIT_ROTATED then
            self:setRotationMode(
                DLANDSCAPE_CLOCKWISE_ROTATION
                and self.ORIENTATION_LANDSCAPE
                or self.ORIENTATION_LANDSCAPE_ROTATED)
        elseif self.cur_rotation_mode == self.ORIENTATION_LANDSCAPE
        or self.cur_rotation_mode == self.ORIENTATION_LANDSCAPE_ROTATED then
            self:setRotationMode((self.cur_rotation_mode + 2) % 4)
        end
    end
end

function fb:getWindowTitle()
    return self.window_title
end

function fb:setWindowTitle(new_title)
    if new_title and new_title ~= "" then
        self.window_title = new_title .. " - KOReader"
    else
        self.window_title = "KOReader"
    end
end

function fb:toggleNightMode()
    self.bb:invert()
    if self.viewport then
        -- invert and blank out the full framebuffer when we are working on a viewport
        self.full_bb:invert()
        self.full_bb:fill(Blitbuffer.COLOR_WHITE)
    end
end

function fb:saveCurrentBB()
    if self.saved_bb then self.saved_bb:free() end
    self.saved_bb = self.bb:copy()
end

function fb:restoreFromSavedBB()
    if self.saved_bb then
        self.bb:blitFullFrom(self.saved_bb)
        -- free data
        self.saved_bb:free()
        self.saved_bb = nil
    end
end

function fb:shot(filename)
    self.bb:writePNG(filename)
end

return fb
