#include <sourcemod>
#include <sdktools>
#include <neotokyo>

#pragma semicolon 1

#define PLUGIN_VERSION "2.0.0"

#define NEO_MAX_PLAYERS 32

#define MAX_SMOKES (NEO_MAX_PLAYERS * 2)
#assert MAX_SMOKES != 0 // because we divide by it

// TODO: These two durations times are eyeballed, for now; should get accurate measurements.
//
// This is the time it takes for an activated smoke to emit smoke
// thick enough to completely block player vision.
#define SMOKE_INITIAL_BLOOM_DELAY_SECS 3.0
// For how long the fully blocking thick smoke phase lasts.
#define SMOKE_FULLY_BLOOMED_DURATION_SECS 19.0
// Radius of the fully vision-blocking smoke bloom sphere.
#define SMOKE_RADIUS 180.0

enum {
    REGEN_STYLE_SUPPORT_SELFHEAL = 0,
    REGEN_STYLE_SMOKE_HEAL = 1,

    REGEN_STYLE_ENUM_COUNT,
    REGEN_STYLE_MAX_VALUE = REGEN_STYLE_ENUM_COUNT - 1
};

public Plugin myinfo =
{
    name = "NEOTOKYO° Support Regen",
    author = "Agiel",
    description = "Gives Supports regenrating HP",
    version = PLUGIN_VERSION,
    url = "https://github.com/Agiel/nt-support-regen"
};

ConVar g_cvSupportRegen;
ConVar g_cvSupportRegenSpeed;
ConVar g_cvSupportRegenCooldown;
ConVar g_cvRegenStyle;

float g_fLastDamage[NEO_MAX_PLAYERS+1];
float g_fPlayerHealth[NEO_MAX_PLAYERS+1] = { 100.0, ... }; // TODO: confirm this init style behaves consistently (and correctly) in the 1.7-1.12 range

int g_smokes[MAX_SMOKES] = { INVALID_ENT_REFERENCE, ... };
int g_smokes_head;
float g_smokes_prevPos[MAX_SMOKES][3];
float g_healspots[MAX_SMOKES][3];
float g_healspots_startTime[MAX_SMOKES];
int g_healspots_head;

public void OnPluginStart()
{
    g_cvRegenStyle = CreateConVar("sm_support_regen_style", "1", "Style of regen to use. 0: Supports self-heal after damage cooldown. 1: Smoke grenades will heal any players within the smoke's sphere of influence.", _, true, 0.0, true, float(REGEN_STYLE_MAX_VALUE));
    g_cvSupportRegen = CreateConVar("sm_support_regen", "80", "Regen up to how much HP.", _, true, 0.0, true, 100.0);
    g_cvSupportRegenSpeed = CreateConVar("sm_support_regen_speed", "2", "How much HP to regen per second.", _, true, 0.0, true, 100.0);
    g_cvSupportRegenCooldown = CreateConVar("sm_support_regen_cooldown", "10", "How many seconds after taking damage the regen kicks in.", _, true, 0.0, true, 60.0);

    for (int i = 0; i < MAX_SMOKES; ++i)
    {
        g_healspots[i] = NULL_VECTOR;
    }

    HookEvent("game_round_start", Event_Round_Start);
    HookEvent("player_hurt", Event_Player_Hurt);

    AutoExecConfig();

    // TODO: should be per-tick, if performant enough.
    // We're scaling by this interval so the average healing rate should still be correct.
#define MY_TIMER_INTERVAL 0.1
    CreateTimer(MY_TIMER_INTERVAL, Timer_CheckSmokes, _, TIMER_REPEAT);
}

public Action Timer_CheckSmokes(Handle timer)
{
    if (g_cvRegenStyle.IntValue != REGEN_STYLE_SMOKE_HEAL)
    {
        return Plugin_Continue;
    }

    float current_pos[3];
    int i;
    for (i = 0; i < MAX_SMOKES; ++i)
    {
        int ent = EntRefToEntIndex(g_smokes[i]);
        if (ent == INVALID_ENT_REFERENCE)
            continue;

        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", current_pos);

        if (!VectorsEqual(current_pos, NULL_VECTOR))
        {
            if (VectorsEqual(current_pos, g_smokes_prevPos[i], 0.1))
            {
                g_smokes_prevPos[i] = NULL_VECTOR;
                g_smokes[i] = INVALID_ENT_REFERENCE;
                g_healspots[g_healspots_head] = current_pos;
                g_healspots_startTime[g_healspots_head] = GetGameTime();
                g_healspots_head = (g_healspots_head + 1) % MAX_SMOKES;
                continue;
            }
        }

        g_smokes_prevPos[i] = current_pos;
    }

    float regen = g_cvSupportRegen.FloatValue;
    float speed = g_cvSupportRegenSpeed.FloatValue;
    float cooldown = g_cvSupportRegenCooldown.FloatValue;
    float time = GetGameTime();
    float delta_time, distance;

    for (i = 0; i < MAX_SMOKES; ++i)
    {
        // Using NULL_VECTOR as special value to mean "inactive array index" here.
        if (VectorsEqual(g_healspots[i], NULL_VECTOR))
        {
            continue;
        }

        delta_time = time - g_healspots_startTime[i];
        // The smoke has been activated, but hasn't fully bloomed yet.
        if (delta_time < SMOKE_INITIAL_BLOOM_DELAY_SECS)
        {
            continue;
        }
        // The smoke is beginning to fade away.
        else if (delta_time > SMOKE_FULLY_BLOOMED_DURATION_SECS)
        {
            g_healspots[i] = NULL_VECTOR;
            continue;
        }

        for (int client = 1; client <= MaxClients; ++client)
        {
            if (!IsValidClient(client) || !IsPlayerAlive(client))
            {
                continue;
            }
            GetClientAbsOrigin(client, current_pos);
            // Squared Euclidean distance because it's faster to calculate
            distance = GetVectorDistance(current_pos, g_healspots[i], true);
            if (distance <= SMOKE_RADIUS * SMOKE_RADIUS)
            {
                if (g_fPlayerHealth[client] <= regen &&
                    g_fLastDamage[client] + cooldown < GetGameTime())
                {
                    g_fPlayerHealth[client] += speed * MY_TIMER_INTERVAL;
                    SetEntityHealth(client, RoundToFloor(g_fPlayerHealth[client]));
                }
            }
        }
    }

    return Plugin_Continue;
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "smokegrenade_projectile"))
    {
        TrackSmoke(EntIndexToEntRef(entity));
    }
}

void TrackSmoke(int entref)
{
    g_smokes[g_smokes_head] = entref;
    g_smokes_head = (g_smokes_head + 1) % MAX_SMOKES;
}

stock bool VectorsEqual(const float v1[3], const float v2[3], const float max_ulps = 0.0)
{
    // Needs to exactly equal.
    if (max_ulps == 0) {
        return v1[0] == v2[0] && v1[1] == v2[1] && v1[2] == v2[2];
    }
    // Allow an inaccuracy of size max_ulps.
    else {
        if (FloatAbs(v1[0] - v2[0]) > max_ulps) { return false; }
        if (FloatAbs(v1[1] - v2[1]) > max_ulps) { return false; }
        if (FloatAbs(v1[2] - v2[2]) > max_ulps) { return false; }
        return true;
    }
}

public void OnClientDisconnect(int client)
{
    g_fPlayerHealth[client] = 100.0;
}

public void OnMapEnd()
{
    for (int i = 0; i < MAX_SMOKES; ++i)
    {
        g_healspots[i] = NULL_VECTOR;
    }
}

public void OnGameFrame()
{
    if (g_cvRegenStyle.IntValue != REGEN_STYLE_SUPPORT_SELFHEAL)
    {
        return;
    }

    float regen = g_cvSupportRegen.FloatValue;
    float speed = g_cvSupportRegenSpeed.FloatValue;
    float cooldown = g_cvSupportRegenCooldown.FloatValue;

    for(int i = 1; i <= MaxClients; i++)
    {
        if(!IsValidClient(i) || !IsPlayerAlive(i))
            continue;

        if (GetPlayerClass(i) == CLASS_SUPPORT)
        {
            if (g_fPlayerHealth[i] <= regen && g_fLastDamage[i] + cooldown < GetGameTime())
            {
                g_fPlayerHealth[i] += speed * GetTickInterval();
                SetEntityHealth(i, RoundToFloor(g_fPlayerHealth[i]));
            }
        }
    }
}

public void Event_Round_Start(Event event, const char[] name, bool dontBroadcast)
{
    for(int i = 1; i <= MaxClients; i++)
    {
        g_fPlayerHealth[i] = 100.0;
    }
}

public void Event_Player_Hurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int health = event.GetInt("health");
    g_fLastDamage[victim] = GetGameTime();
    g_fPlayerHealth[victim] = float(health);
}
