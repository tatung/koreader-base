--[[--
Module for interfacing SDL 2.0 video/input facilities

This module is intended to provide input/output facilities on a
typical desktop (rather than a dedicated e-ink reader, for which
there would probably be raw framebuffer/input device access
instead).

@module ffi.sdl2_0
]]

local bit = require("bit")
local ffi = require("ffi")
local util = require("ffi/util")

local dummy = require("ffi/SDL2_0_h")
local dummy = require("ffi/linux_input_h")

-----------------------------------------------------------------

local SDL = ffi.load("SDL2")

local S = {
    w = 0, h = 0,
    screen = nil,
    renderer = nil,
    texture = nil,
    SDL = SDL,
}

local function openGameController()
    local num_joysticks = SDL.SDL_NumJoysticks()

    if num_joysticks < 1 then
        S.controller = nil
        io.write("SDL: no gamecontrollers connected", "\n")
        return
    end

    for joystick_counter = 0, num_joysticks-1 do
        if SDL.SDL_IsGameController(joystick_counter) ~= 0 then
            S.controller = SDL.SDL_GameControllerOpen(joystick_counter);
            if S.controller ~= nil then
                io.write("SDL: opened gamecontroller ",joystick_counter, ": ",
                         ffi.string(SDL.SDL_GameControllerNameForIndex(joystick_counter)), "\n");
                break
            else
                io.write("SDL: could not open gamecontroller ",joystick_counter, ": ",
                         ffi.string(SDL.SDL_GameControllerNameForIndex(joystick_counter)), "\n");
            end
        end
    end
end

-- initialization for both input and eink output
function S.open()
    if SDL.SDL_WasInit(SDL.SDL_INIT_VIDEO) ~= 0 then
        -- already initialized
        return true
    end

    SDL.SDL_SetMainReady()

    if SDL.SDL_Init(bit.bor(SDL.SDL_INIT_VIDEO,
                            SDL.SDL_INIT_JOYSTICK,
                            SDL.SDL_INIT_GAMECONTROLLER)) ~= 0 then
        error("Cannot initialize SDL.")
    end

    local full_screen = os.getenv("SDL_FULLSCREEN")
    if full_screen then
        local mode = ffi.new("struct SDL_DisplayMode")
        if SDL.SDL_GetCurrentDisplayMode(0, mode) ~= 0 then
            error("SDL cannot get current display mode.")
        end
        S.w, S.h = mode.w, mode.h
    else
        S.w = tonumber(os.getenv("EMULATE_READER_W")) or 600
        S.h = tonumber(os.getenv("EMULATE_READER_H")) or 800
    end

    -- set up screen (window)
    S.screen = SDL.SDL_CreateWindow("KOReader",
        tonumber(os.getenv("KOREADER_WINDOW_POS_X")) or SDL.SDL_WINDOWPOS_UNDEFINED,
        tonumber(os.getenv("KOREADER_WINDOW_POS_Y")) or SDL.SDL_WINDOWPOS_UNDEFINED,
        S.w, S.h,
        bit.bor(full_screen and 1 or 0, SDL.SDL_WINDOW_RESIZABLE)
    )

    S.renderer = SDL.SDL_CreateRenderer(S.screen, -1, 0)
    S.texture = S.createTexture()

    openGameController()
end

function S.createTexture(w, h)
    w = w or S.w
    h = h or S.h

    return SDL.SDL_CreateTexture(
        S.renderer,
        SDL.SDL_PIXELFORMAT_ABGR8888,
        SDL.SDL_TEXTUREACCESS_STREAMING,
        w, h)
end

function S.destroyTexture(texture)
    SDL.SDL_DestroyTexture(texture)
end

local rect = ffi.metatype("SDL_Rect", {})
function S.rect(x, y, w, h)
    return rect(x, y, w, h)
end

-- one SDL event can generate more than one event for koreader,
-- so this represents a FIFO queue
local inputQueue = {}

local function genEmuEvent(evtype, code, value)
    local secs, usecs = util.gettime()
    local ev = {
        type = tonumber(evtype),
        code = tonumber(code),
        value = tonumber(value),
        time = { sec = secs, usec = usecs },
    }
    table.insert(inputQueue, ev)
end

local function handleWindowEvent(event_window)
    -- The next buffer might always contain garbage, and on X11 without
    -- compositing the buffers will be damaged just by moving the window
    -- partly offscreen, minimizing it, or putting another window
    -- (partially) on top of it.
    -- Handling `SDL_WINDOWEVENT_EXPOSED` is the only way to deal with
    -- this without sending regular updates.
    if event_window.event == SDL.SDL_WINDOWEVENT_EXPOSED then
        SDL.SDL_RenderCopy(S.renderer, S.texture, nil, nil)
        SDL.SDL_RenderPresent(S.renderer)
    elseif (event_window.event == SDL.SDL_WINDOWEVENT_RESIZED
             or event_window.event == SDL.SDL_WINDOWEVENT_SIZE_CHANGED) then
        local w = 0
        local h = 1
        local new_size_w = event_window.data1
        local new_size_h = event_window.data2

        if new_size_w and new_size_h then
            genEmuEvent(ffi.C.EV_MSC, w, new_size_w)
            genEmuEvent(ffi.C.EV_MSC, h, new_size_h)
            genEmuEvent(ffi.C.EV_MSC, SDL.SDL_WINDOWEVENT_RESIZED, 0)
        end
    end
end

local last_joystick_event_secs = 0
local last_joystick_event_usecs = 0

local function handleJoyAxisMotionEvent(event)
    local axis_ev = event.jaxis
    local value = axis_ev.value

    local neutral_max_val = 5000
    local min_time_since_last_ev = 0.3

    -- ignore random neutral fluctuations
    if (value > -neutral_max_val) and (value < neutral_max_val) then return end

    local current_ev_s, current_ev_us = util.gettime()

    local since_last_ev = current_ev_s-last_joystick_event_secs + (current_ev_us-last_joystick_event_usecs)/1000000

    local axis = axis_ev.axis

    if not ( since_last_ev > min_time_since_last_ev ) then return end

    -- left stick 0/1
    if axis == 0 then
        if value < -neutral_max_val then
            -- send left
            genEmuEvent(ffi.C.EV_KEY, 80, 1)
        else
            -- send right
            genEmuEvent(ffi.C.EV_KEY, 79, 1)
        end
    elseif axis == 1 then
        if value < -neutral_max_val then
            -- send up
            genEmuEvent(ffi.C.EV_KEY, 82, 1)
        else
            -- send down
            genEmuEvent(ffi.C.EV_KEY, 81, 1)
        end
    -- right stick 3/4
    elseif axis == 4 then
        if value < -neutral_max_val then
            -- send page up
            genEmuEvent(ffi.C.EV_KEY, 75, 1)
        else
            -- send page down
            genEmuEvent(ffi.C.EV_KEY, 78, 1)
        end
    -- left trigger 2
    -- right trigger 5
    end

    last_joystick_event_secs, last_joystick_event_usecs = util.gettime()
end

local is_in_touch = false
local dropped_file_path

function S.waitForEvent(usecs)
    usecs = usecs or -1
    local event = ffi.new("union SDL_Event")
    local countdown = usecs
    while true do
        -- check for queued events
        if #inputQueue > 0 then
            -- return oldest FIFO element
            return table.remove(inputQueue, 1)
        end

        -- otherwise, wait for event
        local got_event = 0
        if usecs < 0 then
            got_event = SDL.SDL_WaitEvent(event);
        else
            -- timeout mode - use polling
            while countdown > 0 and got_event == 0 do
                got_event = SDL.SDL_PollEvent(event)
                if got_event == 0 then
                    -- no event, wait 10 msecs before polling again
                    SDL.SDL_Delay(10)
                    countdown = countdown - 10000
                end
            end
        end
        if got_event == 0 then
            error("Waiting for input failed: timeout\n")
        end

        -- if we got an event, examine it here and generate
        -- events for koreader
        if ffi.os == "OSX" and (event.type == SDL.SDL_FINGERMOTION or
            event.type == SDL.SDL_FINGERDOWN or
            event.type == SDL.SDL_FINGERUP) then
            -- noop for trackpad finger inputs which interfere with emulated mouse inputs
            do end -- luacheck: ignore 541
        elseif event.type == SDL.SDL_KEYDOWN then
            genEmuEvent(ffi.C.EV_KEY, event.key.keysym.scancode, 1)
        elseif event.type == SDL.SDL_KEYUP then
            genEmuEvent(ffi.C.EV_KEY, event.key.keysym.scancode, 0)
        elseif event.type == SDL.SDL_MOUSEMOTION
            or event.type == SDL.SDL_FINGERMOTION then
            local is_finger = event.type == SDL.SDL_FINGERMOTION
            if is_in_touch then
                if is_finger then
                    if event.tfinger.dx ~= 0 then
                        genEmuEvent(ffi.C.EV_ABS, ffi.C.ABS_MT_POSITION_X,
                            event.tfinger.x * S.w)
                    end
                    if event.tfinger.dy ~= 0 then
                        genEmuEvent(ffi.C.EV_ABS, ffi.C.ABS_MT_POSITION_Y,
                            event.tfinger.y * S.h)
                    end
                else
                    if event.motion.xrel ~= 0 then
                        genEmuEvent(ffi.C.EV_ABS, ffi.C.ABS_MT_POSITION_X,
                            event.button.x)
                    end
                    if event.motion.yrel ~= 0 then
                        genEmuEvent(ffi.C.EV_ABS, ffi.C.ABS_MT_POSITION_Y,
                            event.button.y)
                    end
                end
                genEmuEvent(ffi.C.EV_SYN, ffi.C.SYN_REPORT, 0)
            end
        elseif event.type == SDL.SDL_MOUSEBUTTONUP
            or event.type == SDL.SDL_FINGERUP then
            is_in_touch = false;
            genEmuEvent(ffi.C.EV_ABS, ffi.C.ABS_MT_TRACKING_ID, -1)
            genEmuEvent(ffi.C.EV_SYN, ffi.C.SYN_REPORT, 0)
        elseif event.type == SDL.SDL_MOUSEBUTTONDOWN
            or event.type == SDL.SDL_FINGERDOWN then
            local is_finger = event.type == SDL.SDL_FINGERDOWN
            -- use mouse click to simulate single tap
            is_in_touch = true
            genEmuEvent(ffi.C.EV_ABS, ffi.C.ABS_MT_TRACKING_ID, 0)
            genEmuEvent(ffi.C.EV_ABS, ffi.C.ABS_MT_POSITION_X,
                is_finger and event.tfinger.x * S.w or event.button.x)
            genEmuEvent(ffi.C.EV_ABS, ffi.C.ABS_MT_POSITION_Y,
                is_finger and event.tfinger.y * S.h or event.button.y)
            genEmuEvent(ffi.C.EV_SYN, ffi.C.SYN_REPORT, 0)
        elseif event.type == SDL.SDL_MULTIGESTURE then -- luacheck: ignore 542
            -- TODO: multi-touch support
        elseif event.type == SDL.SDL_DROPFILE then
            dropped_file_path = ffi.string(event.drop.file)
            genEmuEvent(ffi.C.EV_MSC, SDL.SDL_DROPFILE, 0)
        elseif event.type == SDL.SDL_WINDOWEVENT then
            handleWindowEvent(event.window)
        --- Gamepad support ---
        -- For debugging it can be helpful to use:
        -- print(ffi.string(SDL.SDL_GameControllerGetStringForButton(button)))
        -- @TODO Proper support instead of faux keyboard presses
        --
        --- Controllers ---
        elseif event.type == SDL.SDL_CONTROLLERDEVICEADDED
               or event.type == SDL.SDL_CONTROLLERDEVICEREMOVED
               or event.type == SDL.SDL_CONTROLLERDEVICEREMAPPED then
            openGameController()
        --- Sticks & triggers ---
        elseif event.type == SDL.SDL_JOYAXISMOTION then
            handleJoyAxisMotionEvent(event)
        --- Buttons (such as A, B, X, Y) ---
        elseif event.type == SDL.SDL_JOYBUTTONDOWN then
            local button = event.cbutton.button

            if button == SDL.SDL_CONTROLLER_BUTTON_A then
                -- send enter
                genEmuEvent(ffi.C.EV_KEY, 40, 1)
                -- send end (bound to press)
                genEmuEvent(ffi.C.EV_KEY, 77, 1)
            elseif button == SDL.SDL_CONTROLLER_BUTTON_B then
                -- send escape
                genEmuEvent(ffi.C.EV_KEY, 41, 1)
            -- left bumper
            elseif button == SDL.SDL_CONTROLLER_BUTTON_BACK then
                -- send page up
                genEmuEvent(ffi.C.EV_KEY, 75, 1)
            -- right bumper
            elseif button == SDL.SDL_CONTROLLER_BUTTON_GUIDE then
                -- send page down
                genEmuEvent(ffi.C.EV_KEY, 78, 1)
            -- On the Xbox One controller, start = start but leftstick = menu button
            elseif button == SDL.SDL_CONTROLLER_BUTTON_START or button == SDL.SDL_CONTROLLER_BUTTON_LEFTSTICK then
                -- send F1 (bound to menu in front at the time of writing)
                genEmuEvent(ffi.C.EV_KEY, 58, 1)
            end
        --- D-pad ---
        elseif event.type == SDL.SDL_JOYHATMOTION then
            local hat_position = event.jhat.value

            if hat_position == SDL.SDL_HAT_UP then
                -- send up
                genEmuEvent(ffi.C.EV_KEY, 82, 1)
            elseif hat_position == SDL.SDL_HAT_DOWN then
                -- send down
                genEmuEvent(ffi.C.EV_KEY, 81, 1)
            elseif hat_position == SDL.SDL_HAT_LEFT then
                -- send left
                genEmuEvent(ffi.C.EV_KEY, 80, 1)
            elseif hat_position == SDL.SDL_HAT_RIGHT then
                -- send right
                genEmuEvent(ffi.C.EV_KEY, 79, 1)
            end
        elseif event.type == SDL.SDL_QUIT then
            -- send Alt + F4
            genEmuEvent(ffi.C.EV_KEY, 226, 1)
            genEmuEvent(ffi.C.EV_KEY, 61, 1)
        end
    end
end

function S.getDroppedFilePath()
    return dropped_file_path
end

function S.hasClipboardText()
    return SDL.SDL_HasClipboardText()
end

function S.getClipboardText()
    return ffi.string(SDL.SDL_GetClipboardText())
end

function S.setClipboardText(text)
    return SDL.SDL_SetClipboardText(text)
end

return S
