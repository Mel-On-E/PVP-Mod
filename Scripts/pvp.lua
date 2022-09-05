---@class PVP : ToolClass

PVP = class()
PVP.instance = nil

local hitboxSize = sm.vec3.new(3, 3, 5)/4
local healthRegenPerSecond = 1
local maxHP = 100
local respawnTime = 10

local showHitboxes = true --DEBUG

function PVP:server_onCreate()
    self:sv_init()
end

function PVP:sv_init()
    if PVP.instance and PVP.instance ~= self then return end

    self.sv = {}
    self.sv.hitboxes = {}
    self.sv.playerStats = {}
    self.sv.respawns = {}
    PVP.instance = self
end

function PVP:server_onRefresh()
    self:sv_init()
end

function PVP:server_onFixedUpdate()
    if PVP.instance ~= self then return end

    local function create_hitbox(player)
        self.sv.playerStats[player.id] = {hp = maxHP}

        print("creating hitbox for:", player.name)

        local hitbox = {}
        hitbox.player = player
        hitbox.trigger = sm.areaTrigger.createBox(player.character.worldPosition, hitboxSize/32)
        hitbox.trigger:bindOnProjectile("hitbox_onProjectile", self)
        return hitbox
    end

    update_hitbox_list(self.sv.hitboxes, create_hitbox)

    update_hitbox_positons(self.sv.hitboxes)

    if sm.game.getCurrentTick() % 40 == 0 then
        for _, player in pairs(sm.player.getAllPlayers()) do
            self:sv_updateHP(player, healthRegenPerSecond)
        end
    end

    for k, respawn in pairs(self.sv.respawns) do
        if respawn.time < sm.game.getCurrentTick() then
            local spawnParams = {
                pos = sm.vec3.one(),
                yaw = 0,
                pitch = 0
            }

            if g_spawns then
                spawnParams = g_spawns[respawn.player.id]
            end

            local newChar = sm.character.createCharacter( respawn.player, respawn.player:getCharacter():getWorld(), spawnParams.pos, spawnParams.yaw, spawnParams.pitch )
            respawn.player:setCharacter(newChar)

            self.sv.playerStats[respawn.player.id].hp = maxHP

            sm.effect.playEffect( "Characterspawner - Activate", spawnParams.pos )

            self.sv.respawns[k] = nil
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
    local hp = self.sv.playerStats[player.id].hp
    if hp and hp > 0 then
        self.sv.playerStats[player.id].hp = math.min(math.max(hp + change, 0), maxHP)
        self.network:sendToClient(player, "cl_updateHealthBar", self.sv.playerStats[player.id].hp)

        if self.sv.playerStats[player.id].hp == 0 then
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
    end
end

function PVP.hitbox_onProjectile( self, trigger, hitPos, hitTime, hitVelocity, _, attacker, damage, userData, hitNormal, projectileUuid )
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
    self.cl.hitboxes = {}

    self.cl.hud = sm.gui.createSurvivalHudGui()
    self.cl.hud:setVisible("FoodBar", false)
    self.cl.hud:setVisible("WaterBar", false)
    self.cl.hud:setVisible("BindingPanel", false)
    self.cl.hud:open()
end

function PVP:client_onFixedUpdate()
    if not self.tool:isLocal() then return end

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

    if self.cl and self.cl.death then
        sm.gui.setInteractionText("Respawn in " .. tostring(self.cl.death))
    end
end

function PVP:cl_updateHealthBar(hp)
    if self.cl then
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



--[[ local oldChatMessage = sm.gui.chatMessage

function chatMessageHook(msg)
    oldChatMessage(msg)
    print("be hookin' like the cool kids do")
end

sm.gui.chatMessage = chatMessageHook

print("HOOK SET?") ]]