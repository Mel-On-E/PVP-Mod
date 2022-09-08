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
    self.sv.hitboxes = {}
    self.sv.respawns = {}

    self.sv.saved = self.storage:load()
    if self.sv.saved == nil then
        self.sv.saved = {}
        self.sv.saved.playerStats = {}
        self.sv.saved.spawnPoints = {}

        self.sv.saved.settings = {}
        self.sv.saved.settings.pvp = true
        self.sv.saved.settings.nameTags = false
        self.sv.saved.settings.teams = {}
    end
    self.storage:save(self.sv.saved)

    self.network:setClientData(self.sv.saved.settings)

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

    update_hitboxes(self.sv.hitboxes)

    if self.sv.saved.settings.pvp and not survivalMode and sm.game.getCurrentTick() % 40 == 0 then
        for _, player in pairs(sm.player.getAllPlayers()) do
            self:sv_updateHP({player = player, change = healthRegenPerSecond})
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

function update_hitboxes(hitboxes)
    for id, hitbox in ipairs(hitboxes) do
        local char = hitbox.player.character
        local newPos = char.worldPosition + 
            char.velocity:safeNormalize(sm.vec3.zero()) *
            char.velocity:length()^0.5/8

        local size = hitboxSize
        if char:isCrouching() then --crouch offset
            size = sm.vec3.new(size.x, size.y, size.z*0.8)
            newPos = newPos + sm.vec3.new(0,0,0.125)
        end

        local lockingInteractable = char:getLockingInteractable()
        if lockingInteractable and lockingInteractable:hasSeat() then --seat offset
            newPos = newPos + sm.vec3.new(0,0,0.125)
        end

        if hitbox.trigger then
            hitbox.trigger:setWorldPosition(newPos)
            hitbox.trigger:setSize(size/2)
        end

        if hitbox.effect then
            hitbox.effect:setPosition(newPos)
            hitbox.effect:setScale(size)
        end
    end
end

function PVP:sv_updateHP(params)
    if not self.sv.saved.settings.pvp then return end

    local player = params.player
    local change = params.change
    local attacker = params.attacker

    if (not params.ignoreSound) and (change < 0 and not player.character:isDowned()) then
        self.network:sendToClients( "cl_damageSound", { event = "impact", pos = player.character.worldPosition, damage = -change * 0.01 } )
    end

    if survivalMode then --SurvivalGame
        if change > 0 then
            sm.event.sendToPlayer(player, "sv_restoreHealth", change)
        else
            sm.event.sendToPlayer(player, "sv_takeDamage", -change)
        end

    else --Custom Health HUD
        if change < 0 then
            local lockingInteractable = player.character:getLockingInteractable()
            if lockingInteractable and lockingInteractable:hasSeat() then
                lockingInteractable:setSeatCharacter( player.character )
            end
        end

        local hp = self.sv.saved.playerStats[player.id].hp
        if hp and hp > 0 then
            self.sv.saved.playerStats[player.id].hp = math.min(math.max(hp + change, 0), maxHP)
            self.network:sendToClient(player, "cl_updateHealthBar", self.sv.saved.playerStats[player.id].hp)

            if self.sv.saved.playerStats[player.id].hp == 0 then
                if type( attacker ) == "Player" then
                    self.network:sendToClients( "cl_n_showMessage", "#ff0000" .. player.name .. "#ffffff was pwned by #00ffff" .. attacker.name )
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
    if not self.sv.saved.settings.pvp then return false end
    
    if isAnyOf( projectileUuid, g_potatoProjectiles ) then
        damage = damage/2
    elseif survivalMode then
        return false
    end
    
    local owner = self:sv_getHitboxOwner(trigger.id)

    self:sv_attack({victim = owner, attacker = attacker, damage = damage})

    return false
end

function PVP:sv_getHitboxOwner(triggerID)
    local owner
    for id, hitbox in ipairs(self.sv.hitboxes) do
        if hitbox.trigger.id == triggerID then
            owner = hitbox.player
            break
        end
    end
    assert(owner, "Couldn't find owner of hitbox")
    return owner
end

function PVP:sv_attack(params)
    local victim = params.victim
    local attacker = params.attacker
    local damage = params.damage

    if victim ~= attacker then
        local friendlyFire = false

        if type(attacker) == "Player" then
            local victimTeam = self.sv.saved.settings.teams[victim.id]
            local attackerTeam = self.sv.saved.settings.teams[attacker.id]
            if victimTeam and (victimTeam == attackerTeam) then
                friendlyFire = true
            end
        end

        if not friendlyFire then
            self:sv_updateHP({player = victim, change = -damage, attacker = attacker, ignoreSound = params.ignoreSound})
        end
    end
end

function PVP:sv_sendAttack(params)
    sm.event.sendToTool(PVP.instance.tool, "sv_attack", params)
end

function PVP:client_onCreate()
    if not self.tool:isLocal() then return end

    sm.gui.chatMessage("#ff0088Thanks for playing with the PVP mod! (0.9)" )

    self.cl = {}
    self.cl.pvp = true
    self.cl.nameTags = false
    self.cl.team = nil
    self.cl.teams = {}

    self.cl.hitboxes = {}
    self.cl.meleeAttacks = {sledgehammer_attack1 = 0, sledgehammer_attack2 = 0}

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
            if hitbox and hitbox.effect and sm.exists(hitbox.effect) then --just wanna make sure, bro
                hitbox.effect:destroy()
            end
        end

        update_hitbox_list(self.cl.hitboxes, create_hitbox, destroy_hitbox)

        update_hitboxes(self.cl.hitboxes)
    end

    --detecting player melee attacks via animation
    local char = sm.localPlayer.getPlayer().character
    if char and getGamemode() ~= "survival" then
        local prevAttacks = self.cl.meleeAttacks

        self.cl.meleeAttacks = {sledgehammer_attack1 = 0, sledgehammer_attack2 = 0}
        for _, anim in ipairs(char:getActiveAnimations()) do
            if anim.name == "sledgehammer_attack1" or anim.name == "sledgehammer_attack2" then
                self.cl.meleeAttacks[anim.name] = prevAttacks[anim.name] + 1
            end
        end

        local hitDelay = 7
        if self.cl.meleeAttacks.sledgehammer_attack1 == hitDelay or self.cl.meleeAttacks.sledgehammer_attack2 == hitDelay then
            --new melee attack
            local Range = 3.0
            local Damage = 20

            local success, result = sm.localPlayer.getRaycast( Range, sm.localPlayer.getRaycastStart(), sm.localPlayer.getDirection() )
            if success then
                if result.type == "character" and result:getCharacter():getPlayer() then
                    self.network:sendToServer("sv_sendAttack", {victim = result:getCharacter():getPlayer(), attacker = sm.localPlayer.getPlayer(), damage = Damage, ignoreSound = true})
                end
            end
        end
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
    if not self.cl then return end --why the fuck does this even happen?

    if self.cl.pvp ~= data.pvp then
        self.cl.pvp = data.pvp
        sm.gui.chatMessage("PVP: " .. (self.cl.pvp and "On" or "Off"))

        if self.cl.hud then
            if self.cl.pvp then
                self.cl.hud:open()
            else
                self.cl.hud:close()
            end
        end
    end

    if self.cl.nameTags ~= data.nameTags then
        self.cl.nameTags = data.nameTags
        sm.gui.chatMessage("Player Names: " .. (self.cl.nameTags and "On" or "Off"))

        self:cl_updateNameTags()
    end

    if self.cl.team ~= data.teams[sm.localPlayer.getPlayer().id] then
        self.cl.team = data.teams[sm.localPlayer.getPlayer().id]
        sm.gui.chatMessage(string.format("Your Team: %s", self.cl.team or "none"))

        self:cl_updateNameTags()
    end
    self.cl.teams = data.teams

    --TODO adjust nametags by team
end

function PVP:cl_updateNameTags()
    local localPlayer = sm.localPlayer.getPlayer()

    for _, player in ipairs(sm.player.getAllPlayers()) do
        if player.character then
            local sameTeam = self.cl.teams[localPlayer.id] == self.cl.teams[player.id]
            local nameTag = self.cl.nameTags and (sameTeam or self.cl.team == nil)
            player.character:setNameTag(nameTag and player.name or "")
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

function PVP:cl_sendAttack(params)
    self.network:sendToServer("sv_sendAttack", params)
end

function PVP:sv_togglePVP()
    self.sv.saved.settings.pvp = not self.sv.saved.settings.pvp
    self.storage:save(self.sv.saved)

    self.network:setClientData(self.sv.saved.settings)
end

function PVP:sv_setSpawnpoint(player)
    local char = player.character
    local yaw = math.atan2( char.direction.y, char.direction.x ) - math.pi / 2
    self.sv.saved.spawnPoints[player.id] = {pos = char.worldPosition, yaw = yaw, pitch = 0}

    self.network:sendToClient(player, "cl_msg", "spawnpoint set")
end

function PVP:sv_toggleNameTags()
    self.sv.saved.settings.nameTags = not self.sv.saved.settings.nameTags
    self.storage:save(self.sv.saved)

    self.network:setClientData(self.sv.saved.settings)
end

function PVP:sv_setTeam(params)
    self.sv.saved.settings.teams[params.player.id] = params.team
    self.storage:save(self.sv.saved)

    self.network:setClientData(self.sv.saved.settings)
end



--HOOKS
local oldBindCommand = sm.game.bindChatCommand

local function bindCommandHook(command, params, callback, help)
    oldBindCommand(command, params, callback, help)
    if not added then
        if sm.isHost then
            oldBindCommand("/pvp", {}, "cl_onChatCommand", "Toggle PVP mod")
            oldBindCommand("/nametags", {}, "cl_onChatCommand", "Toggles player name tags")
        end
        
        if getGamemode() ~= "survival" then
            oldBindCommand("/setspawn", {}, "cl_onChatCommand", "Sets the spawnpoint for your character")
        end

        oldBindCommand("/team", {{ "int", "teamNumber", false }}, "cl_onChatCommand", "Joins team of the number given")
        oldBindCommand("/noteam", {}, "cl_onChatCommand", "Leave all teams")
        
        added = true
    end
    print("be hookin' like the cool kids do")
end

sm.game.bindChatCommand = bindCommandHook


local oldWorldEvent = sm.event.sendToWorld

local function worldEventHook(world, callback, params)
    if params[1] == "/pvp" then
        sm.event.sendToTool(PVP.instance.tool, "sv_togglePVP")
    elseif params[1] == "/setspawn" then
        sm.event.sendToTool(PVP.instance.tool, "sv_setSpawnpoint", params.player)
    elseif params[1] == "/nametags" then
        sm.event.sendToTool(PVP.instance.tool, "sv_toggleNameTags")
    elseif params[1] == "/team" then
        sm.event.sendToTool(PVP.instance.tool, "sv_setTeam", {player = params.player, team = params[2]})
    elseif params[1] == "/noteam" then
        sm.event.sendToTool(PVP.instance.tool, "sv_setTeam", {player = params.player, team = nil})
    else
        oldWorldEvent(world, callback, params)
    end
end

sm.event.sendToWorld = worldEventHook

local oldMeleeAttack = sm.melee.meleeAttack

local function meleeAttackHook(uuid, damage, origin, directionRange, source, delay, power)
    oldMeleeAttack(uuid, damage, origin, directionRange, source, delay, power)

    --print("melee hook")

    local success, result
    if sm.isServerMode() then
        success, result = sm.physics.raycast(origin, origin + directionRange)
    else
       success, result = sm.localPlayer.getRaycast( directionRange:length(), origin, directionRange:normalize() )
    end

    print(success, result.type)

    if not success then return end
    if result.type ~= "character" then return end

    local char = result:getCharacter()
    if not char:getPlayer() then return end

    if getGamemode() == "survival" and type(source) ~= "Player" then return end

    local params = {
        victim = char:getPlayer(),
        attacker = source,
        damage = damage,
        ignoreSound = true
    }

    sm.event.sendToTool(PVP.instance.tool, sm.isServerMode() and "sv_sendAttack" or "cl_sendAttack", params)
end

sm.melee.meleeAttack = meleeAttackHook


local oldExplode = sm.physics.explode

local function explodeHook(position, level, destructionRadius, impulseRadius, magnitude, effectName, ignoreShape, parameters)
    oldExplode(position, level, destructionRadius, impulseRadius, magnitude, effectName, ignoreShape, parameters)

    if getGamemode() == "survival" then return end

    for _, character in ipairs(sm.physics.getSphereContacts(position, destructionRadius).characters) do
        if character:getPlayer() then
            sm.event.sendToTool(PVP.instance.tool, "sv_updateHP", {player = character:getPlayer(), change = -level*2})
        end
    end
end

sm.physics.explode = explodeHook



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

--TODO
--make hp bar update for clients