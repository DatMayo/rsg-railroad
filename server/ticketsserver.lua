

local RSGCore = exports['rsg-core']:GetCoreObject()


RSGCore.Functions.CreateCallback('rsg-traintickets:server:useTicket', function(source, cb, companyId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player then
        cb('no_ticket')
        return
    end

    -- Company owners ride for free
    if companyId then
        local ownership = DB.GetCompanyOwnership(companyId)
        if ownership and ownership.owner_citizenid == Player.PlayerData.citizenid then
            cb('has_ticket')
            return
        end
    end

   
    local ticket = Player.Functions.GetItemByName(Config.TicketItem)

    if ticket and ticket.amount and ticket.amount > 0 then
       
        if companyId then
            DB.AddToCashRegister(companyId, Config.TicketPrice)
        end

        cb('has_ticket')
    else
        
        local cash = Player.PlayerData.money['cash'] or 0

        if cash >= Config.MarkupPrice then
           
            Player.Functions.RemoveMoney('cash', Config.MarkupPrice, 'train-ticket')
            Player.Functions.AddItem(Config.TicketItem, 1)
            TriggerClientEvent('inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.TicketItem], 'add', 1)

            if companyId then
                DB.AddToCashRegister(companyId, Config.MarkupPrice)
            end
           
            cb('bought_ticket')
        else
            
           
            cb('no_ticket')
        end
    end
end)


RegisterNetEvent('rsg-traintickets:server:removeTicket', function()
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player then return end

    local ticket = Player.Functions.GetItemByName(Config.TicketItem)

    if ticket and ticket.amount and ticket.amount > 0 then
        Player.Functions.RemoveItem(Config.TicketItem, 1)
        TriggerClientEvent('inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.TicketItem], 'remove', 1)
        TriggerClientEvent('rsg-traintickets:client:ticketRemoved', src)
        
    end
end)





AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
end)

