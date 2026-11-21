-- map-extensions owns save/load and new-world initialization. Only simulation
-- state belongs here; configuration, code and temporary targeting scratch do not.
local M = {}
local function canonical(value)
    if type(value) ~= 'table' then return type(value) .. ':' .. tostring(value) end
    local keys, parts = {}, {}
    for key in pairs(value) do keys[#keys+1] = key end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do parts[#parts+1] = canonical(key) .. '=' .. canonical(value[key]) end
    return '{' .. table.concat(parts, ';') .. '}'
end
function M.new(blocks, config, profile_count, rebuild)
    local gameplay = {units=config.units, projectiles=config.projectiles, decorations=config.decorations}
    if config.projectile_physics then gameplay.projectile_physics = config.projectile_physics end
    -- Load policy is not gameplay identity. Existing format-5 saves keep the
    -- same fingerprint when their gameplay fields have not changed.
    local state = {blocks=blocks, allow_config_changes=config.allow_config_changes_on_load ~= false,
        config=canonical(gameplay),
        assets=canonical({projectiles=config.projectiles or {}, decorations=config.decorations or {}})}
    local no_assets = not next(config.projectiles or {}) and not next(config.decorations or {})
    local retained = {seed=true, ['entity-variant']=true, ['entity-uid']=true,
        ['entity-type']=true, ['decoration-variant']=true, ['decoration-uid']=true}
    local limits = {cooldown=60000, movement=20, pending=63, ['pending-cooldown']=60000, ['sync-wait']=60000, profile=(profile_count or 160)-1,
        ['weapon-cycle']=40, ['weapon-tick']=1, ['weapon-phase']=6,
        ['entity-variant']=33, ['entity-type']=255, ['decoration-variant']=33}
    function state:initialize()
        for _, block in ipairs(self.blocks) do
            if not block[4] then core.setMemory(block[2], 0, block[3]) end
        end
        core.writeInteger(self.blocks[1][2], 0x1D872B41)
        if rebuild then rebuild() end
    end
    function state:serialize(handle)
        handle:put('format', '5')
        handle:put('config', self.config)
        handle:put('assets', self.assets)
        for _, block in ipairs(self.blocks) do
            handle:put(block[1] .. '.bin', core.readString(block[2], block[3]))
        end
    end
    -- Map Extensions calls this before restoring any extension. Direct restores
    -- use the same validator; no pending state is retained between callbacks.
    -- Loading never fails because of changed settings, an older save format or a
    -- different unit limit (a save/map made in Crusader has 2500 unit slots,
    -- Extreme 10000): whatever no longer fits is reset to zero and logged.
    -- Only an explicit allow_config_changes_on_load: false keeps the strict check.
    function state:validate(handle)
        local present = handle:exists('format')
        if not present and not handle.required then return end
        local notes = {}
        if not present or handle:get('format') ~= '5' then
            notes[1] = 'saved state is from an older version; projectile timers start fresh'
            return {fresh=true, notes=notes}
        end
        local saved_config = handle:get('config')
        local changed = saved_config ~= self.config
        assert(not changed or self.allow_config_changes,
            '[custom-projectiles] saved projectile settings differ; restore the settings used for this save or enable allow_config_changes_on_load')
        local reset_visuals = false
        if changed then
            notes[#notes+1] = 'projectile settings changed since this save; firing timers were reset'
            if handle:exists('assets') then
                reset_visuals = handle:get('assets') ~= self.assets
            else
                reset_visuals = not no_assets
            end
        end
        local pending = {reconfigure=changed, notes=notes}
        for i, block in ipairs(self.blocks) do
            local name = block[1] .. '.bin'
            local bytes = handle:exists(name) and handle:get(name) or nil
            if type(bytes) ~= 'string' then
                bytes = nil
                if not block[4] then notes[#notes+1] = 'missing ' .. name .. '; reset' end
            elseif block[4] then
                -- Graphics-slot layouts are rebuilt from this config, never restored.
                if bytes ~= core.readString(block[2], block[3]) then reset_visuals = true end
                bytes = nil
            elseif #bytes ~= block[3] then
                notes[#notes+1] = name .. ' was saved with ' .. #bytes .. ' bytes, now ' .. block[3] .. ' (different unit limit); resized'
                if #bytes < block[3] then
                    bytes = bytes .. string.rep('\0', block[3] - #bytes)
                else
                    bytes = bytes:sub(1, block[3])
                end
            end
            if bytes and limits[block[1]] and not (changed and block[1] == 'profile') then
                for offset = 1, #bytes - 3, 4 do
                    local a,b,c,d = bytes:byte(offset, offset+3)
                    if a + b*256 + c*65536 + d*16777216 > limits[block[1]] then
                        notes[#notes+1] = 'out-of-range values in ' .. name .. '; reset'
                        bytes = nil
                        break
                    end
                end
            end
            pending[i] = bytes
        end
        if reset_visuals then
            notes[#notes+1] = 'custom projectile/decoration graphics changed; flying projectiles and decorations use their default look'
        end
        pending.reset_visuals = reset_visuals
        return pending
    end
    function state:deserialize(handle)
        local pending = self:validate(handle)
        if not pending then self:initialize(); return end
        for _, note in ipairs(pending.notes) do log(WARNING, '[custom-projectiles] ' .. note) end
        if pending.fresh then self:initialize(); return end
        for i, block in ipairs(self.blocks) do
            if block[4] then
                -- rebuilt by rebuild() below
            elseif pending[i] == nil
                or (pending.reconfigure and not retained[block[1]])
                or (pending.reset_visuals and retained[block[1]] and block[1] ~= 'seed') then
                core.setMemory(block[2], 0, block[3])
            else
                local bytes = {}
                for j = 1, #pending[i] do bytes[j] = pending[i]:byte(j) end
                core.writeBytes(block[2], bytes)
            end
        end
        if pending[1] == nil then core.writeInteger(self.blocks[1][2], 0x1D872B41) end
        if rebuild then rebuild() end
    end
    return state
end
return M
