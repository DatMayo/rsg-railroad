local RSGCore = exports['rsg-core']:GetCoreObject()

---------------------------------------------------------------
-- CALLBACKS
---------------------------------------------------------------
lib.callback.register('rsg-railroad:getEmployees', function(source, companyId)
    return DB.GetEmployeesByCompany(companyId)
end)

lib.callback.register('rsg-railroad:getPendingApplications', function(source, companyId)
    return DB.GetPendingApplications(companyId)
end)

lib.callback.register('rsg-railroad:getMyEmployment', function(source)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then return {} end
    return DB.GetPlayerEmployment(Player.PlayerData.citizenid)
end)

---------------------------------------------------------------
-- APPLY AS DRIVER
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:applyAsDriver', function(companyId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local charinfo = Player.PlayerData.charinfo

    -- Check company is owned
    local ownership = DB.GetCompanyOwnership(companyId)
    if not ownership then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('company_no_owner'), type = 'error', duration = 5000 })
        return
    end

    -- Check not already applied/employed
    local existing = DB.GetEmployeeByIds(companyId, citizenid)
    if existing then
        local msg = existing.status == 'pending' and locale('application_pending') or locale('already_employed')
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = msg, type = 'error', duration = 5000 })
        return
    end

    -- Check player doesn't own this company
    if ownership.owner_citizenid == citizenid then
        TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('own_this_company'), type = 'error', duration = 5000 })
        return
    end

    DB.ApplyAsDriver(companyId, citizenid, charinfo.firstname or '', charinfo.lastname or '')
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('application_submitted'), type = 'success', duration = 7000 })

    Webhook.SendFields('employees', 'Driver Application', {
        { 'Applicant', GetPlayerFullName(Player) .. ' (' .. citizenid .. ')' },
        { 'Company', Config.Companies[companyId] and Config.Companies[companyId].label or companyId },
    }, 'info')

    -- Notify owner if online
    local ownerPlayer = RSGCore.Functions.GetPlayerByCitizenId(ownership.owner_citizenid)
    if ownerPlayer then
        local applicantName = (charinfo.firstname or '') .. ' ' .. (charinfo.lastname or '')
        local companyLabel = Config.Companies[companyId] and Config.Companies[companyId].label or companyId
        TriggerClientEvent('ox_lib:notify', ownerPlayer.PlayerData.source, {
            title = companyLabel,
            description = locale('driver_applied_notify', applicantName),
            type = 'inform',
            duration = 10000,
        })
    end
end)

---------------------------------------------------------------
-- APPROVE DRIVER
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:approveDriver', function(companyId, employeeId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    -- Verify caller is owner
    local ownership = DB.GetCompanyOwnership(companyId)
    if not ownership or ownership.owner_citizenid ~= Player.PlayerData.citizenid then return end

    DB.ApproveEmployee(employeeId)

    -- Ensure the driver has a company membership row for XP/rank tracking
    local employees = DB.GetEmployeesByCompany(companyId)
    for _, emp in ipairs(employees) do
        if emp.id == employeeId then
            DB.EnsureCompanyMembership(emp.citizenid, companyId)
            break
        end
    end

    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('driver_approved'), type = 'success', duration = 5000 })

    Webhook.SendFields('employees', 'Driver Approved', {
        { 'Approved By', GetPlayerFullName(Player) },
        { 'Company', Config.Companies[companyId] and Config.Companies[companyId].label or companyId },
    }, 'success')

    -- Notify the driver if online
    local employees = DB.GetEmployeesByCompany(companyId)
    for _, emp in ipairs(employees) do
        if emp.id == employeeId then
            local driverPlayer = RSGCore.Functions.GetPlayerByCitizenId(emp.citizenid)
            if driverPlayer then
                local companyLabel = Config.Companies[companyId] and Config.Companies[companyId].label or companyId
                TriggerClientEvent('ox_lib:notify', driverPlayer.PlayerData.source, {
                    title = companyLabel,
                    description = locale('application_approved_notify'),
                    type = 'success',
                    duration = 10000,
                })
            end
            break
        end
    end
end)

---------------------------------------------------------------
-- REJECT DRIVER
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:rejectDriver', function(companyId, employeeId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local ownership = DB.GetCompanyOwnership(companyId)
    if not ownership or ownership.owner_citizenid ~= Player.PlayerData.citizenid then return end

    DB.RejectEmployee(employeeId)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('application_rejected'), type = 'inform', duration = 5000 })

    Webhook.SendFields('employees', 'Driver Application Rejected', {
        { 'Rejected By', GetPlayerFullName(Player) },
        { 'Company', Config.Companies[companyId] and Config.Companies[companyId].label or companyId },
    }, 'warn')
end)

---------------------------------------------------------------
-- FIRE DRIVER
---------------------------------------------------------------
RegisterNetEvent('rsg-railroad:fireDriver', function(companyId, employeeId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local ownership = DB.GetCompanyOwnership(companyId)
    if not ownership or ownership.owner_citizenid ~= Player.PlayerData.citizenid then return end

    -- Get employee info for notification
    local employees = DB.GetEmployeesByCompany(companyId)
    local firedCid = nil
    local firedName = ''
    for _, emp in ipairs(employees) do
        if emp.id == employeeId then
            firedCid = emp.citizenid
            firedName = (emp.firstname or '') .. ' ' .. (emp.lastname or '')
            break
        end
    end

    DB.FireEmployee(employeeId)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('driver_fired', firedName), type = 'success', duration = 5000 })

    Webhook.SendFields('employees', 'Driver Fired', {
        { 'Fired By', GetPlayerFullName(Player) },
        { 'Company', Config.Companies[companyId] and Config.Companies[companyId].label or companyId },
        { 'Driver', firedName },
    }, 'error')

    -- Notify fired player if online
    if firedCid then
        local firedPlayer = RSGCore.Functions.GetPlayerByCitizenId(firedCid)
        if firedPlayer then
            local companyLabel = Config.Companies[companyId] and Config.Companies[companyId].label or companyId
            TriggerClientEvent('ox_lib:notify', firedPlayer.PlayerData.source, {
                title = companyLabel,
                description = locale('fired_notify'),
                type = 'error',
                duration = 10000,
            })
        end
    end
end)

---------------------------------------------------------------
-- EMPLOYEE XP + RANK UP (called from missions)
---------------------------------------------------------------
function AddDriverXP(src, companyId, citizenid, xpAmount)
    local employee = DB.GetEmployeeByIds(companyId, citizenid)
    if not employee or employee.status ~= 'approved' then return end

    DB.AddEmployeeXP(employee.id, xpAmount)

    -- Check rank up
    local newXP = employee.xp + xpAmount
    local currentRank = employee.rank
    local newRank = currentRank

    for rank = 5, 1, -1 do
        if newXP >= Config.Ranks[rank].xpRequired then
            newRank = rank
            break
        end
    end

    if newRank > currentRank then
        DB.SetEmployeeRank(employee.id, newRank)
        local rankLabel = Config.Ranks[newRank].label
        local companyLabel = Config.Companies[companyId] and Config.Companies[companyId].label or companyId
        TriggerClientEvent('ox_lib:notify', src, {
            title = locale('notify_title'),
            description = locale('rank_up', rankLabel, companyLabel),
            type = 'success',
            duration = 8000,
        })

        -- Rank reward
        if Config.CompanyRankRewards[newRank] then
            local reward = Config.CompanyRankRewards[newRank]
            if reward.cashReward > 0 then
                local Player = RSGCore.Functions.GetPlayer(src)
                if Player then
                    Player.Functions.AddMoney('cash', reward.cashReward)
                    TriggerClientEvent('ox_lib:notify', src, { title = locale('notify_title'), description = locale('rank_reward', reward.cashReward), type = 'success', duration = 5000 })
                end
            end
        end
    end
end
