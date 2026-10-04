-- gamemodes/kcRPclient/forge_register.lua
-- Relais des demandes de fermeture du registre vers le serveur.

function OnWebMessage(frame, data)
  if frame ~= "forge-register" then
    return
  end

  Log("Forge register Web message:", tostring(data))

  if data and data.action == "close" then
    SendServerEvent("forge_register_close")
  end
end