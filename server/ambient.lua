local RSGCore = exports['rsg-core']:GetCoreObject()
local ambientSpawned = false

lib.callback.register('rsg-railroad:shouldSpawnAmbient', function(source)
    if ambientSpawned then return false end
    ambientSpawned = true
    return true
end)

RegisterNetEvent('rsg-railroad:ambientDespawned', function()
    ambientSpawned = false
end)