dofile( "$SURVIVAL_DATA/Scripts/game/survival_projectiles.lua" )
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )

---@class PVP : ToolClass

PVP = class()
PVP.instance = nil

local hitboxSize = sm.vec3.new(3, 3, 5)/4
local healthRegenPerSecond = 1
local maxHP = 100
local respawnTime = 10

local showHitboxes = true --DEBUG
local survivalMode = false

function PVP:server_onCreate()
    self:sv_init()
end

function PVP:sv_init()
    if PVP.instance and PVP.instance ~= self then return end

    self.sv = {}
    self.sv.enablePVP = true
    self.sv.hitboxes = {}
    self.sv.respawns = {}

    self.sv.saved = self.storage:load()
    if self.sv.saved == nil then
        self.sv.saved = {}
        self.sv.saved.playerStats = {}
        self.sv.saved.spawnPoints = {}
    end
    self.storage:save(self.sv.saved)

    self.network:setClientData({pvp = self.sv.enablePVP})

    PVP.instance = self
end

function PVP:server_onRefresh()
    self:sv_init()
end

function PVP:server_onFixedUpdate()
    if PVP.instance ~= self then return end

    if getGamemode() == "survival" then
        survivalMode = true
    end

    local function create_hitbox(player)
        self.sv.saved.playerStats[player.id] = self.sv.saved.playerStats[player.id] or {hp = maxHP}

        local hitbox = {}
        hitbox.player = player
        hitbox.trigger = sm.areaTrigger.createBox(hitboxSize/2, player.character.worldPosition)
        hitbox.trigger:bindOnProjectile("sv_hitboxOnProjectile", self)
        return hitbox
    end

    update_hitbox_list(self.sv.hitboxes, create_hitbox)

    update_hitbox_positons(self.sv.hitboxes)

    if self.sv.enablePVP and not survivalMode and sm.game.getCurrentTick() % 40 == 0 then
        for _, player in pairs(sm.player.getAllPlayers()) do
            self:sv_updateHP(player, healthRegenPerSecond)
        end
    end

    for k, respawn in pairs(self.sv.respawns) do
        if respawn.time < sm.game.getCurrentTick() then
            local spawnParams = self.sv.saved.spawnPoints[respawn.player.id] or {
                pos = sm.vec3.one(),
                yaw = 0,
                pitch = 0 }

            local newChar = sm.character.createCharacter( respawn.player, respawn.player:getCharacter():getWorld(), spawnParams.pos, spawnParams.yaw, spawnParams.pitch )
            respawn.player:setCharacter(newChar)

            sm.effect.playEffect( "Characterspawner - Activate", spawnParams.pos )

            self.sv.respawns[k] = nil

            self.sv.saved.playerStats[respawn.player.id].hp = maxHP
            self.storage:save(self.sv.saved)
        end
    end
end

function update_hitbox_list(list, createFunction, destroyFunction )
    for _, player in pairs(sm.player.getAllPlayers()) do
        local character = player.character

        if list[player.id] and not character then
            if destroyFunction then
                destroyFunction(list[player.id].hitbox)
            end
            list[player.id] = nil

        elseif not list[player.id] and character then
            list[player.id] = createFunction(player)
        end
    end
end

function update_hitbox_positons(hitboxes)
    for id, hitbox in ipairs(hitboxes) do
        local newPos = hitbox.player.character.worldPosition
        local vel = hitbox.player.character.velocity
        newPos = newPos + vel:safeNormalize(sm.vec3.zero())*vel:length()^0.5/8

        if hitbox.trigger then
            hitbox.trigger:setWorldPosition(newPos)
        end

        if hitbox.effect then
            hitbox.effect:setPosition(newPos)
        end
    end
end

function PVP:sv_updateHP(player, change, attacker)
    if not self.sv.enablePVP then return end

    if change < 0 and not player.character:isDowned() then
        self.network:sendToClients( "cl_damageSound", { event = "impact", pos = player.character.worldPosition, damage = -change * 0.01 } )
    end

    if survivalMode then --SurvivalGame
        if change > 0 then
            sm.event.sendToPlayer(player, "sv_restoreHealth", change)
        else
            sm.event.sendToPlayer(player, "sv_takeDamage", -change)
        end

    else --Custom Health HUD
        local hp = self.sv.saved.playerStats[player.id].hp
        if hp and hp > 0 then
            self.sv.saved.playerStats[player.id].hp = math.min(math.max(hp + change, 0), maxHP)
            self.network:sendToClient(player, "cl_updateHealthBar", self.sv.saved.playerStats[player.id].hp)

            if self.sv.saved.playerStats[player.id].hp == 0 then
                if type( attacker ) == "Player" then
                    self.network:sendToClients( "cl_n_showMessage", "#ff0000" .. player.name .. "#ffffff was killed by #00ffff" .. attacker.name )
                else
                    self.network:sendToClients( "cl_n_showMessage", "#ff0000".. player.name .. " #ffffffdied " )
                end

                player.character:setTumbling(true)
                player.character:setDowned(true)

                self.sv.respawns[#self.sv.respawns+1] = {player = player, time = sm.game.getCurrentTick() + respawnTime*40}
                self.network:sendToClient(player, "cl_death")
            end

            self.storage:save(self.sv.saved)
        end
    end
end

function PVP.sv_hitboxOnProjectile( self, trigger, hitPos, hitTime, hitVelocity, _, attacker, damage, userData, hitNormal, projectileUuid )
    if not self.sv.enablePVP then return false end
    
    if isAnyOf( projectileUuid, g_potatoProjectiles ) then
        damage = damage/2

        if survivalMode then
            return
        end
    end
    
    local owner
    for id, hitbox in ipairs(self.sv.hitboxes) do
        if hitbox.trigger.id == trigger.id then
            owner = hitbox.player
            break
        end
    end
    assert(owner, "Couldn't find owner of hitbox")

    if owner ~= attacker then
        sm.gui.chatMessage("#ff0000Ouch!")
        self:sv_updateHP(owner, -damage, attacker)
    end

    return false
end

function PVP:client_onCreate()
    if not self.tool:isLocal() then return end

    sm.gui.chatMessage("#ff0088Thanks for playing with the PVP mod! (0.9)" )

    self.cl = {}
    self.cl.enablePVP = true
    self.cl.hitboxes = {}

    self.cl.hud = sm.gui.createSurvivalHudGui()
    self.cl.hud:setVisible("FoodBar", false)
    self.cl.hud:setVisible("WaterBar", false)
    self.cl.hud:setVisible("BindingPanel", false)
    self.cl.hud:open()
end

function PVP:client_onFixedUpdate()
    if not self.tool:isLocal() then return end

    if getGamemode() == "survival" then
        survivalMode = true
    end

    if self.cl.death and sm.game.getCurrentTick()%40 == 0 then
        self.cl.death = math.max(self.cl.death-1, 0)
        
        if self.cl.death == 0 then
            self.cl.death = nil
        end
    end

    if showHitboxes then
        local function create_hitbox(player)
            local hitbox = {}
            hitbox.player = player

            hitbox.effect = sm.effect.createEffect("ShapeRenderable")
            hitbox.effect:setParameter("uuid", sm.uuid.new("5f41af56-df4c-4837-9b3c-10781335757f"))
            hitbox.effect:setParameter("color", sm.color.new(1,1,1))
            hitbox.effect:setScale(hitboxSize)
            hitbox.effect:start()
            return hitbox
        end

        local function destroy_hitbox(hitbox)
            hitbox.effect:destroy()
        end

        update_hitbox_list(self.cl.hitboxes, create_hitbox, destroy_hitbox)


        update_hitbox_positons(self.cl.hitboxes)
    end
end

function PVP:client_onUpdate()
    if not self.tool:isLocal() then return end

    if self.cl then
        if self.cl.death then
            sm.gui.setInteractionText("Respawn in " .. tostring(self.cl.death))
        end

        if self.cl.hud and survivalMode then
            self.cl.hud:destroy()
            self.cl.hud = nil
        end
    end
end

function PVP:client_onClientDataUpdate(data)
    if self.cl.enablePVP ~= data.pvp then
        self.cl.enablePVP = data.pvp
        sm.gui.chatMessage("PVP: " .. (self.cl.enablePVP and "On" or "Off"))

        if self.cl.hud then
            if self.cl.enablePVP then
                self.cl.hud:open()
            else
                self.cl.hud:close()
            end
        end
    end
end

function PVP:cl_updateHealthBar(hp)
    if self.cl and self.cl.hud then
        self.cl.hud:setSliderData( "Health", maxHP * 10 + 1, hp * 10 )
    end
end

function PVP:cl_n_showMessage(msg)
	sm.gui.chatMessage(msg)
end

function PVP:cl_death()
    if self.cl then
        self.cl.death = respawnTime
    end
end

function PVP:cl_damageSound(params)
    sm.event.sendToPlayer(sm.localPlayer.getPlayer(), "cl_n_onEvent", params)
end

function PVP:cl_msg(msg)
    sm.gui.chatMessage(msg)
end

function PVP:sv_togglePVP()
    self.sv.enablePVP = not self.sv.enablePVP
    self.network:setClientData({pvp = self.sv.enablePVP})
end

function PVP:sv_setSpawnpoint(player)
    local char = player.character
    local yaw = math.atan2( char.direction.y, char.direction.x ) - math.pi / 2
    self.sv.saved.spawnPoints[player.id] = {pos = char.worldPosition, yaw = yaw, pitch = 0}

    self.network:sendToClient(player, "cl_msg", "spawnpoint set")
end




--HOOKS
local oldBindCommand = sm.game.bindChatCommand

function bindCommandHook(command, params, callback, help)
    oldBindCommand(command, params, callback, help)
    if not added then
        if sm.isHost then
            oldBindCommand("/pvp", {}, "cl_onChatCommand", "toggle pvp mod")
        end
        
        if getGamemode() ~= "survival" then
            oldBindCommand("/setspawn", {}, "cl_onChatCommand", "Sets the spawnpoint for your character")
        end
        
        added = true
    end
    print("be hookin' like the cool kids do")
end

sm.game.bindChatCommand = bindCommandHook


local oldWorldEvent = sm.event.sendToWorld

function worldEventHook(world, callback, params)
    if params[1] == "/pvp" then
        sm.event.sendToTool(PVP.instance.tool, "sv_togglePVP")
    elseif params[1] == "/setspawn" then
        sm.event.sendToTool(PVP.instance.tool, "sv_setSpawnpoint", params.player)
    else
        oldWorldEvent(world, callback, params)
    end
end

sm.event.sendToWorld = worldEventHook


--helper functions
function getGamemode()
    --TechnologicNick is a life-saver!
    if sm.event.sendToGame("cl_onClearConfirmButtonClick", {}) then
        return "creative"
    elseif sm.event.sendToGame("sv_e_setWarehouseRestrictions", {}) then
        return "survival"
    elseif sm.event.sendToGame("server_getLevelUuid", {}) then
        return "challenge"
    end

    return "unknown"
end