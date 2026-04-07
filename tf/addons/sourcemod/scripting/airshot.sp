#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <clientprefs>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <morecolors>
#include <whaletracker_api>
#define HEADSHOT_SUPPRESS_WINDOW 0.5
#define AIRSHOT_MIN_HEIGHT 50.0
#define SOUND_AIRSHOT "misc/taps_02.wav"
#define SOUND_AIRSHOT_DOWNLOAD "sound/misc/taps_02.wav"
native void SaySounds_PlaySoundToOptedIn(const char[] soundPath, const char[] groupName);
bool g_bSaySoundsAvailable = false;
Cookie g_hNameColorCookie = null;
int g_iPendingAirshotAttacker[MAXPLAYERS + 1];
float g_fLastHeadshotTime[MAXPLAYERS + 1];
public Plugin myinfo =
{
	name = "[TF2] Airshot",
	author = "Jerry",
	description = "Detects projectile airshot kills for Soldier and Demoman.",
	version = "1.0",
	url = ""
};
public void OnPluginStart()
{
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	g_bSaySoundsAvailable = LibraryExists("saysounds");
	g_hNameColorCookie = FindClientCookie("filter_namecolor");
}

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errlen)
{
	MarkNativeAsOptional("SaySounds_PlaySoundToOptedIn");
	return APLRes_Success;
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "saysounds"))
	{
		g_bSaySoundsAvailable = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "saysounds"))
	{
		g_bSaySoundsAvailable = false;
	}
}

public void OnMapStart()
{
	PrecacheSound(SOUND_AIRSHOT, true);
	AddFileToDownloadsTable(SOUND_AIRSHOT_DOWNLOAD);
}
public void OnClientPutInServer(int client)
{
	ResetAirshotState(client);
}
public void OnClientDisconnect(int client)
{
	ResetAirshotState(client);
}
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!IsValidClient(victim) || !IsValidClient(attacker) || attacker == victim)
	{
		if (IsValidClient(victim))
			ResetAirshotState(victim);
		return;
	}
	if (IsFakeClient(attacker) || IsFakeClient(victim))
	{
		ResetAirshotState(victim);
		return;
	}
	int customkill = event.GetInt("customkill");
	bool isHeadshot = (customkill == TF_CUSTOM_HEADSHOT
		|| customkill == TF_CUSTOM_HEADSHOT_DECAPITATION
		|| customkill == TF_CUSTOM_PENETRATE_HEADSHOT);
	bool isMidairHeadshot = isHeadshot
		&& !(GetEntityFlags(attacker) & FL_ONGROUND)
		&& (DistanceAboveGround(attacker) > AIRSHOT_MIN_HEIGHT);

	if (!isMidairHeadshot)
	{
		g_fLastHeadshotTime[victim] = 0.0;
		return;
	}
	g_fLastHeadshotTime[victim] = GetGameTime();
	g_iPendingAirshotAttacker[victim] = 0;
	char attackerColorTag[40];
	char victimColorTag[40];
	BuildNameColorTag(attacker, attackerColorTag, sizeof(attackerColorTag));
	BuildNameColorTag(victim, victimColorTag, sizeof(victimColorTag));
	CPrintToChatAll("%s%N{default} headshot %s%N{default} while in the air!", attackerColorTag, attacker, victimColorTag, victim);
	if (g_bSaySoundsAvailable)
	{
		SaySounds_PlaySoundToOptedIn(SOUND_AIRSHOT, "all");
	}
	else
	{
		EmitSoundToClient(attacker, SOUND_AIRSHOT);
		EmitSoundToClient(victim, SOUND_AIRSHOT);
	}
	ResetAirshotState(victim);
}

public void WhaleTracker_OnAirshot(int attacker, int victim)
{
	if (!IsValidClient(attacker) || !IsValidClient(victim) || attacker == victim)
		return;
	if (IsFakeClient(attacker) || IsFakeClient(victim))
		return;

	g_iPendingAirshotAttacker[victim] = attacker;
	CreateTimer(0.0, Timer_BroadcastAirshot, GetClientUserId(victim));
}

public Action Timer_BroadcastAirshot(Handle timer, any userid)
{
	int victim = GetClientOfUserId(userid);
	if (!IsValidClient(victim))
		return Plugin_Stop;

	int attacker = g_iPendingAirshotAttacker[victim];
	if (!IsValidClient(attacker) || attacker == victim)
	{
		ResetAirshotState(victim);
		return Plugin_Stop;
	}

	if (g_fLastHeadshotTime[victim] > 0.0
		&& (GetGameTime() - g_fLastHeadshotTime[victim]) <= HEADSHOT_SUPPRESS_WINDOW)
	{
		ResetAirshotState(victim);
		return Plugin_Stop;
	}

	char attackerColorTag[40];
	char victimColorTag[40];
	BuildNameColorTag(attacker, attackerColorTag, sizeof(attackerColorTag));
	BuildNameColorTag(victim, victimColorTag, sizeof(victimColorTag));
	CPrintToChatAll("%s%N{default} airshot %s%N{default}!", attackerColorTag, attacker, victimColorTag, victim);
	if (!IsPlayerAlive(victim))
	{
		if (g_bSaySoundsAvailable)
		{
			SaySounds_PlaySoundToOptedIn(SOUND_AIRSHOT, "all");
		}
		else
		{
			EmitSoundToClient(attacker, SOUND_AIRSHOT);
			EmitSoundToClient(victim, SOUND_AIRSHOT);
		}
	}
	ResetAirshotState(victim);
	return Plugin_Stop;
}
static bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

static void BuildNameColorTag(int client, char[] colorTag, int length)
{
	if (g_hNameColorCookie != null && AreClientCookiesCached(client))
	{
		char cookieValue[32];
		GetClientCookie(client, g_hNameColorCookie, cookieValue, sizeof(cookieValue));
		TrimString(cookieValue);
		ToLowercaseInPlace(cookieValue, sizeof(cookieValue));
		if (cookieValue[0] != '\0')
		{
			Format(colorTag, length, "{%s}", cookieValue);
			return;
		}
	}

	BuildTeamColorTag(client, colorTag, length);
}

static void BuildTeamColorTag(int client, char[] colorTag, int length)
{
	switch (GetClientTeam(client))
	{
		case 2: strcopy(colorTag, length, "{red}");
		case 3: strcopy(colorTag, length, "{blue}");
		default: strcopy(colorTag, length, "{default}");
	}
}

static void ToLowercaseInPlace(char[] buffer, int maxlen)
{
	for (int i = 0; i < maxlen && buffer[i] != '\0'; i++)
	{
		buffer[i] = CharToLower(buffer[i]);
	}
}
static bool IsVictimInAir(int victim)
{
	int flags = GetEntityFlags(victim);
	return !(flags & FL_ONGROUND);
}
static float DistanceAboveGround(int client)
{
	float start[3];
	float end[3];
	GetEntPropVector(client, Prop_Send, "m_vecOrigin", start);
	end[0] = start[0];
	end[1] = start[1];
	end[2] = start[2] - 8192.0;
	Handle trace = TR_TraceRayFilterEx(start, end, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilterPlayers, client);
	if (trace == INVALID_HANDLE)
		return 0.0;
	float hitPos[3];
	TR_GetEndPosition(hitPos, trace);
	CloseHandle(trace);
	return GetVectorDistance(start, hitPos);
}
public bool TraceEntityFilterPlayers(int entity, int contentsMask, any data)
{
	if (entity == data)
		return false;
	return true;
}
static void ResetAirshotState(int client)
{
	g_iPendingAirshotAttacker[client] = 0;
	g_fLastHeadshotTime[client] = 0.0;
}
