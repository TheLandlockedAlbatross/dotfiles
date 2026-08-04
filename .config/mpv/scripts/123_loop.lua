local loop_a
local loop_b
local play_count = 0  -- Counter for the number of loop plays

local function loop_handler(_, time_pos)
    if time_pos then
        local dir = mp.get_property('play-dir')
        
        -- Check if we have reached loop_b
        if dir == 'forward' and time_pos >= loop_b then
            -- Play normally for the first two times
            if play_count < 1 then
                play_count = play_count + 1
                mp.commandv('seek', loop_a, 'absolute')
            elseif play_count == 1 then
                play_count = play_count + 1
                -- Play at X-speed on the third loop
                mp.set_property('speed', 0.25)
                mp.commandv('seek', loop_a, 'absolute')
            else
                -- Resume play at normal speed and start over
                play_count = 0  -- Reset play count
                mp.set_property('speed', 1)
                mp.commandv('seek', loop_a, 'absolute')
            end
        end
    end
end

mp.add_key_binding(':', '123-loop', function ()
    if loop_a == nil then
        loop_a = mp.get_property_native('time-pos')
        mp.osd_message("A-B 123-loop start " .. loop_a)
    elseif loop_b == nil then
        loop_b = mp.get_property_native('time-pos')
        if (loop_a > loop_b) then
            loop_a, loop_b = loop_b, loop_a  -- Swap if loop_a is greater than loop_b
        elseif loop_a == loop_b then
            mp.osd_message("A and B cannot be the same, ignoring")
            loop_b = nil
            return
        end
        play_count = 0  -- Reset play count when setting loop_b
        mp.observe_property('time-pos', 'native', loop_handler)
        mp.osd_message("A-B 123-loop " .. loop_a .. " - " .. loop_b)
    else
        mp.unobserve_property(loop_handler)
        mp.set_property('speed', 1)  -- Reset speed to normal
        mp.osd_message("Clear A-B 123 loop")
        loop_a = nil
        loop_b = nil
    end
end)

