// Whale scramble vote helper (NativeVotes)
#include <sourcemod>
#include <morecolors>
#include <nativevotes>
#include <tf2_stocks>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

native int FilterAlerts_SuppressTeamAlertWindow(float seconds);
native bool Filters_GetChatName(int client, char[] buffer, int maxlen);

static const char SCRAMBLE_COMMANDS[][] =
{
    "sm_scramble",
    "sm_scwamble",
    "sm_sc",
    "sm_scram",
    "sm_shitteam"
};

static const char SCRAMBLE_KEYWORDS[][] =
{
    "scramble",
    "scwamble",
    "sc",
    "scram",
    "shitteam"
};

bool g_bPlayerVoted[MAXPLAYERS + 1];
int g_iVoteRequests = 0;
bool g_bVoteRunning = false;
bool g_bNativeVotes = false;
bool g_bVoteAllowLowPop = false;
bool scrambleCooldown = false;
NativeVote g_hVote = null;
Handle g_hScrambleCooldownTimer = null;
GameData g_hWhaleScrambleGameData = null;
DynamicHook g_hHandleScrambleTeamsHook = null;
int g_iHandleScrambleTeamsHookId = INVALID_HOOK_ID;
Handle g_hHookRetryTimer = null;
Handle g_hSetScrambleTeamsCall = null;
Handle g_hChangeTeamCall = null;
ConVar g_hMpScrambleteamsAuto = null;
ConVar g_hSvVoteIssueScrambleAllowed = null;
bool g_bPluginScramblePending = false;
bool g_bQueuedWhaleScramble = false;
bool g_bPendingScrambleAllowEngineFallback = false;
bool g_bBetweenRounds = false;
int g_iPendingScrambleIssuerUserId = 0;
bool g_bPendingScrambleBroadcastFailures = false;
bool g_bPendingScrambleAllowLowPop = true;
bool g_bHandlingEngineScramble = false;
ConVar g_hLogEnabled = null;
ConVar g_hAutoRounds = null;
ConVar g_hVoteTime = null;
ConVar g_hCountBots = null;
ConVar g_hTopSwap = null;
ConVar g_hRandom = null;
int g_iRoundsSinceAuto = 0;
int g_iEngineAutoScrambleRounds = 0;
int g_iRoundsSinceEngineAuto = 0;
char g_sLogPath[PLATFORM_MAX_PATH];
StringMap g_hScrambleImmunity = null;

#define TEAM_RED  2
#define TEAM_BLU  3
#define MAX_TOP_SWAP  4
#define MAX_RANDOM_SWAP  5
#define MAX_SWAP_BUFFER  MAX_RANDOM_SWAP

public Plugin myinfo =
{
    name = "whalescramble",
    author = "Hombre",
    description = "Player-triggered whale scramble vote helper",
    version = "1.1.0",
    url = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("FilterAlerts_SuppressTeamAlertWindow");
    MarkNativeAsOptional("Filters_GetChatName");
    MarkNativeAsOptional("DynamicHook.DynamicHook");
    MarkNativeAsOptional("DynamicHook.HookGamerules");
    return APLRes_Success;
}

public void OnPluginStart()
{
    UpdateNativeVotes();
    InitHandleScrambleTeamsHook();
    g_hLogEnabled = CreateConVar("sm_whalescramble_log", "1", "Enable whalescramble debug logging.", _, true, 0.0, true, 1.0);
    BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/whalescramble.log");
    LogWhale("Plugin started.");
    g_hAutoRounds = CreateConVar("votescramble_rounds", "2", "Automatically start a scramble vote every X rounds. 0/1 disables auto vote.", _, true, 0.0, true, 100.0);
    g_hVoteTime = CreateConVar("votescramble_votetime", "4", "Scramble vote duration in seconds.", _, true, 1.0, true, 30.0);
    g_hCountBots = CreateConVar("whalescramble_count_bots", "0", "Include bots when selecting whale scramble targets.", _, true, 0.0, true, 1.0);
    g_hTopSwap = CreateConVar("sm_ws_topswap", "0", "Enable topswap scramble mode.", _, true, 0.0, true, 1.0);
    g_hRandom = CreateConVar("sm_ws_random", "1", "Enable random scramble mode.", _, true, 0.0, true, 1.0);
    g_hMpScrambleteamsAuto = FindConVar("mp_scrambleteams_auto");
    g_hSvVoteIssueScrambleAllowed = FindConVar("sv_vote_issue_scramble_teams_allowed");
    g_hScrambleImmunity = new StringMap();

    for (int i = 0; i < sizeof(SCRAMBLE_COMMANDS); i++)
    {
        RegConsoleCmd(SCRAMBLE_COMMANDS[i], Command_Scramble);
    }
    RegConsoleCmd("sm_votescramble", Command_Scramble);
    RegAdminCmd("sm_forcescramble", Command_WhaleScramble, ADMFLAG_GENERIC, "Immediately perform a whale scramble.");
    RegAdminCmd("sm_whalescramble", Command_WhaleScramble, ADMFLAG_GENERIC, "Immediately perform a whale scramble.");
    RegAdminCmd("sm_whalescramblevote", Command_ForceScrambleVote, ADMFLAG_GENERIC, "Force a whale scramble vote.");
    RegAdminCmd("sm_forcescramblevote", Command_ForceScrambleVote, ADMFLAG_GENERIC, "Force a whale scramble vote.");

    AddCommandListener(SayListener, "say");
    AddCommandListener(SayListener, "say_team");
    AddCommandListener(Command_EngineScramble, "mp_scrambleteams");
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_win", Event_RoundWin, EventHookMode_PostNoCopy);
    StartScrambleGamerulesHookRetry();
}

public void OnAllPluginsLoaded()
{
    UpdateNativeVotes();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "nativevotes", false))
    {
        UpdateNativeVotes();
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "nativevotes", false))
    {
        g_bNativeVotes = false;
    }
}

public void OnConfigsExecuted()
{
    g_iEngineAutoScrambleRounds = 0;
    g_iRoundsSinceEngineAuto = 0;

    if (g_hMpScrambleteamsAuto != null)
    {
        int configuredRounds = g_hMpScrambleteamsAuto.IntValue;
        if (configuredRounds > 1)
        {
            g_iEngineAutoScrambleRounds = configuredRounds;
            g_hMpScrambleteamsAuto.IntValue = 0;
            LogWhale("Disabled mp_scrambleteams_auto and will emulate a whale scramble every %d full rounds.", configuredRounds);
        }
        else if (configuredRounds > 0)
        {
            g_hMpScrambleteamsAuto.IntValue = 0;
            LogWhale("Disabled mp_scrambleteams_auto.");
        }
    }

    if (g_hSvVoteIssueScrambleAllowed != null && g_hSvVoteIssueScrambleAllowed.BoolValue)
    {
        g_hSvVoteIssueScrambleAllowed.BoolValue = false;
        LogWhale("Disabled sv_vote_issue_scramble_teams_allowed.");
    }
}

public void OnMapStart()
{
    StartScrambleGamerulesHookRetry();
    g_bBetweenRounds = false;
    ResetVotes();
    ClearScrambleCooldown();
    ClearPendingWhaleScramble();
    g_iRoundsSinceAuto = 0;
    g_iRoundsSinceEngineAuto = 0;
    if (g_hScrambleImmunity != null)
    {
        g_hScrambleImmunity.Clear();
    }
    LogWhale("Map start: immunity cleared, votes reset.");
}

public void OnMapEnd()
{
    delete g_hHookRetryTimer;
    g_hHookRetryTimer = null;
    g_iHandleScrambleTeamsHookId = INVALID_HOOK_ID;
    ResetVotes();
    ClearScrambleCooldown();
    ClearPendingWhaleScramble();
    g_bBetweenRounds = false;
    g_iRoundsSinceAuto = 0;
    g_iRoundsSinceEngineAuto = 0;
    LogWhale("Map end: votes reset.");
}

public void OnPluginEnd()
{
    delete g_hHookRetryTimer;
    g_hHookRetryTimer = null;
    g_iHandleScrambleTeamsHookId = INVALID_HOOK_ID;
    ResetVotes();
    ClearScrambleCooldown();
    ClearPendingWhaleScramble();
    g_bBetweenRounds = false;
    delete g_hHandleScrambleTeamsHook;
    g_hHandleScrambleTeamsHook = null;
    delete g_hSetScrambleTeamsCall;
    g_hSetScrambleTeamsCall = null;
    delete g_hChangeTeamCall;
    g_hChangeTeamCall = null;
    delete g_hWhaleScrambleGameData;
    g_hWhaleScrambleGameData = null;
    LogWhale("Plugin ended.");
}

public void OnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients)
        return;
    if (g_bPlayerVoted[client])
    {
        g_bPlayerVoted[client] = false;
        if (g_iVoteRequests > 0)
        {
            g_iVoteRequests--;
        }
    }
}

public void OnClientPutInServer(int client)
{
    if (client <= 0 || client > MaxClients)
        return;
}

public Action Command_EngineScramble(int client, const char[] command, int argc)
{
    if (IsWhaleScramblePending())
    {
        LogWhale("Ignoring %s because a whale scramble is already pending.", command);
        return Plugin_Handled;
    }

    if (client > 0 && IsClientConnected(client))
    {
        LogWhale("Observed %s from %N (%d).", command, client, GetClientUserId(client));
    }
    else
    {
        LogWhale("Observed %s from server console.", command);
    }

    if (QueueWhaleScramble(0, false, true, true))
    {
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

public Action Command_Scramble(int client, int args)
{
    LogWhale("Scramble request via command from %N (%d).", client, GetClientUserId(client));
    HandleScrambleRequest(client);
    return Plugin_Handled;
}

public Action Command_WhaleScramble(int client, int args)
{
    LogWhale("Admin whale scramble requested by %N (%d).", client, GetClientUserId(client));
    QueueWhaleScramble(client, true, true, false);
    return Plugin_Handled;
}

public Action Command_ForceScrambleVote(int client, int args)
{
    LogWhale("Admin force vote requested by %N (%d).", client, GetClientUserId(client));
    StartScrambleVote(client, false, true);
    return Plugin_Handled;
}

public Action SayListener(int client, const char[] command, int argc)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    char text[192];
    GetCmdArgString(text, sizeof(text));
    TrimString(text);
    StripQuotes(text);
    TrimString(text);

    if (!text[0])
    {
        return Plugin_Continue;
    }

    for (int i = 0; i < sizeof(SCRAMBLE_KEYWORDS); i++)
    {
        if (StrEqual(text, SCRAMBLE_KEYWORDS[i], false))
        {
            LogWhale("Scramble request via chat from %N (%d): %s", client, GetClientUserId(client), text);
            HandleScrambleRequest(client);
            return Plugin_Handled;
        }
    }

    return Plugin_Continue;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bBetweenRounds = false;
}

public void Event_RoundWin(Event event, const char[] name, bool dontBroadcast)
{
    ClearScrambleCooldown();

    if (!(event.GetBool("full_round")))
        return;

    g_bBetweenRounds = true;

    if (g_bQueuedWhaleScramble)
    {
        ArmPendingWhaleScramble();
    }

    if (!IsWhaleScramblePending() && g_iEngineAutoScrambleRounds > 1)
    {
        g_iRoundsSinceEngineAuto++;
        if (g_iRoundsSinceEngineAuto >= g_iEngineAutoScrambleRounds)
        {
            if (QueueWhaleScramble(0, false, true, false))
            {
                g_iRoundsSinceEngineAuto = 0;
            }
        }
    }

    if (g_hAutoRounds == null)
    {
        return;
    }

    // full_round is 1 if the entire map/round is over (Red lost or Blue finished final stage)
    // full_round is 0 if it was just a stage completion (e.g., Goldrush Stage 1)
    int roundsRequired = g_hAutoRounds.IntValue;
    if (roundsRequired <= 1)
    {
        return;
    }

    g_iRoundsSinceAuto++;
    if (g_iRoundsSinceAuto < roundsRequired)
    {
        return;
    }

    if (StartAutoScramble(true))
    {
        g_iRoundsSinceAuto = 0;
    }
}

static void UpdateNativeVotes()
{
    g_bNativeVotes = LibraryExists("nativevotes") && NativeVotes_IsVoteTypeSupported(NativeVotesType_Custom_YesNo);
}

static bool IsWhaleScramblePending()
{
    return g_bQueuedWhaleScramble || g_bPluginScramblePending;
}

static void HandleScrambleRequest(int client)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return;

    if (IsWhaleScramblePending())
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} A scramble is already pending.");
        LogWhale("Vote request rejected: scramble already pending (client %N).", client);
        return;
    }

    if (scrambleCooldown)
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} Scramble is on cooldown.");
        LogWhale("Vote request rejected: scramble cooldown active (client %N).", client);
        return;
    }

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} A vote is already running.");
        LogWhale("Vote request rejected: vote already running (client %N).", client);
        return;
    }

    if (g_bPlayerVoted[client])
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} You already requested a scramble.");
        LogWhale("Vote request rejected: already requested (client %N).", client);
        return;
    }

    g_bPlayerVoted[client] = true;
    g_iVoteRequests++;

    CPrintToChatAll("{blue}[WhaleScramble]{default} %N requested a scramble (%d/4).", client, g_iVoteRequests);
    LogWhale("Vote request counted: %N (%d/%d).", client, g_iVoteRequests, 4);

    if (g_iVoteRequests >= 4)
    {
        StartScrambleVote(client, false, false);
    }
}

static bool StartScrambleVote(int client, bool suppressFeedback, bool allowLowPop)
{
    LogWhale("Starting vote: caller=%d allowLowPop=%d suppressFeedback=%d.", client, allowLowPop ? 1 : 0, suppressFeedback ? 1 : 0);

    if (IsWhaleScramblePending())
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} A scramble is already pending.");
        }
        LogWhale("Vote start failed: scramble already pending.");
        return false;
    }

    if (scrambleCooldown)
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} Scramble is on cooldown.");
        }
        LogWhale("Vote start failed: scramble cooldown active.");
        return false;
    }

    if (!g_bNativeVotes)
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} NativeVotes is unavailable.");
        }
        LogWhale("Vote start failed: NativeVotes unavailable.");
        return false;
    }

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} A vote is already running.");
        }
        LogWhale("Vote start failed: vote already running.");
        return false;
    }

    int delay = NativeVotes_CheckVoteDelay();
    if (delay > 0)
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            NativeVotes_DisplayCallVoteFail(client, NativeVotesCallFail_Recent, delay);
        }
        LogWhale("Vote start failed: vote delay %d.", delay);
        return false;
    }

    if (!NativeVotes_IsNewVoteAllowed())
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} A vote is not allowed right now.");
        }
        LogWhale("Vote start failed: new vote not allowed.");
        return false;
    }

    if (g_hVote != null)
    {
        g_hVote.Close();
        g_hVote = null;
    }

    g_hVote = new NativeVote(ScrambleVoteHandler, NativeVotesType_Custom_YesNo, MENU_ACTIONS_ALL);
    NativeVotes_SetTitle(g_hVote, "Whale scramble teams?");

    int voteTime = 4;
    if (g_hVoteTime != null)
    {
        voteTime = g_hVoteTime.IntValue;
    }
    if (voteTime < 1)
    {
        voteTime = 1;
    }

    g_bVoteRunning = NativeVotes_DisplayToAll(g_hVote, voteTime);
    if (!g_bVoteRunning)
    {
        g_hVote.Close();
        g_hVote = null;
        g_bVoteAllowLowPop = false;
        LogWhale("Vote start failed: display to all returned false.");
        return false;
    }

    g_bVoteAllowLowPop = allowLowPop;
    LogWhale("Vote started: duration=%d allowLowPop=%d.", voteTime, allowLowPop ? 1 : 0);
    return true;
}

static bool StartAutoScramble(bool suppressFeedback)
{
    if (IsWhaleScramblePending())
    {
        LogWhale("Auto scramble skipped: scramble already pending.");
        return false;
    }

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        return false;
    }

    if (!suppressFeedback)
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} Auto scramble triggered.");
    }

    LogWhale("Auto scramble triggered.");
    return QueueWhaleScramble(0, !suppressFeedback, false, false);
}

static void InitHandleScrambleTeamsHook()
{
    if (g_hWhaleScrambleGameData != null)
    {
        return;
    }

    if (GetFeatureStatus(FeatureType_Native, "DynamicHook.DynamicHook") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "DynamicHook.HookGamerules") != FeatureStatus_Available)
    {
        LogWhale("DHooks unavailable; engine scramble interception disabled.");
        return;
    }

    g_hWhaleScrambleGameData = LoadGameConfigFile("whalescramble");
    if (g_hWhaleScrambleGameData == null)
    {
        LogWhale("Failed to load gamedata/whalescramble.txt; engine scramble interception disabled.");
        return;
    }

    int offset = g_hWhaleScrambleGameData.GetOffset("CTeamplayRules::HandleScrambleTeams");
    if (offset < 0)
    {
        LogWhale("Failed to load CTeamplayRules::HandleScrambleTeams offset from gamedata.");
        return;
    }

    g_hHandleScrambleTeamsHook = new DynamicHook(offset, HookType_GameRules, ReturnType_Void, ThisPointer_Ignore);
    if (g_hHandleScrambleTeamsHook == null)
    {
        LogWhale("Failed to create CTeamplayRules::HandleScrambleTeams hook.");
        return;
    }

    StartPrepSDKCall(SDKCall_GameRules);
    if (!PrepSDKCall_SetFromConf(g_hWhaleScrambleGameData, SDKConf_Virtual, "CTeamplayRules::SetScrambleTeams"))
    {
        LogWhale("Failed to prepare CTeamplayRules::SetScrambleTeams SDK call.");
        return;
    }
    PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
    g_hSetScrambleTeamsCall = EndPrepSDKCall();
    if (g_hSetScrambleTeamsCall == null)
    {
        LogWhale("Failed to create CTeamplayRules::SetScrambleTeams SDK call.");
        return;
    }

    StartPrepSDKCall(SDKCall_Player);
    if (!PrepSDKCall_SetFromConf(g_hWhaleScrambleGameData, SDKConf_Virtual, "CBasePlayer::ChangeTeam"))
    {
        LogWhale("Failed to prepare CBasePlayer::ChangeTeam SDK call.");
        return;
    }
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
    PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
    g_hChangeTeamCall = EndPrepSDKCall();
    if (g_hChangeTeamCall == null)
    {
        LogWhale("Failed to create CBasePlayer::ChangeTeam SDK call.");
        return;
    }

}

static void ClearPendingWhaleScramble()
{
    g_bQueuedWhaleScramble = false;
    g_bPluginScramblePending = false;
    g_bPendingScrambleAllowEngineFallback = false;
    g_iPendingScrambleIssuerUserId = 0;
    g_bPendingScrambleBroadcastFailures = false;
    g_bPendingScrambleAllowLowPop = true;
}

static bool HasGameRulesEntity()
{
    if (FindEntityByClassname(-1, "tf_gamerules") != -1)
    {
        return true;
    }

    return FindEntityByClassname(-1, "game_rules_proxy") != -1;
}

static bool AreScrambleGamerulesHooksReady()
{
    return g_iHandleScrambleTeamsHookId != INVALID_HOOK_ID;
}

static void StartScrambleGamerulesHookRetry()
{
    if (AreScrambleGamerulesHooksReady() || g_hHandleScrambleTeamsHook == null)
    {
        return;
    }

    if (g_hHookRetryTimer == null)
    {
        g_hHookRetryTimer = CreateTimer(0.5, Timer_TryHookScrambleGamerules, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        LogWhale("Scheduling deferred scramble hook retry.");
    }
}

static bool ArmPendingWhaleScramble()
{
    if (g_hSetScrambleTeamsCall == null || g_hHandleScrambleTeamsHook == null)
    {
        LogWhale("Failed to arm whale scramble: hook/call unavailable.");
        return false;
    }

    g_bPluginScramblePending = true;
    g_bQueuedWhaleScramble = false;

    SDKCall(g_hSetScrambleTeamsCall, true);
    LogWhale("Armed whale scramble for engine handling: issuer=%d allowLowPop=%d broadcastFailures=%d fallback=%d.", g_iPendingScrambleIssuerUserId, g_bPendingScrambleAllowLowPop ? 1 : 0, g_bPendingScrambleBroadcastFailures ? 1 : 0, g_bPendingScrambleAllowEngineFallback ? 1 : 0);
    return true;
}

static bool QueueWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop, bool allowEngineFallback)
{
    if (g_hSetScrambleTeamsCall == null || g_hHandleScrambleTeamsHook == null)
    {
        NotifyFailure(issuer, broadcastFailures, "Engine scramble hook is unavailable.");
        LogWhale("Failed to queue whale scramble: hook/call unavailable.");
        return false;
    }

    g_iRoundsSinceAuto = 0;
    g_iRoundsSinceEngineAuto = 0;
    g_iPendingScrambleIssuerUserId = (issuer > 0 && IsClientInGame(issuer)) ? GetClientUserId(issuer) : 0;
    g_bPendingScrambleBroadcastFailures = broadcastFailures;
    g_bPendingScrambleAllowLowPop = allowLowPop;
    g_bPendingScrambleAllowEngineFallback = allowEngineFallback;

    if (g_bBetweenRounds)
    {
        LogWhale("QueueWhaleScramble requested between rounds; arming immediately.");
        return ArmPendingWhaleScramble();
    }

    g_bQueuedWhaleScramble = true;
    LogWhale("Queued whale scramble for next full round end: issuer=%d allowLowPop=%d broadcastFailures=%d fallback=%d.", issuer, allowLowPop ? 1 : 0, broadcastFailures ? 1 : 0, allowEngineFallback ? 1 : 0);
    return true;
}

static void HookScrambleGamerules()
{
    if (g_hHandleScrambleTeamsHook == null || g_iHandleScrambleTeamsHookId != INVALID_HOOK_ID)
    {
        return;
    }

    g_iHandleScrambleTeamsHookId = g_hHandleScrambleTeamsHook.HookGamerules(Hook_Pre, DHook_HandleScrambleTeams);
    if (g_iHandleScrambleTeamsHookId == INVALID_HOOK_ID)
    {
        LogWhale("Failed to hook CTeamplayRules::HandleScrambleTeams on gamerules.");
    }
    else
    {
        LogWhale("Hooked CTeamplayRules::HandleScrambleTeams.");
    }
}

public Action Timer_TryHookScrambleGamerules(Handle timer)
{
    if (timer != g_hHookRetryTimer)
    {
        return Plugin_Stop;
    }

    if (AreScrambleGamerulesHooksReady())
    {
        g_hHookRetryTimer = null;
        return Plugin_Stop;
    }

    if (!HasGameRulesEntity())
    {
        return Plugin_Continue;
    }

    HookScrambleGamerules();
    if (AreScrambleGamerulesHooksReady())
    {
        g_hHookRetryTimer = null;
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

public MRESReturn DHook_HandleScrambleTeams()
{
    if (!g_bPluginScramblePending)
    {
        LogWhale("Ignoring HandleScrambleTeams without a pending whale scramble.");
        return MRES_Ignored;
    }

    g_bHandlingEngineScramble = true;
    int issuer = GetClientOfUserId(g_iPendingScrambleIssuerUserId);
    bool broadcastFailures = g_bPendingScrambleBroadcastFailures;
    bool allowLowPop = g_bPendingScrambleAllowLowPop;
    bool allowEngineFallback = g_bPendingScrambleAllowEngineFallback;
    LogWhale("Intercepted CTeamplayRules::HandleScrambleTeams (issuer=%d allowLowPop=%d broadcastFailures=%d fallback=%d).", g_iPendingScrambleIssuerUserId, allowLowPop ? 1 : 0, broadcastFailures ? 1 : 0, allowEngineFallback ? 1 : 0);
    bool started = Internal_HandleScramble(issuer, broadcastFailures, allowLowPop);
    g_bHandlingEngineScramble = false;
    ClearPendingWhaleScramble();

    if (!started)
    {
        if (allowEngineFallback)
        {
            LogWhale("Queued whale scramble failed during engine handling; allowing TF2 fallback.");
            return MRES_Ignored;
        }

        LogWhale("Queued whale scramble failed during engine handling.");
        return MRES_Supercede;
    }

    return MRES_Supercede;
}

static bool Internal_HandleScramble(int issuer, bool broadcastFailures, bool allowLowPop)
{
    if (g_hTopSwap != null && g_hTopSwap.BoolValue)
    {
        LogWhale("Configured scramble mode: topswap.");
        return StartWhaleScramble(issuer, broadcastFailures, allowLowPop);
    }
    else if (g_hRandom != null && g_hRandom.BoolValue)
    {
        LogWhale("Configured scramble mode: random.");
        return StartRandomWhaleScramble(issuer, broadcastFailures, allowLowPop);
    }

    NotifyFailure(issuer, broadcastFailures, "No scramble mode is enabled. Set sm_ws_topswap or sm_ws_random to 1.");
    LogWhale("Configured scramble aborted: no enabled modes.");
    return false;
}

public int ScrambleVoteHandler(NativeVote vote, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_End:
        {
            vote.Close();
            g_hVote = null;
            g_bVoteRunning = false;
            g_bVoteAllowLowPop = false;
            ResetVotes();
            LogWhale("Vote ended.");
            return 0;
        }
        case MenuAction_VoteCancel:
        {
            if (param1 == VoteCancel_NoVotes)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_NotEnoughVotes);
            }
            else
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_Generic);
            }
            g_bVoteAllowLowPop = false;
            LogWhale("Vote cancelled: %d.", param1);
            return 0;
        }
        case MenuAction_VoteEnd:
        {
            int votes = 0;
            int totalVotes = 0;
            NativeVotes_GetInfo(param2, votes, totalVotes);

            if (totalVotes <= 0)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_NotEnoughVotes);
                LogWhale("Vote failed: no votes.");
                return 0;
            }

            int yesVotes = (param1 == NATIVEVOTES_VOTE_YES) ? votes : (totalVotes - votes);
            float yesPercent = float(yesVotes) / float(totalVotes);

            if (yesPercent < 0.50)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_Loses);
                CPrintToChatAll("Vote failed (Yes %.0f%%).", yesPercent * 100.0);
                g_bVoteAllowLowPop = false;
                LogWhale("Vote failed: yes=%d total=%d (%.1f%%).", yesVotes, totalVotes, yesPercent * 100.0);
            }
            else
            {
                bool started = QueueWhaleScramble(0, true, g_bVoteAllowLowPop, false);
                if (started)
                {
                    NativeVotes_DisplayPassCustom(vote, "Vote passed. Whale scramble queued for round end.");
                    LogWhale("Vote passed: yes=%d total=%d (%.1f%%).", yesVotes, totalVotes, yesPercent * 100.0);
                }
                else
                {
                    NativeVotes_DisplayPassCustom(vote, "Vote passed. Scramble conditions not met.");
                    LogWhale("Vote passed but scramble conditions not met.");
                }
                g_bVoteAllowLowPop = false;
            }
            return 0;
        }
    }
    return 0;
}

static void ResetVotes()
{
    g_iVoteRequests = 0;
    g_bVoteRunning = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bPlayerVoted[i] = false;
    }
}

static void StartScrambleCooldown()
{
    scrambleCooldown = true;
    if (g_hScrambleCooldownTimer != null)
    {
        delete g_hScrambleCooldownTimer;
        g_hScrambleCooldownTimer = null;
    }

    g_hScrambleCooldownTimer = CreateTimer(120.0, Timer_ResetScrambleCooldown, _, TIMER_FLAG_NO_MAPCHANGE);
    LogWhale("Scramble cooldown started.");
}

static void ClearScrambleCooldown()
{
    scrambleCooldown = false;
    if (g_hScrambleCooldownTimer != null)
    {
        delete g_hScrambleCooldownTimer;
        g_hScrambleCooldownTimer = null;
    }
}

static bool StartWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop)
{
    LogWhale("StartWhaleScramble: issuer=%d allowLowPop=%d.", issuer, allowLowPop ? 1 : 0);
    g_iRoundsSinceAuto = 0;
    int totalPlayers = 0;
    int redCount = 0;
    int bluCount = 0;
    int redEligible = 0;
    int bluEligible = 0;

    int topRed[MAX_SWAP_BUFFER];
    int topBlu[MAX_SWAP_BUFFER];
    int topRedScore[MAX_SWAP_BUFFER];
    int topBluScore[MAX_SWAP_BUFFER];

    for (int i = 0; i < MAX_SWAP_BUFFER; i++)
    {
        topRed[i] = 0;
        topBlu[i] = 0;
        topRedScore[i] = -999999;
        topBluScore[i] = -999999;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU) continue;

        totalPlayers++;
        if (team == TEAM_RED) redCount++;
        else bluCount++;

        if (IsScrambleImmune(i)) continue;

        if (team == TEAM_RED) redEligible++;
        else bluEligible++;

        int score = GetScrambleScore(i, false);
        if (team == TEAM_RED)
        {
            InsertTopN(i, score, topRed, topRedScore, MAX_TOP_SWAP);
        }
        else
        {
            InsertTopN(i, score, topBlu, topBluScore, MAX_TOP_SWAP);
        }
    }

    LogWhale("Counts: total=%d red=%d blu=%d eligibleRed=%d eligibleBlu=%d.", totalPlayers, redCount, bluCount, redEligible, bluEligible);
    int swapCount = 0;
    bool lowPop = (totalPlayers < 12);

    if (!lowPop)
    {
        if (totalPlayers >= 20)
        {
            swapCount = MAX_TOP_SWAP;
        }
        else
        {
            swapCount = 3;
        }
    }
    else if (allowLowPop)
    {
        swapCount = redEligible < bluEligible ? redEligible : bluEligible;
        if (swapCount > 2)
        {
            swapCount = 2;
        }
    }

    bool needsFallback = (redEligible < swapCount || bluEligible < swapCount);
    if (allowLowPop && lowPop && swapCount == 0)
    {
        needsFallback = true;
    }
    if (needsFallback)
    {
        LogWhale("Eligibility low; recalculating without class filters.");
        redEligible = 0;
        bluEligible = 0;
        for (int i = 0; i < MAX_SWAP_BUFFER; i++)
        {
            topRed[i] = 0;
            topBlu[i] = 0;
            topRedScore[i] = -999999;
            topBluScore[i] = -999999;
        }

        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i)) continue;
            if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

            int team = GetClientTeam(i);
            if (team != TEAM_RED && team != TEAM_BLU) continue;
            if (IsScrambleImmune(i)) continue;

            if (team == TEAM_RED) redEligible++;
            else bluEligible++;

            int score = GetScrambleScore(i, true);
            if (team == TEAM_RED)
            {
                InsertTopN(i, score, topRed, topRedScore, MAX_TOP_SWAP);
            }
            else
            {
                InsertTopN(i, score, topBlu, topBluScore, MAX_TOP_SWAP);
            }
        }
        if (allowLowPop && lowPop)
        {
            swapCount = redEligible < bluEligible ? redEligible : bluEligible;
            if (swapCount > 2)
            {
                swapCount = 2;
            }
        }
    }

    if (swapCount == 0)
    {
        if (allowLowPop && lowPop)
        {
            NotifyFailure(issuer, broadcastFailures, "Not enough eligible players to swap (RED=%d BLU=%d).", redEligible, bluEligible);
            LogWhale("Scramble aborted: not enough eligible players (red=%d blu=%d).", redEligible, bluEligible);
        }
        else
        {
            NotifyFailure(issuer, broadcastFailures, "Need at least 12 players (current: %d).", totalPlayers);
            LogWhale("Scramble aborted: not enough players (total=%d).", totalPlayers);
        }
        return false;
    }

    if (redCount < swapCount || bluCount < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d players (RED=%d BLU=%d).", swapCount, redCount, bluCount);
        LogWhale("Scramble aborted: team size too small (swap=%d red=%d blu=%d).", swapCount, redCount, bluCount);
        return false;
    }

    if (redEligible < swapCount || bluEligible < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d eligible players (RED=%d BLU=%d).", swapCount, redEligible, bluEligible);
        LogWhale("Scramble aborted: eligible too small (swap=%d red=%d blu=%d).", swapCount, redEligible, bluEligible);
        return false;
    }

    if (g_bHandlingEngineScramble)
    {
        bool started = ExecuteWhaleScramble(issuer > 0 ? GetClientUserId(issuer) : 0, swapCount, topRed, topBlu, false, true);
        LogWhale("Scramble handled during engine hook: swapCount=%d started=%d.", swapCount, started ? 1 : 0);
        return started;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(issuer > 0 ? GetClientUserId(issuer) : 0);
    pack.WriteCell(swapCount);
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topRed[i]));
    }
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topBlu[i]));
    }

    CreateTimer(0.1, Timer_DoSwap, pack, TIMER_FLAG_NO_MAPCHANGE);
    LogWhale("Scramble scheduled: swapCount=%d.", swapCount);
    return true;
}

static bool StartRandomWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop)
{
    LogWhale("StartRandomWhaleScramble: issuer=%d allowLowPop=%d.", issuer, allowLowPop ? 1 : 0);
    g_iRoundsSinceAuto = 0;
    int totalPlayers = 0;
    int redCount = 0;
    int bluCount = 0;
    int redEligible = 0;
    int bluEligible = 0;
    int redCandidates[MAXPLAYERS + 1];
    int bluCandidates[MAXPLAYERS + 1];
    int redCandidateCount = 0;
    int bluCandidateCount = 0;
    int topRed[MAX_SWAP_BUFFER];
    int topBlu[MAX_SWAP_BUFFER];

    for (int i = 0; i < MAX_SWAP_BUFFER; i++)
    {
        topRed[i] = 0;
        topBlu[i] = 0;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU) continue;

        totalPlayers++;
        if (team == TEAM_RED) redCount++;
        else bluCount++;

        if (IsScrambleImmune(i)) continue;
        if (!IsSimpleScrambleEligibleClass(i)) continue;

        if (team == TEAM_RED)
        {
            redEligible++;
            if (redCandidateCount < sizeof(redCandidates))
            {
                redCandidates[redCandidateCount++] = i;
            }
        }
        else
        {
            bluEligible++;
            if (bluCandidateCount < sizeof(bluCandidates))
            {
                bluCandidates[bluCandidateCount++] = i;
            }
        }
    }

    LogWhale("Random counts: total=%d red=%d blu=%d eligibleRed=%d eligibleBlu=%d.", totalPlayers, redCount, bluCount, redEligible, bluEligible);
    int swapCount = 0;
    bool lowPop = (totalPlayers < 12);

    if (!lowPop)
    {
        if (totalPlayers >= 20)
        {
            swapCount = MAX_RANDOM_SWAP;
        }
        else
        {
            swapCount = 4;
        }
    }
    else if (allowLowPop)
    {
        swapCount = redEligible < bluEligible ? redEligible : bluEligible;
        if (swapCount > 2)
        {
            swapCount = 2;
        }
    }

    bool needsFallback = (redEligible < swapCount || bluEligible < swapCount);
    if (allowLowPop && lowPop && swapCount == 0)
    {
        needsFallback = true;
    }
    if (needsFallback)
    {
        LogWhale("Random eligibility low; recalculating without class filters.");
        redEligible = 0;
        bluEligible = 0;
        redCandidateCount = 0;
        bluCandidateCount = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i)) continue;
            if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

            int team = GetClientTeam(i);
            if (team != TEAM_RED && team != TEAM_BLU) continue;
            if (IsScrambleImmune(i)) continue;

            if (team == TEAM_RED)
            {
                redEligible++;
                if (redCandidateCount < sizeof(redCandidates))
                {
                    redCandidates[redCandidateCount++] = i;
                }
            }
            else
            {
                bluEligible++;
                if (bluCandidateCount < sizeof(bluCandidates))
                {
                    bluCandidates[bluCandidateCount++] = i;
                }
            }
        }
        if (allowLowPop && lowPop)
        {
            swapCount = redEligible < bluEligible ? redEligible : bluEligible;
            if (swapCount > 2)
            {
                swapCount = 2;
            }
        }
    }

    if (swapCount == 0)
    {
        if (allowLowPop && lowPop)
        {
            NotifyFailure(issuer, broadcastFailures, "Not enough eligible players to swap (RED=%d BLU=%d).", redEligible, bluEligible);
            LogWhale("Random scramble aborted: not enough eligible players (red=%d blu=%d).", redEligible, bluEligible);
        }
        else
        {
            NotifyFailure(issuer, broadcastFailures, "Need at least 12 players (current: %d).", totalPlayers);
            LogWhale("Random scramble aborted: not enough players (total=%d).", totalPlayers);
        }
        return false;
    }

    if (redCount < swapCount || bluCount < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d players (RED=%d BLU=%d).", swapCount, redCount, bluCount);
        LogWhale("Random scramble aborted: team size too small (swap=%d red=%d blu=%d).", swapCount, redCount, bluCount);
        return false;
    }

    if (redEligible < swapCount || bluEligible < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d eligible players (RED=%d BLU=%d).", swapCount, redEligible, bluEligible);
        LogWhale("Random scramble aborted: eligible too small (swap=%d red=%d blu=%d).", swapCount, redEligible, bluEligible);
        return false;
    }

    if (!SelectRandomPlayers(redCandidates, redCandidateCount, topRed, swapCount)
        || !SelectRandomPlayers(bluCandidates, bluCandidateCount, topBlu, swapCount))
    {
        NotifyFailure(issuer, broadcastFailures, "Failed to select random swap targets.");
        LogWhale("Random scramble aborted: random selection failed (swap=%d redCandidates=%d bluCandidates=%d).", swapCount, redCandidateCount, bluCandidateCount);
        return false;
    }

    if (g_bHandlingEngineScramble)
    {
        bool started = ExecuteWhaleScramble(issuer > 0 ? GetClientUserId(issuer) : 0, swapCount, topRed, topBlu, false, true);
        LogWhale("Random scramble handled during engine hook: swapCount=%d started=%d.", swapCount, started ? 1 : 0);
        return started;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(issuer > 0 ? GetClientUserId(issuer) : 0);
    pack.WriteCell(swapCount);
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topRed[i]));
    }
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topBlu[i]));
    }

    CreateTimer(0.1, Timer_DoSwap, pack, TIMER_FLAG_NO_MAPCHANGE);
    LogWhale("Random scramble scheduled: swapCount=%d.", swapCount);
    return true;
}

static void ChangeClientTeamForWhaleScramble(int client, int team, bool engineTiming)
{
    if (engineTiming)
    {
        if (g_hChangeTeamCall != null)
        {
            SDKCall(g_hChangeTeamCall, client, team, false, true);
        }
        else
        {
            ChangeClientTeam(client, team);
        }
        return;
    }

    ChangeClientTeam(client, team);
    TF2_RespawnPlayer(client);
}

static bool ExecuteWhaleScramble(int issuerUserId, int swapCount, const int redEntries[MAX_SWAP_BUFFER], const int bluEntries[MAX_SWAP_BUFFER], bool entriesAreUserIds, bool engineTiming)
{
    if (!engineTiming && GetFeatureStatus(FeatureType_Native, "FilterAlerts_SuppressTeamAlertWindow") == FeatureStatus_Available)
    {
        FilterAlerts_SuppressTeamAlertWindow(2.0);
    }

    int moved = 0;
    int pairR[MAX_SWAP_BUFFER];
    int pairB[MAX_SWAP_BUFFER];
    int pairCount = 0;
    for (int i = 0; i < swapCount; i++)
    {
        int r = entriesAreUserIds ? GetClientOfUserId(redEntries[i]) : redEntries[i];
        int b = entriesAreUserIds ? GetClientOfUserId(bluEntries[i]) : bluEntries[i];

        if (r <= 0 || b <= 0) continue;
        if (!IsClientInGame(r) || !IsClientInGame(b)) continue;
        if (GetClientTeam(r) != TEAM_RED || GetClientTeam(b) != TEAM_BLU) continue;

        if (pairCount < MAX_SWAP_BUFFER)
        {
            pairR[pairCount] = r;
            pairB[pairCount] = b;
            pairCount++;
        }

        if (r > 0 && IsClientInGame(r) && GetClientTeam(r) == TEAM_RED)
        {
            ChangeClientTeamForWhaleScramble(r, TEAM_BLU, engineTiming);
            MarkScrambleImmune(r);
        }
        if (b > 0 && IsClientInGame(b) && GetClientTeam(b) == TEAM_BLU)
        {
            ChangeClientTeamForWhaleScramble(b, TEAM_RED, engineTiming);
            MarkScrambleImmune(b);
        }
    }

    moved = pairCount * 2;
    if (moved > 0)
    {
        StartScrambleCooldown();
        CPrintToChatAll("{tomato}[{purple}Gap{tomato}]{default} {gold}Whalescrambling{default} %d players!", moved);
        LogWhale("Scramble executed: moved=%d pairs=%d.", moved, pairCount);
        for (int i = 0; i < pairCount; i++)
        {
            int r = pairR[i];
            int b = pairB[i];

            char nameR[256];
            char nameB[256];
            bool hasFilterR = GetFiltersNameOrEmpty(r, nameR, sizeof(nameR));
            bool hasFilterB = GetFiltersNameOrEmpty(b, nameB, sizeof(nameB));

            int srcClient = r;
            bool useTeamColorR = false;
            bool useTeamColorB = false;

            if (!hasFilterR && !hasFilterB)
            {
                srcClient = r;
                useTeamColorR = true;
            }
            else if (!hasFilterR)
            {
                srcClient = r;
                useTeamColorR = true;
            }
            else if (!hasFilterB)
            {
                srcClient = b;
                useTeamColorB = true;
            }

            if (!hasFilterR)
            {
                BuildFallbackName(r, useTeamColorR, nameR, sizeof(nameR));
            }
            if (!hasFilterB)
            {
                BuildFallbackName(b, useTeamColorB, nameB, sizeof(nameB));
            }

            CPrintToChatAllEx(srcClient, "%s <-> %s", nameR, nameB);
            LogWhale("Pair %d: %N <-> %N.", i + 1, r, b);
        }

        for (int i = 0; i < pairCount; i++)
        {
            int r = pairR[i];
            int b = pairB[i];
            if (r > 0 && IsClientInGame(r))
            {
                PrintHintText(r, "You have been WhaleScrambled!");
            }
            if (b > 0 && IsClientInGame(b))
            {
                PrintHintText(b, "You have been WhaleScrambled!");
            }
        }
    }
    else
    {
        int issuer = GetClientOfUserId(issuerUserId);
        if (issuer > 0 && IsClientInGame(issuer))
        {
            ReplyToCommand(issuer, "[whalescramble] No eligible players to swap.");
        }
        LogWhale("Scramble executed: no eligible pairs.");
    }
    return moved > 0;
}

public Action Timer_DoSwap(Handle timer, DataPack pack)
{
    pack.Reset();
    int issuerUserId = pack.ReadCell();
    int swapCount = pack.ReadCell();

    int redIds[MAX_SWAP_BUFFER];
    int bluIds[MAX_SWAP_BUFFER];

    for (int i = 0; i < swapCount; i++)
    {
        redIds[i] = pack.ReadCell();
    }
    for (int i = 0; i < swapCount; i++)
    {
        bluIds[i] = pack.ReadCell();
    }

    delete pack;

    ExecuteWhaleScramble(issuerUserId, swapCount, redIds, bluIds, true, false);
    return Plugin_Stop;
}

public Action Timer_ResetScrambleCooldown(Handle timer)
{
    if (timer == g_hScrambleCooldownTimer)
    {
        g_hScrambleCooldownTimer = null;
    }
    scrambleCooldown = false;
    LogWhale("Scramble cooldown expired.");
    return Plugin_Stop;
}

static void NotifyFailure(int issuer, bool broadcastFailures, const char[] fmt, any ...)
{
    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 4);
    if (issuer > 0 && IsClientInGame(issuer))
    {
        ReplyToCommand(issuer, "[whalescramble] %s", buffer);
        return;
    }
    if (broadcastFailures)
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} %s", buffer);
    }
}

static void InsertTopN(int client, int score, int clients[MAX_SWAP_BUFFER], int scores[MAX_SWAP_BUFFER], int maxCount)
{
    for (int i = 0; i < maxCount; i++)
    {
        if (score > scores[i])
        {
            for (int j = maxCount - 1; j > i; j--)
            {
                scores[j] = scores[j - 1];
                clients[j] = clients[j - 1];
            }
            scores[i] = score;
            clients[i] = client;
            return;
        }
    }
}

static int GetScrambleScore(int client, bool ignoreClass)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return 0;
    }

    if (!ignoreClass)
    {
        TFClassType cls = TF2_GetPlayerClass(client);
        if (cls == TFClass_Spy || cls == TFClass_Engineer || cls == TFClass_Medic)
        {
            return 0;
        }
    }

    return GetClientFrags(client);
}

static bool IsSimpleScrambleEligibleClass(int client)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return false;
    }

    TFClassType cls = TF2_GetPlayerClass(client);
    return cls != TFClass_Engineer && cls != TFClass_Medic;
}

static bool SelectRandomPlayers(const int candidates[MAXPLAYERS + 1], int candidateCount, int selected[MAX_SWAP_BUFFER], int selectedCount)
{
    if (selectedCount <= 0 || selectedCount > MAX_SWAP_BUFFER || candidateCount < selectedCount)
    {
        return false;
    }

    int pool[MAXPLAYERS + 1];
    for (int i = 0; i < candidateCount; i++)
    {
        pool[i] = candidates[i];
    }

    for (int i = 0; i < selectedCount; i++)
    {
        int remaining = candidateCount - i;
        int pick = GetRandomInt(0, remaining - 1);
        selected[i] = pool[pick];
        pool[pick] = pool[remaining - 1];
    }

    return true;
}

static bool IsScrambleImmune(int client)
{
    if (client <= 0 || !IsClientInGame(client) || g_hScrambleImmunity == null)
    {
        return false;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return false;
    }

    int dummy = 0;
    return g_hScrambleImmunity.GetValue(steamId, dummy);
}

static void MarkScrambleImmune(int client)
{
    if (client <= 0 || !IsClientInGame(client) || g_hScrambleImmunity == null)
    {
        return;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return;
    }

    g_hScrambleImmunity.SetValue(steamId, 1, true);
}

static void LogWhale(const char[] fmt, any ...)
{
    if (g_hLogEnabled == null || !g_hLogEnabled.BoolValue)
    {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFileEx(g_sLogPath, "%s", buffer);
}

static bool GetFiltersNameOrEmpty(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (client <= 0 || !IsClientInGame(client))
    {
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available)
    {
        if (Filters_GetChatName(client, buffer, maxlen) && buffer[0] != '\0')
        {
            return true;
        }
    }
    return false;
}

static void BuildFallbackName(int client, bool useTeamColor, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    if (useTeamColor)
    {
        Format(buffer, maxlen, "{teamcolor}%s{default}", name);
        return;
    }

    char colorTag[16];
    switch (GetClientTeam(client))
    {
        case TEAM_RED: strcopy(colorTag, sizeof(colorTag), "{red}");
        case TEAM_BLU: strcopy(colorTag, sizeof(colorTag), "{blue}");
        case 4: strcopy(colorTag, sizeof(colorTag), "{green}");
        case 5: strcopy(colorTag, sizeof(colorTag), "{yellow}");
        default: strcopy(colorTag, sizeof(colorTag), "{default}");
    }

    Format(buffer, maxlen, "%s%s{default}", colorTag, name);
}
