

local RSGCore = nil
local isOnTrain = false
local ticketChecked = false


CreateThread(function()
    while RSGCore == nil do
        RSGCore = exports['rsg-core']:GetCoreObject()
        Wait(100)
    end
    
end)


CreateThread(function()
    while RSGCore == nil do
        Wait(100)
    end

    

    while true do
        local sleep = 500
        local ped = PlayerPedId()
        local onTrain = IsPedInAnyTrain(ped)

        if onTrain == 1 or onTrain == true then
            if not ticketChecked then
                
                ticketChecked = true
                isOnTrain = true
                CheckTicket()
            end
        else
            if isOnTrain then
               
                TriggerServerEvent('rsg-traintickets:server:removeTicket')
                ResetState()
            end
        end

        Wait(sleep)
    end
end)


function GetNearestStationCompany()
    local ped = PlayerPedId()
    local train = GetVehiclePedIsIn(ped)

    -- If on a company-owned train, use that company
    if train and DoesEntityExist(train) and ActiveTrain and train == ActiveTrain and ActiveTrainConfig then
        return ActiveTrainConfig.company
    end

    -- Otherwise fall back to nearest station
    local pcoords = GetEntityCoords(ped)
    local nearestDist = math.huge
    local nearestCompany = nil
    for _, station in ipairs(Config.Stations) do
        local dist = GetDistanceBetween(pcoords, station.coords)
        if dist < nearestDist then
            nearestDist = dist
            nearestCompany = station.company
        end
    end
    return nearestCompany
end

function CheckTicket()
    local companyId = GetNearestStationCompany()

    RSGCore.Functions.TriggerCallback('rsg-traintickets:server:useTicket', function(result)
       

        if result == 'has_ticket' then
            lib.notify({
                title = locale('ticket_valid_title'),
                description = locale('ticket_valid_desc'),
                type = 'success',
                position = 'top-right',
                duration = 5000,
            })

        elseif result == 'bought_ticket' then
            lib.notify({
                title = locale('ticket_purchased_title'),
                description = locale('ticket_purchased_desc', string.format('%.2f', Config.MarkupPrice), string.format('%.2f', Config.TicketPrice)),
                type = 'warning',
                position = 'top-right',
                duration = 7000,
            })

        elseif result == 'no_ticket' then
            lib.notify({
                title = locale('no_ticket_title'),
                description = locale('no_ticket_desc', string.format('%.2f', Config.MarkupPrice)),
                type = 'error',
                position = 'top-right',
                duration = 5000,
            })

            KickOffTrain()
        end
    end, companyId)
end


function KickOffTrain()
    CreateThread(function()
        Wait(2000)

        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)

        ClearPedTasksImmediately(ped)
        SetEntityCoords(ped, coords.x + 10.0, coords.y + 10.0, coords.z, false, false, false, false)
        Wait(500)
        PlaceEntityOnGroundProperly(ped)

        ResetState()
    end)
end


RegisterNetEvent('rsg-traintickets:client:ticketRemoved', function()
    lib.notify({
        title = locale('journey_complete_title'),
        description = locale('journey_complete_desc'),
        type = 'success',
        position = 'top-right',
        duration = 5000,
    })
end)

function ResetState()
    isOnTrain = false
    ticketChecked = false
end


AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    ResetState()
end)

