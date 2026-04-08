#if defined _saysounds_included
    #endinput
#endif
#define _saysounds_included

#include <sourcemod>

/**
 * Returns whether a client currently has say sounds enabled.
 *
 * @param client        Client index.
 * @return              True if the client can hear say sounds.
 */
native bool SaySounds_ShouldPlay(int client);

/**
 * Plays a raw sound path to clients who can currently hear say sounds.
 *
 * @param soundPath     Raw sound path relative to `sound/`.
 * @param groupName     Optional say sound group. Use `all` for all groups.
 */
native void SaySounds_PlaySoundToOptedIn(const char[] soundPath, const char[] groupName);

/**
 * Plays a configured say sound command to a target client.
 *
 * `client == 0` broadcasts with normal say sound delivery rules.
 *
 * @param client        Client index, or `0` for broadcast.
 * @param commandName   Configured say sound command, such as `xp_gain`.
 * @return              True if the sound resolved and was emitted to at least one client.
 */
native bool SaySounds_PlayCommand(int client, const char[] commandName);

public SharedPlugin __pl_saysounds =
{
    name = "saysounds",
    file = "saysounds.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_saysounds_SetNTVOptional()
{
    MarkNativeAsOptional("SaySounds_ShouldPlay");
    MarkNativeAsOptional("SaySounds_PlaySoundToOptedIn");
    MarkNativeAsOptional("SaySounds_PlayCommand");
}
#endif
