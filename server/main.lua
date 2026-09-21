local RSGCore = exports['rsg-core']:GetCoreObject()
local ActiveTrains = {} -- [source] = trainDbId

---------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------

-- Looks up the Config.Trains entry that matches a DB train row.
local function GetTrainConfig(train)
    for _, tc in ipairs(Config.Trains) do
        if tc.model == train.train_model and tc.company == train.company_id then
            return tc
        end
    end
    return nil
end

-- Clamp a number into [0, max]
local function Clamp(value, max)
    value = tonumber(value) or 0
    if value < 0 then return 0 end
    if value > max then return max end
    return value
end

-- Verifies the calling player owns `trainId` (personal train) and is the
-- one currently driving it (per ActiveTrains). Used to stop other players
-- from spoofing rsg-railroad:update* events with an arbitrary trainId.
local function IsAuthorizedForTrain(src, citizenid, trainId, train)
    if ActiveTrains[src] ~= trainId then return false end
    if not train or train.citizenid ~= citizenid then return false end
    return true
end

---------------------------------------------------------------
-- CALLBACKS
---------------------------------------------------------------
lib.callback.register('rsg-railroad:getOwnedTrains', function(source)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then return {} end
    return DB.GetOwnedTrains(Player.PlayerData.citizenid) or {}
end)

lib.callback.register('rsg-railroad:getTrainById', function(source, trainId)
    return DB.GetTrainById(trainId)
end)

lib.callback.register('rsg-railroad:canSpawnTrain', function(source)
    return ActiveTrains[source] == nil
end)

lib.callback.register('rsg-railroad:getAmbientState', function()
    local count = DB.GetOwnedCompanyCount()
    return count == 0
end)

lib.callback.register('rsg-railroad:getMyCompanyMembership', function(source, companyId)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then return nil end
    return DB.GetCompanyMembership(Player.PlayerData.citizenid, companyId)
end)

lib.callback.register('rsg-railroad:getCompanyData', function(source)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then return {} end
    return DB.GetCompanyData(Player.PlayerData.citizenid) or {}
end)

---------------------------------------------------------------
-- BUY TRAIN
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:buyTrain', function(trainIndex, stationId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local trainConfig = Config.Trains[trainIndex]
    if not trainConfig then return end

    -- Check limit
    local count = DB.CountTrains(citizenid)
    if count >= Config.MaxTrainsPerPlayer then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('train_limit_reached', Config.MaxTrainsPerPlayer), type = 'error', duration = 5000 })
        return
    end

    -- Check rank
    local requiredRankLabel = Config.Ranks[trainConfig.requiredRank] and Config.Ranks[trainConfig.requiredRank].label or 'Unknown'
    local membership = DB.GetCompanyMembership(citizenid, trainConfig.company)
    if membership then
        if membership.rank < trainConfig.requiredRank then
            TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('rank_too_low', requiredRankLabel), type = 'error', duration = 5000 })
            return
        end
    else
        -- Not a member yet - auto join at rank 1
        if trainConfig.requiredRank > 1 then
            TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('rank_too_low', requiredRankLabel), type = 'error', duration = 5000 })
            return
        end
        DB.JoinCompany(citizenid, trainConfig.company)
    end

    -- Check money
    local cash = Player.PlayerData.money['cash'] or 0
    if cash < trainConfig.cost then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('not_enough_money'), type = 'error', duration = 5000 })
        return
    end

    Player.Functions.RemoveMoney('cash', trainConfig.cost)
    -- New trains start at 50% fuel, water, and condition
    local startFuel = math.floor(trainConfig.maxFuel * 0.5)
    local startWater = math.floor(trainConfig.maxWater * 0.5)
    local startCondition = math.floor(trainConfig.maxCondition * 0.5)
    DB.InsertTrain(citizenid, trainConfig.company, trainConfig.model, trainConfig.label, startFuel, startWater, startCondition)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('train_bought') .. ' (50% fuel, water & condition)', type = 'success', duration = 7000 })

    Webhook.SendFields('economy', 'Train Purchased', {
        { 'Player', GetPlayerFullName(Player) .. ' (' .. citizenid .. ')' },
        { 'Company', Config.Companies[trainConfig.company] and Config.Companies[trainConfig.company].label or trainConfig.company },
        { 'Train', trainConfig.label },
        { 'Cost', '$' .. trainConfig.cost },
    }, 'success')
end)

---------------------------------------------------------------
-- SELL TRAIN
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:sellTrain', function(trainId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local train = DB.GetTrainById(trainId)
    if not train or train.citizenid ~= citizenid then return end

    -- Don't allow selling a train that's currently out and being driven
    -- (by this player or, in theory, spoofed from elsewhere).
    if ActiveTrains[src] == trainId then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('park_before_selling'), type = 'error', duration = 5000 })
        return
    end

    -- Find config for sell price
    local sellPrice = 0
    local tc = GetTrainConfig(train)
    if tc then sellPrice = tc.sellPrice end

    DB.DeleteTrain(trainId, citizenid)
    Player.Functions.AddMoney('cash', sellPrice)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('train_sold', sellPrice), type = 'success', duration = 5000 })

    Webhook.SendFields('economy', 'Train Sold', {
        { 'Player', GetPlayerFullName(Player) .. ' (' .. citizenid .. ')' },
        { 'Train', train.train_model },
        { 'Sell Price', '$' .. sellPrice },
    }, 'info')
end)

---------------------------------------------------------------
-- TICKET REVENUE (continuous passenger system)
-- Called when the driver reaches a station with passengers on board.
---------------------------------------------------------------
local lastTicketRevenue = {} -- [source] = os.time() of last payout, anti-spam

RegisterNetEvent('rsg-railroad:ticketRevenue', function(companyId, passengerCount)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not companyId or not Config.Companies[companyId] then return end

    passengerCount = tonumber(passengerCount) or 0
    if passengerCount <= 0 then return end

    -- Hard cap: nobody can plausibly have more than MaxBoardPerStop
    -- passengers waiting to be paid out for in one go. Also rate-limit so
    -- the event can't be spammed for free XP/cash.
    local cfg = Config.PassengerSystem
    passengerCount = math.min(passengerCount, cfg.MaxBoardPerStop or 10)

    local now = os.time()
    if lastTicketRevenue[src] and (now - lastTicketRevenue[src]) < 5 then return end
    lastTicketRevenue[src] = now

    local total       = passengerCount * cfg.TicketPrice
    local driverShare = math.floor(total * (1 - cfg.CompanyShare))
    local compShare   = math.floor(total * cfg.CompanyShare)

    -- Pay driver
    Player.Functions.AddMoney('cash', driverShare)

    -- Pay into company register
    if DB.GetCompanyOwnership(companyId) then
        DB.AddToCashRegister(companyId, compShare)
    end

    -- Award XP
    local citizenid = Player.PlayerData.citizenid
    local xpGain = passengerCount * cfg.TicketXP
    DB.AddCompanyXP(citizenid, companyId, xpGain)

    TriggerClientEvent('ox_lib:notify', src, {
        title       = locale('notify_title'),
        description = locale('ticket_revenue_summary', driverShare, compShare, xpGain),
        type        = 'success',
        duration    = 7000,
    })
end)

---------------------------------------------------------------
-- SPAWN / DESPAWN TRACKING
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:setTrainSpawned', function(spawned, trainId)
    local src = source
    if spawned then
        local Player = RSGCore.Functions.GetPlayer(src)
        if not Player then return end
        local train = DB.GetTrainById(trainId)
        if not train or train.citizenid ~= Player.PlayerData.citizenid then return end
        if ActiveTrains[src] then return end -- already has a train out

        ActiveTrains[src] = trainId
        DB.UnparkTrain(trainId)
    else
        ActiveTrains[src] = nil
    end
end)

---------------------------------------------------------------
-- PARK TRAIN
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:parkTrain', function(trainId, stationId, fuel, water, condition)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local train = DB.GetTrainById(trainId)
    if not IsAuthorizedForTrain(src, Player.PlayerData.citizenid, trainId, train) then return end

    local tc = GetTrainConfig(train)
    local maxFuel = tc and tc.maxFuel or 100
    local maxWater = tc and tc.maxWater or 100
    local maxCond = tc and tc.maxCondition or 100

    DB.ParkTrain(trainId, stationId, Clamp(fuel, maxFuel), Clamp(water, maxWater), Clamp(condition, maxCond))
    ActiveTrains[src] = nil
end)

---------------------------------------------------------------
-- UPDATE TRAIN STATE
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:updateTrainState', function(trainId, fuel, water, condition)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local train = DB.GetTrainById(trainId)
    if not IsAuthorizedForTrain(src, Player.PlayerData.citizenid, trainId, train) then return end

    local tc = GetTrainConfig(train)
    local maxFuel = tc and tc.maxFuel or 100
    local maxWater = tc and tc.maxWater or 100
    local maxCond = tc and tc.maxCondition or 100

    DB.UpdateTrainState(trainId, Clamp(fuel, maxFuel), Clamp(water, maxWater), Clamp(condition, maxCond))
end)

RegisterNetEvent('rsg-railroad:updateFuel', function(trainId, fuel)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local train = DB.GetTrainById(trainId)
    if not IsAuthorizedForTrain(src, Player.PlayerData.citizenid, trainId, train) then return end

    local tc = GetTrainConfig(train)
    DB.UpdateTrainFuel(trainId, Clamp(fuel, tc and tc.maxFuel or 100))
end)

RegisterNetEvent('rsg-railroad:updateWater', function(trainId, water)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local train = DB.GetTrainById(trainId)
    if not IsAuthorizedForTrain(src, Player.PlayerData.citizenid, trainId, train) then return end

    local tc = GetTrainConfig(train)
    DB.UpdateTrainWater(trainId, Clamp(water, tc and tc.maxWater or 100))
end)

RegisterNetEvent('rsg-railroad:updateCondition', function(trainId, condition)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local train = DB.GetTrainById(trainId)
    if not IsAuthorizedForTrain(src, Player.PlayerData.citizenid, trainId, train) then return end

    local tc = GetTrainConfig(train)
    DB.UpdateTrainCondition(trainId, Clamp(condition, tc and tc.maxCondition or 100))
end)

-- Sanity cap on how many miles can be credited in a single call, so a
-- spoofed event can't inflate total_miles (used for reward thresholds).
local MAX_MILES_PER_CALL = 25

RegisterNetEvent('rsg-railroad:addMiles', function(trainId, miles)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local train = DB.GetTrainById(trainId)
    if not IsAuthorizedForTrain(src, Player.PlayerData.citizenid, trainId, train) then return end

    miles = tonumber(miles) or 0
    if miles <= 0 then return end
    miles = math.min(miles, MAX_MILES_PER_CALL)

    DB.AddMiles(trainId, miles)
end)

---------------------------------------------------------------
-- REFUEL / REFILL / REPAIR
-- 1 item = +10% of max capacity, capped at 100%
---------------------------------------------------------------
local FILL_PERCENT = 10 -- each item adds 10% of max

RegisterNetEvent('rsg-railroad:refuelTrain', function(trainId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local train = DB.GetTrainById(trainId)
    if not train or train.citizenid ~= Player.PlayerData.citizenid then return end

    local tc = GetTrainConfig(train)
    local maxFuel = tc and tc.maxFuel or 100

    -- Check if already full
    if train.fuel >= maxFuel then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('fuel_tank_full'), type = 'error', duration = 5000 })
        return
    end

    -- Check for 1 item
    local item = Player.Functions.GetItemByName(Config.Fuel.item)
    if not item or item.amount < 1 then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('no_fuel_item', 1, Config.Fuel.itemLabel), type = 'error', duration = 5000 })
        return
    end

    -- Remove 1 item, add 10%
    Player.Functions.RemoveItem(Config.Fuel.item, 1)
    TriggerClientEvent('inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.Fuel.item], 'remove')

    local addAmount = math.floor(maxFuel * FILL_PERCENT / 100)
    local newFuel = math.min(train.fuel + addAmount, maxFuel)
    DB.UpdateTrainFuel(trainId, newFuel)
    TriggerClientEvent('rsg-railroad:syncFuel', src, newFuel)

    local pct = math.floor((newFuel / maxFuel) * 100)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('fuel_added_pct', pct), type = 'success', duration = 5000 })
end)

RegisterNetEvent('rsg-railroad:refillWater', function(trainId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local train = DB.GetTrainById(trainId)
    if not train or train.citizenid ~= Player.PlayerData.citizenid then return end

    local tc = GetTrainConfig(train)
    local maxWater = tc and tc.maxWater or 100

    if train.water >= maxWater then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('water_tank_full'), type = 'error', duration = 5000 })
        return
    end

    local item = Player.Functions.GetItemByName(Config.Water.item)
    if not item or item.amount < 1 then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('no_water_item', 1, Config.Water.itemLabel), type = 'error', duration = 5000 })
        return
    end

    Player.Functions.RemoveItem(Config.Water.item, 1)
    TriggerClientEvent('inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.Water.item], 'remove')

    local addAmount = math.floor(maxWater * FILL_PERCENT / 100)
    local newWater = math.min(train.water + addAmount, maxWater)
    DB.UpdateTrainWater(trainId, newWater)
    TriggerClientEvent('rsg-railroad:syncWater', src, newWater)

    local pct = math.floor((newWater / maxWater) * 100)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('water_added_pct', pct), type = 'success', duration = 5000 })
end)

RegisterNetEvent('rsg-railroad:repairTrain', function(trainId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local train = DB.GetTrainById(trainId)
    if not train or train.citizenid ~= Player.PlayerData.citizenid then return end

    local tc = GetTrainConfig(train)
    local maxCond = tc and tc.maxCondition or 100

    if train.condition >= maxCond then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('condition_full'), type = 'error', duration = 5000 })
        return
    end

    local item = Player.Functions.GetItemByName(Config.Condition.item)
    if not item or item.amount < 1 then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('no_repair_item', 1, Config.Condition.itemLabel), type = 'error', duration = 5000 })
        return
    end

    Player.Functions.RemoveItem(Config.Condition.item, 1)
    TriggerClientEvent('inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.Condition.item], 'remove')

    local addAmount = math.floor(maxCond * FILL_PERCENT / 100)
    local newCond = math.min(train.condition + addAmount, maxCond)
    DB.UpdateTrainCondition(trainId, newCond)
    TriggerClientEvent('rsg-railroad:syncCondition', src, newCond)

    local pct = math.floor((newCond / maxCond) * 100)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('condition_repaired_pct', pct), type = 'success', duration = 5000 })
end)

---------------------------------------------------------------
-- UNIVERSAL MAINTENANCE (works for config + DB trains)
-- Removes 1 item from player, tells client to apply the effect
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:useMaintenanceItem', function(itemName, quantity, mType, trainId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    quantity = tonumber(quantity) or 1
    quantity = math.max(1, math.min(quantity, 10)) -- sane cap; nobody uses 10+ at once

    -- Check player has the item
    local item = Player.Functions.GetItemByName(itemName)
    if not item or item.amount < quantity then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('missing_required_item'), type = 'error', duration = 5000 })
        TriggerClientEvent('rsg-railroad:maintenanceResult', src, mType, false)
        return
    end

    -- If DB train (id > 0), verify ownership before touching it
    local train = nil
    if trainId and trainId > 0 then
        train = DB.GetTrainById(trainId)
        if not train or train.citizenid ~= Player.PlayerData.citizenid then
            TriggerClientEvent('rsg-railroad:maintenanceResult', src, mType, false)
            return
        end
    end

    -- Remove item
    Player.Functions.RemoveItem(itemName, quantity)
    TriggerClientEvent('inventory:client:ItemBox', src, RSGCore.Shared.Items[itemName], 'remove')

    if train then
        local tc = GetTrainConfig(train)
        local maxVal = 100
        if tc then
            if mType == 'fuel' then maxVal = tc.maxFuel
            elseif mType == 'water' then maxVal = tc.maxWater
            elseif mType == 'condition' then maxVal = tc.maxCondition end
        end
        local addAmount = math.floor(maxVal * 0.10)
        if mType == 'fuel' then
            DB.UpdateTrainFuel(trainId, math.min(train.fuel + addAmount, maxVal))
        elseif mType == 'water' then
            DB.UpdateTrainWater(trainId, math.min(train.water + addAmount, maxVal))
        elseif mType == 'condition' then
            DB.UpdateTrainCondition(trainId, math.min(train.condition + addAmount, maxVal))
        end
    end

    -- Tell client to apply the effect locally
    TriggerClientEvent('rsg-railroad:maintenanceResult', src, mType, true)
end)

---------------------------------------------------------------
-- CLEANUP ON DISCONNECT
---------------------------------------------------------------
AddEventHandler('playerDropped', function()
    local src = source
    ActiveTrains[src] = nil
    lastTicketRevenue[src] = nil
end)
