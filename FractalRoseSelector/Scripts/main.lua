-- Fractal Rose Selector 0.1.0
local VERSION = '0.1.0'
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
local selections = 0
local function log(s) print('[Fractal Rose Selector] ' .. s .. '\n') end
local function valid(a) return a and a:IsValid() end
local function seed(a)
    if not valid(a) or a:GetFName():ToString():sub(1, 9) == 'Default__' then return false end
    local name = a:GetClass():GetFName():ToString()
    return name == 'Seed_FractalRose_C' or name == 'Seed_SuperRose_C'
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
    if choiceValue == nil then return end
    local ok, result = pcall(function()
        local actor = context:get()
        if not seed(actor) or not actor:HasAuthority() then return nil end
        selections = selections + 1
        return choiceValue
    end)
    if ok then return result end
    if not errors.callback then
        errors.callback = true
        log('Couldn\'t pick a rose: ' .. tostring(result))
    end
end
local function ensureHooks()
    if choiceValue == nil then return end
    for kind, path in pairs(paths) do
        if not hooks[kind] then
            local fn = StaticFindObject(path)
            if valid(fn) then
                local ok, pre, post = pcall(RegisterHook, path, override)
                if ok then
                    hooks[kind] = {pre, post}
                    errors[kind] = nil
                    log(kind .. ' hook ready.')
                elseif errors[kind] ~= tostring(pre) then
                    errors[kind] = tostring(pre)
                    log(kind .. ' hook failed: ' .. tostring(pre))
                end
            end
        end
    end
end
local function reset()
    choice, choiceValue = nil, nil
    for kind, ids in pairs(hooks) do
        local ok, err = pcall(UnregisterHook, paths[kind], ids[1], ids[2])
        if ok then hooks[kind] = nil; errors[kind] = nil
        else errors[kind] = tostring(err); log('Couldn\'t remove hook for ' .. kind .. ': ' .. tostring(err)) end
    end
    log('Reset. Back to normal rose selection.')
end
local function status()
    local function state(kind)
        if errors[kind] then return 'ERROR' end
        if hooks[kind] then return 'attached' end
        return choice and 'waiting for seeds' or 'off'
    end
    log(string.format('STATUS: %s; regular=%s; hybrid=%s; calls=%d.',
        choice and ('forcing ' .. choice) or 'vanilla', state('regular'), state('hybrid'), selections))
end
-- seed classes might load later, so try again when one spawns
RegisterBeginPlayPreHook(function(context)
    if choiceValue == nil then return end
    local ok, err = pcall(function()
        if seed(context:get()) then ensureHooks() end
    end)
    if not ok then log('Couldn\'t set up seed hooks: ' .. tostring(err)) end
end)
local help = 'fractalrose <sylva|desolo|vesania|novus|calidor|glacio|atrox|chronos>\n'
    .. 'fractalrose status | fractalrose reset\n'
    .. 'Works on both seed types. Resets when you close the game.\n'
RegisterConsoleCommandHandler('fractalrose', function(_, parameters, output)
    local action = parameters[1] and parameters[1]:lower() or 'help'
    if #parameters ~= 1 or (action ~= 'status' and action ~= 'reset' and not planets[action]) then
        output:Log(help)
        return true
    end
    -- output is only valid during this callback
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if action == 'reset' then reset()
            elseif action == 'status' then ensureHooks(); status()
            else
                local value = resolveEnum()[planets[action]]
                choice, choiceValue = action, value
                ensureHooks()
                status()
            end
        end)
        if not ok then log('Command failed: ' .. tostring(err)) end
    end)
    output:Log('Check the log for the result.\n')
    return true
end)
log('v' .. VERSION .. ' loaded. Type fractalrose for help.')
