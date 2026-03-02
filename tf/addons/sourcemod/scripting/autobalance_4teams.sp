#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <morecolors>
#include <tf2_stocks>

native int FilterAlerts_MarkAutobalance(int client);

#define CHECK_INTERVAL      3.0
#define IMMUNITY_DURATION   300.0   // seconds a player stays immune after being balanced
#define TEAM_RED            2
#define TEAM_BLUE           3
#define TEAM_GREEN          4
#define TEAM_YELLOW         5
#define GAME_TEAM_COUNT     4

static const int g_GameTeams[GAME_TEAM_COUNT] =
{
    TEAM_RED,
    TEAM_BLUE,
    TEAM_GREEN,
    TEAM_YELLOW
};

float   g_fImmunityExpiry[MAXPLAYERS + 1];  // GetGameTime() at which immunity expires; 0.0 = not immune
ConVar  g_hLogEnabled;
ConVar  g_hDiffThreshold;
ConVar  g_hMpAutoteamBalance;
ConVar  g_hMpTeamsUnbalanceLimit;
int     g_iSavedAutoteamBalance;
int     g_iSavedUnbalanceLimit;
char    g_sLogPath[PLATFORM_MAX_PATH];
Handle  g_hAutoBalanceTimer = INVALID_HANDLE;

public Plugin myinfo =
{
    name        = "autobalance_4teams",
    author      = "Hombre",
    description = "Moves players when 4 teams are imbalanced.",
    version     = "1.3",
    url         = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("FilterAlerts_MarkAutobalance");
    return APLRes_Success;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

public void OnPluginStart()
{
    g_hLogEnabled = CreateConVar("sm_autobalance_log", "1", "Enable autobalance debug logging.", _, true, 0.0, true, 1.0);
    g_hDiffThreshold = CreateConVar("sm_autobalance_diff", "1", "Autobalance when team size difference is above this value.", _, true, 1.0, true, 10.0);
    BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/autobalance.log");
    LogToFileEx(g_sLogPath, "[autobalance_4teams] Plugin started.");

    ApplyServerBalanceCvars(true);
}

public void OnMapStart()
{
    if (g_hAutoBalanceTimer != INVALID_HANDLE)
    {
        KillTimer(g_hAutoBalanceTimer);
        g_hAutoBalanceTimer = INVALID_HANDLE;
    }

    g_hAutoBalanceTimer = CreateTimer(CHECK_INTERVAL, Timer_Autobalance, _, TIMER_REPEAT);
}

public void OnPluginEnd()
{
    ApplyServerBalanceCvars(false);

    if (g_hAutoBalanceTimer != INVALID_HANDLE)
    {
        KillTimer(g_hAutoBalanceTimer);
        g_hAutoBalanceTimer = INVALID_HANDLE;
    }
}

public void OnClientPutInServer(int client)
{
    if (client <= 0 || client > MaxClients) return;
    g_fImmunityExpiry[client] = 0.0;
}

public void OnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients) return;
    g_fImmunityExpiry[client] = 0.0;
}

// ---------------------------------------------------------------------------
// Main balance timer
// ---------------------------------------------------------------------------

public Action Timer_Autobalance(Handle timer)
{
    int teamCounts[6];

    for (int i = 0; i < GAME_TEAM_COUNT; i++)
    {
        int team = g_GameTeams[i];
        teamCounts[team] = CountTeamPlayersRaw(team);
    }

    // Build the list of active teams (always RED + BLU; add GREEN/YELLOW if populated).
    int activeTeams[GAME_TEAM_COUNT];
    int activeCount = 0;
    activeTeams[activeCount++] = TEAM_RED;
    activeTeams[activeCount++] = TEAM_BLUE;

    if (teamCounts[TEAM_GREEN] > 0 || teamCounts[TEAM_YELLOW] > 0)
    {
        activeTeams[activeCount++] = TEAM_GREEN;
        activeTeams[activeCount++] = TEAM_YELLOW;
    }

    // Sort active teams by count descending (simple insertion sort; max 4 elements).
    int sortedTeams[GAME_TEAM_COUNT];
    int sortedCounts[GAME_TEAM_COUNT];
    for (int i = 0; i < activeCount; i++)
    {
        sortedTeams[i]  = activeTeams[i];
        sortedCounts[i] = teamCounts[activeTeams[i]];
    }

    for (int i = 1; i < activeCount; i++)
    {
        int keyTeam  = sortedTeams[i];
        int keyCount = sortedCounts[i];
        int j = i - 1;
        while (j >= 0 && sortedCounts[j] < keyCount)
        {
            sortedTeams[j + 1]  = sortedTeams[j];
            sortedCounts[j + 1] = sortedCounts[j];
            j--;
        }
        sortedTeams[j + 1]  = keyTeam;
        sortedCounts[j + 1] = keyCount;
    }

    int biggestTeam   = sortedTeams[0];
    int biggestCount  = sortedCounts[0];
    int smallestTeam  = sortedTeams[activeCount - 1];
    int smallestCount = sortedCounts[activeCount - 1];

    if (biggestTeam == 0 || smallestTeam == 0 || biggestTeam == smallestTeam)
    {
        return Plugin_Continue;
    }

    int diff = biggestCount - smallestCount;
    int diffThreshold = 1;
    if (g_hDiffThreshold != null)
    {
        diffThreshold = g_hDiffThreshold.IntValue;
        if (diffThreshold < 1) diffThreshold = 1;
    }

    if (diff <= diffThreshold)
    {
        return Plugin_Continue;
    }

    bool forceBalance = (diff > diffThreshold);

    char fromTeamName[16];
    char toTeamName[16];
    AB_GetTeamName(biggestTeam,  fromTeamName, sizeof(fromTeamName));
    AB_GetTeamName(smallestTeam, toTeamName,   sizeof(toTeamName));
    char fromTeamChat[24];
    char toTeamChat[24];
    AB_GetTeamChatLabel(biggestTeam,  fromTeamChat, sizeof(fromTeamChat));
    AB_GetTeamChatLabel(smallestTeam, toTeamChat,   sizeof(toTeamChat));

    LogBalance(
        "Imbalance: RED=%d BLU=%d GREEN=%d YELLOW=%d | from=%s(%d) to=%s(%d) force=%s",
        teamCounts[TEAM_RED], teamCounts[TEAM_BLUE], teamCounts[TEAM_GREEN], teamCounts[TEAM_YELLOW],
        fromTeamName, biggestCount, toTeamName, smallestCount,
        forceBalance ? "yes" : "no"
    );
    PrintToServer(
        "[autobalance_4teams] Imbalance: RED=%d BLU=%d GREEN=%d YELLOW=%d | from=%s(%d) to=%s(%d) force=%s",
        teamCounts[TEAM_RED], teamCounts[TEAM_BLUE], teamCounts[TEAM_GREEN], teamCounts[TEAM_YELLOW],
        fromTeamName, biggestCount, toTeamName, smallestCount,
        forceBalance ? "yes" : "no"
    );

    // ------------------------------------------------------------------
    // Candidate selection.
    //
    // If forceBalance is active (diff > threshold), switch immediately:
    // pick from any human on the oversized team, regardless of alive
    // state or immunity.
    //
    // Otherwise keep normal two-pass selection:
    //  Pass 1 (strict)    : dead, below-average score, non-Engi/Medic
    //  Pass 2 (relax s/a) : any alive/score state, non-Engi/Medic
    // ------------------------------------------------------------------

    int totalScore   = 0;
    int totalPlayers = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!(forceBalance ? IsEligiblePlayerForce(i, biggestTeam) : IsEligiblePlayer(i, biggestTeam)))
        {
            continue;
        }

        totalScore += GetClientScore(i);
        totalPlayers++;
    }

    if (totalPlayers == 0)
    {
        int immuneCount = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != biggestTeam) continue;
            if (IsClientImmune(i)) immuneCount++;
        }

        LogBalance(
            "Skip balance on %s: no eligible players (force=%d, teamPlayers=%d, immune=%d)",
            fromTeamName, forceBalance ? 1 : 0, biggestCount, immuneCount
        );
        return Plugin_Continue;
    }

    float avg = float(totalScore) / float(totalPlayers);

    int candidates[MAXPLAYERS];
    int candidateCount = 0;

    if (forceBalance)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsEligiblePlayerForce(i, biggestTeam)) continue;

            candidates[candidateCount++] = i;
        }
    }
    else
    {
        // Pass 1: strict — dead, below average, no Engi/Medic.
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsEligiblePlayer(i, biggestTeam)) continue;

            TFClassType cls = TF2_GetPlayerClass(i);
            if (cls == TFClass_Engineer || cls == TFClass_Medic) continue;
            if (IsPlayerAlive(i)) continue;
            if (float(GetClientScore(i)) >= avg) continue;

            candidates[candidateCount++] = i;
        }

        // Pass 2: relax score/alive, still exclude Engi/Medic.
        if (candidateCount == 0)
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (!IsEligiblePlayer(i, biggestTeam)) continue;

                TFClassType cls = TF2_GetPlayerClass(i);
                if (cls == TFClass_Engineer || cls == TFClass_Medic) continue;

                candidates[candidateCount++] = i;
            }
        }
    }

    if (candidateCount == 0)
    {
        if (forceBalance)
        {
            LogBalance(
                "Skip balance on %s: force mode had zero candidates (teamPlayers=%d, eligible=%d)",
                fromTeamName, biggestCount, totalPlayers
            );
        }
        else
        {
            int classExcluded = 0;
            int aliveFiltered = 0;
            int scoreFiltered = 0;
            int strictWouldPass = 0;

            for (int i = 1; i <= MaxClients; i++)
            {
                if (!IsEligiblePlayer(i, biggestTeam)) continue;

                TFClassType cls = TF2_GetPlayerClass(i);
                if (cls == TFClass_Engineer || cls == TFClass_Medic)
                {
                    classExcluded++;
                    continue;
                }

                bool alive = IsPlayerAlive(i);
                bool highScore = float(GetClientScore(i)) >= avg;

                if (alive) aliveFiltered++;
                if (highScore) scoreFiltered++;
                if (!alive && !highScore) strictWouldPass++;
            }

            LogBalance(
                "Skip balance on %s: no candidates (avg=%.2f eligible=%d classExcluded=%d aliveFiltered=%d scoreFiltered=%d strictPass=%d)",
                fromTeamName, avg, totalPlayers, classExcluded, aliveFiltered, scoreFiltered, strictWouldPass
            );
        }
        return Plugin_Continue;
    }

    // Weight selection toward lowest-scoring candidates.
    // Build a cumulative-weight array where each candidate's weight is
    // (maxScore - score + 1) so the lowest scorer is most likely.
    int maxScore = 0;
    for (int i = 0; i < candidateCount; i++)
    {
        int s = GetClientScore(candidates[i]);
        if (s > maxScore) maxScore = s;
    }

    int weights[MAXPLAYERS];
    int totalWeight = 0;
    for (int i = 0; i < candidateCount; i++)
    {
        weights[i]   = maxScore - GetClientScore(candidates[i]) + 1;
        totalWeight += weights[i];
    }

    int roll = GetRandomInt(0, totalWeight - 1);
    int pick = candidates[0];
    int running = 0;
    for (int i = 0; i < candidateCount; i++)
    {
        running += weights[i];
        if (roll < running)
        {
            pick = candidates[i];
            break;
        }
    }

    LogBalance(
        "Autobalancing %N (%d) from %s to %s. score=%d avg=%.2f candidates=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount
    );
    PrintToServer(
        "[autobalance_4teams] move %N (%d) %s -> %s | score=%d avg=%.2f candidates=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount
    );

    if (GetFeatureStatus(FeatureType_Native, "FilterAlerts_MarkAutobalance") == FeatureStatus_Available)
    {
        FilterAlerts_MarkAutobalance(pick);
    }

    ChangeClientTeam(pick, smallestTeam);
    SetClientImmunity(pick, true);

    CPrintToChatAllEx(
        pick,
        "{tomato}[{purple}Gap{tomato}]{default} Sending {teamcolor}%N{default} from %s to %s",
        pick, fromTeamChat, toTeamChat
    );

    char teamColorName[24];
    AB_GetTeamColorName(smallestTeam, teamColorName, sizeof(teamColorName));
    CPrintToChatEx(pick, pick, "{lightgreen}[Server]{default} You've been autobalanced to %s{default}!", teamColorName);

    return Plugin_Continue;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static bool IsEligiblePlayer(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;
    if (IsClientImmune(client)) return false;

    return true;
}

static bool IsEligiblePlayerForce(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;
    if (IsClientImmune(client)) return false;

    return true;
}

static bool IsClientImmune(int client)
{
    float expiry = g_fImmunityExpiry[client];
    if (expiry <= 0.0) return false;

    if (GetGameTime() >= expiry)
    {
        g_fImmunityExpiry[client] = 0.0;   // Immunity has expired; clear it.
        return false;
    }

    return true;
}

static void SetClientImmunity(int client, bool immune)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) return;

    g_fImmunityExpiry[client] = immune ? (GetGameTime() + IMMUNITY_DURATION) : 0.0;
}

static int CountTeamPlayersRaw(int team)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (GetClientTeam(i) != team) continue;
        count++;
    }

    return count;
}

static int GetClientScore(int client)
{
    return GetClientFrags(client);
}

static void AB_GetTeamName(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "RED");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "BLU");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "GREEN");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "YELLOW");
        default:          strcopy(buffer, maxlen, "UNKNOWN");
    }
}

static void AB_GetTeamChatLabel(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "{red}RED{default}");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "{blue}BLU{default}");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "{green}GREEN{default}");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "{yellow}YELLOW{default}");
        default:          strcopy(buffer, maxlen, "{default}UNKNOWN");
    }
}

static void AB_GetTeamColorName(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "{red}Red");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "{blue}Blue");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "{green}Green");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "{yellow}Yellow");
        default:          strcopy(buffer, maxlen, "{default}Unknown");
    }
}

static void LogBalance(const char[] fmt, any ...)
{
    if (g_hLogEnabled == null || !g_hLogEnabled.BoolValue)
    {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFileEx(g_sLogPath, "%s", buffer);
}

static void ApplyServerBalanceCvars(bool pluginLoaded)
{
    if (g_hMpAutoteamBalance == null)
        g_hMpAutoteamBalance = FindConVar("mp_autoteambalance");

    if (g_hMpTeamsUnbalanceLimit == null)
        g_hMpTeamsUnbalanceLimit = FindConVar("mp_teams_unbalance_limit");

    if (pluginLoaded)
    {
        // Save originals before we overwrite them.
        if (g_hMpAutoteamBalance != null)
        {
            g_iSavedAutoteamBalance = g_hMpAutoteamBalance.IntValue;
            g_hMpAutoteamBalance.IntValue = 0;
        }

        if (g_hMpTeamsUnbalanceLimit != null)
        {
            g_iSavedUnbalanceLimit = g_hMpTeamsUnbalanceLimit.IntValue;
            g_hMpTeamsUnbalanceLimit.IntValue = 1;
        }
    }
    else
    {
        // Restore originals on unload.
        if (g_hMpAutoteamBalance != null)
            g_hMpAutoteamBalance.IntValue = g_iSavedAutoteamBalance;

        if (g_hMpTeamsUnbalanceLimit != null)
            g_hMpTeamsUnbalanceLimit.IntValue = g_iSavedUnbalanceLimit;
    }
}
