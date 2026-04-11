#if defined _whaletracker_api_included
  #endinput
#endif
#define _whaletracker_api_included

#include <sourcemod>

/**
 * Returns a client's cumulative tracked kills.
 *
 * @param client        Client index.
 * @return              Cumulative kills, or 0 if unavailable.
 */
native int WhaleTracker_GetCumulativeKills(int client);

/**
 * Returns whether a client's WhaleTracker stats are loaded and ready.
 *
 * @param client        Client index.
 * @return              True if ready.
 */
native bool WhaleTracker_AreStatsLoaded(int client);

/**
 * Returns a client's current Whale Points total.
 *
 * @param client        Client index.
 * @return              Whale Points, or 0 if unavailable.
 */
native int WhaleTracker_GetWhalePoints(int client);

/**
 * Returns whether a client is the stored MVP for their current team this round.
 *
 * @param client        Client index.
 * @return              True if current round MVP.
 */
native bool WhaleTracker_IsCurrentRoundMvp(int client);

/**
 * Applies bonus points with full WhaleTracker behavior.
 *
 * @param client        Client index.
 * @param points        Points delta. Negative spends.
 * @param playSound     Play  through SaySounds.
 * @param chatAlert     Print BP chat line.
 * @param randomChance  Chance, clamped to 0.1..1.0.
 * @param type          Message type key.
 * @param target        Optional target client.
 * @param delay         Delay in seconds. 0.0 = immediate.
 * @return              True on success.
 */
native bool WhaleTracker_ApplyBonusPoints(int client, int points, bool playSound, bool chatAlert, float randomChance, const char[] type, int target = 0, float delay = 3.0);

/**
 * API convenience wrapper.
 */
stock bool ApplyBonusPoints(int client, int points = 1, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0, float delay = 3.0)
{
    return WhaleTracker_ApplyBonusPoints(client, points, playSound, chatAlert, randomChance, type, target, delay);
}

/**
 * Resolves the best recorded name for a SteamID64.
 *
 * Lookup order:
 * 1. Connected live client name
 * 2. whaletracker.cached_personaname
 * 3. whaletracker.personaname
 * 4. whaletracker_points_cache.name
 *
 * @param steamId64     SteamID64 to look up.
 * @param buffer        Output buffer.
 * @param maxlen        Output buffer size.
 * @return              True if a non-empty name was found.
 */
native bool WhaleTracker_GetLastRecordedName(const char[] steamId64, char[] buffer, int maxlen);

/**
 * Fired when WhaleTracker records an airshot.
 *
 * @param attacker      Attacker client index.
 * @param victim        Victim client index.
 */
forward void WhaleTracker_OnAirshot(int attacker, int victim);
