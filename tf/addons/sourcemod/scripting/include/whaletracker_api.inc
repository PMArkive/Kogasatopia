#if defined _whaletracker_api_included
  #endinput
#endif
#define _whaletracker_api_included

#include <sourcemod>

native int WhaleTracker_GetCumulativeKills(int client);
native bool WhaleTracker_AreStatsLoaded(int client);
native int WhaleTracker_GetWhalePoints(int client);
native bool WhaleTracker_ApplyBonusPoints(int client, int points, bool playSound, bool chatAlert, float randomChance, const char[] type, int target = 0, float delay = 3.0);

stock bool ApplyBonusPoints(int client, int points = 1, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0, float delay = 3.0)
{
    return WhaleTracker_ApplyBonusPoints(client, points, playSound, chatAlert, randomChance, type, target, delay);
}

native bool WhaleTracker_GetLastRecordedName(const char[] steamId64, char[] buffer, int maxlen);
forward void WhaleTracker_OnAirshot(int attacker, int victim);
