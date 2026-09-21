local RSGCore = exports['rsg-core']:GetCoreObject()

---------------------------------------------------------------
-- CALLBACKS
---------------------------------------------------------------
lib.callback.register('rsg-railroad:getCompanySupplies', function(source, companyId)
    return DB.GetCompanySupplies(companyId)
end)

---------------------------------------------------------------
-- OWNER: ADD SUPPLIES FROM INVENTORY
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:addSupply', function(companyId, itemName, quantity)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    -- Verify owner
    local ownership = DB.GetCompanyOwnership(companyId)
    if not ownership or ownership.owner_citizenid ~= Player.PlayerData.citizenid then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('not_owner_of_company'), type = 'error', duration = 5000 })
        return
    end

    quantity = tonumber(quantity) or 0
    if quantity <= 0 then return end

    -- Validate item is a supply item
    local validItem = false
    for _, si in ipairs(Config.SupplyItems) do
        if si.item == itemName then validItem = true break end
    end
    if not validItem then return end

    -- Check player has the item
    local item = Player.Functions.GetItemByName(itemName)
    if not item or item.amount < quantity then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('missing_item_quantity'), type = 'error', duration = 5000 })
        return
    end

    -- Remove from player, add to company stock
    Player.Functions.RemoveItem(itemName, quantity)
    TriggerClientEvent('inventory:client:ItemBox', src, RSGCore.Shared.Items[itemName], 'remove')
    DB.AddSupplyItem(companyId, itemName, quantity)

    local itemLabel = RSGCore.Shared.Items[itemName] and RSGCore.Shared.Items[itemName].label or itemName
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('supply_added_notify', quantity, itemLabel), type = 'success', duration = 5000 })
end)

---------------------------------------------------------------
-- DRIVER: TAKE SUPPLY (free from company stock)
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:takeSupply', function(companyId, itemName, quantity)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    quantity = tonumber(quantity) or 1
    if quantity <= 0 then return end

    -- Verify player is approved employee OR owner
    local ownership = DB.GetCompanyOwnership(companyId)
    local isOwner = ownership and ownership.owner_citizenid == citizenid
    local isDriver = false
    if not isOwner then
        local employee = DB.GetEmployeeByIds(companyId, citizenid)
        isDriver = employee and employee.status == 'approved'
    end

    if not isOwner and not isDriver then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('not_authorized'), type = 'error', duration = 5000 })
        return
    end

    -- Check stock
    local supply = DB.GetSupplyItem(companyId, itemName)
    if not supply or supply.quantity < quantity then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('not_enough_stock'), type = 'error', duration = 5000 })
        return
    end

    -- Take from stock, give to player
    DB.TakeSupplyItem(companyId, itemName, quantity)
    Player.Functions.AddItem(itemName, quantity)
    TriggerClientEvent('inventory:client:ItemBox', src, RSGCore.Shared.Items[itemName], 'add')

    local itemLabel = RSGCore.Shared.Items[itemName] and RSGCore.Shared.Items[itemName].label or itemName
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('supply_taken_notify', quantity, itemLabel), type = 'success', duration = 5000 })
end)
