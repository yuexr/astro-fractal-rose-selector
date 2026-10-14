-- Fractal Rose Selector 0.1.2
local VERSION = '0.1.2'
local BASE = '/Game/Decorators/Hazards/Seeds/'
local paths = {
    regular = BASE .. 'Seed_FractalRose.Seed_FractalRose_C:GetPlanetIdentifier',
    hybrid = BASE .. 'Seed_SuperRose.Seed_SuperRose_C:GetPlanetIdentifier',
}
local planets = {
    sylva = 'Terran', desolo = 'TerranMoon', vesania = 'Exotic',
    novus = 'ExoticMoon', calidor = 'Arid', glacio = 'Tundra',
    atrox = 'Radiated', chronos = 'None',
}
local choice, choiceValue = nil, nil
local hooks, enumValues, errors = {}, nil, {}
local planted = {}
local function log(s, output)
    if output then output:Log(s .. '\n')
    else print('[Fractal Rose Selector] ' .. s .. '\n') end
end
local function valid(a) return a and a:IsValid() end
local function seed(a)
    if not valid(a) or a:GetFName():ToString():sub(1, 9) == 'Default__' then return false end
    local name = a:GetClass():GetFName():ToString()
    return name == 'Seed_FractalRose_C' or name == 'Seed_SuperRose_C'
end
local function key(a) return tostring(a:GetAddress()) .. ':' .. a:GetFullName() end
local function preserveGrowing(a)
    if seed(a) and a:HasAuthority() and a['SERVER Growing'] then
        local id = key(a)
        if not planted[id] then planted[id] = {actor=a, value=nil} end
    end
end
local function preserveExisting()
    for id, state in pairs(planted) do
        if not valid(state.actor) then planted[id] = nil end
    end
    -- leave seeds that are already growing alone
    for _, class in ipairs({'Seed_FractalRose_C', 'Seed_SuperRose_C'}) do
        for _, a in ipairs(FindAllOf(class) or {}) do preserveGrowing(a) end
    end
end
local function resolveEnum()
    if enumValues then return enumValues end
    local e = StaticFindObject('/Script/Astro.EPlanetIdentifier')
    assert(valid(e), 'Planet list not loaded. Try again after loading a save.')
    local values = {}
    e:ForEachName(function(name, value)
        values[name:ToString():match('([^:]+)$')] = value
    end)
    for planet, name in pairs(planets) do
        assert(type(values[name]) == 'number', 'Missing planet: ' .. planet)
    end
    enumValues = values
    return values
end
local function override(context)
    -- nil leaves the game's choice alone
    local ok, result = pcall(function()
        local actor = context:get()
        if not seed(actor) or not actor:HasAuthority() then return nil end
        local id = key(actor)
        if not actor['SERVER Growing'] then
            planted[id] = nil
            return nil
        end
        local state = planted[id]
        if state and not valid(state.actor) then state = nil; planted[id] = nil end
        if not state then
            state = {actor=actor, value=choiceValue}
            planted[id] = state
        end
        if state.value == nil then return nil end
        return state.value
    end)
    if ok then return result end
    if not errors.callback then
        errors.callback = true
        log('Couldn\'t pick a rose: ' .. tostring(result))
    end
end
local function ensureHooks(output)
    if choiceValue == nil then return end
    for kind, path in pairs(paths) do
        if not hooks[kind] then
            local fn = StaticFindObject(path)
            if valid(fn) then
                local ok, pre, post = pcall(RegisterHook, path, override)
                if ok then
                    hooks[kind] = {pre, post}
                    errors[kind] = nil
                    if not output then log(kind .. ' hook ready.') end
                elseif errors[kind] ~= tostring(pre) then
                    errors[kind] = tostring(pre)
                    log(kind .. ' hook failed: ' .. tostring(pre), output)
                end
            end
        end
    end
end
local function reset(output)
    preserveExisting()
    choice, choiceValue = nil, nil
    -- keep the hooks for seeds planted before reset
    log('Reset. Growing roses keep their choice.', output)
end
local function status(output)
    log('Selection for new plantings: ' .. (choice and (choice:sub(1, 1):upper() .. choice:sub(2)) or 'normal') .. '.', output)
    if errors.callback then log('A seed selection failed. Details are in UE4SS.log.', output) end
end
-- seed classes might load later, so try again when one spawns
RegisterBeginPlayPreHook(function(context)
    local ok, err = pcall(function()
        local actor = context:get()
        if seed(actor) then
            -- already growing when loaded? keep its original choice
            preserveGrowing(actor)
            ensureHooks()
        end
    end)
    if not ok then log('Couldn\'t set up seed hooks: ' .. tostring(err)) end
end)
local help = 'fractalrose <sylva|desolo|vesania|novus|calidor|glacio|atrox|chronos>\n'
    .. 'fractalrose status | fractalrose reset\n'
    .. 'rose works too, e.g. rose calidor.\n'
    .. 'Works on both seed types. Growing roses keep their choice.\n'
    .. 'Resets when you close the game.\n'
local function command(_, parameters, output)
    local action = parameters[1] and parameters[1]:lower() or 'help'
    if #parameters ~= 1 or (action ~= 'status' and action ~= 'reset' and not planets[action]) then
        output:Log(help)
        return true
    end
    -- reply here, before the console output expires
    local ok, err = pcall(function()
        if action == 'reset' then reset(output)
        elseif action == 'status' then ensureHooks(output)
        else
            local value = resolveEnum()[planets[action]]
            preserveExisting()
            choice, choiceValue = action, value
            ensureHooks(output)
        end
        status(output)
    end)
    if not ok then log('Command failed: ' .. tostring(err), output) end
    return true
end
RegisterConsoleCommandHandler('fractalrose', command)
RegisterConsoleCommandHandler('rose', command)
log('v' .. VERSION .. ' loaded. Type fractalrose or rose for help.')
