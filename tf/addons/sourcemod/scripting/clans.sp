#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <morecolors>
#include <whaletracker_api>

#define PLUGIN_NAME               "Clans"
#define PLUGIN_AUTHOR             "Draggy"
#define PLUGIN_VERSION            "1.0.0"
#define PLUGIN_URL                "https://kogasa.tf"

#define CLAN_CREATE_COST          100
#define INVITE_EXPIRE_SECONDS     604800
#define CLAN_NAME_MAXLEN          64
#define CLAN_TAG_MAXLEN           64
#define CLAN_TAG_STORE_MAXLEN     (CLAN_TAG_MAXLEN + 1)
#define STEAMID64_MAXLEN          32
#define SQL_STEAMID64_MAXLEN      ((STEAMID64_MAXLEN * 2) + 1)
#define SQL_CLAN_NAME_MAXLEN      ((CLAN_NAME_MAXLEN * 2) + 1)
#define SQL_CLAN_TAG_MAXLEN       ((CLAN_TAG_MAXLEN * 2) + 1)
#define CLAN_SUB_TAG_MAXLEN       64
#define CLAN_SUB_TAG_STORE_MAXLEN (CLAN_SUB_TAG_MAXLEN + 1)
#define SQL_CLAN_SUB_TAG_MAXLEN   ((CLAN_SUB_TAG_MAXLEN * 2) + 1)
#define CLAN_TAG_FORMAT_OVERHEAD  17 // Stored tag format: "[{gold}" + raw tag + "{default}]"
#define CLAN_TAG_PLAYER_MAXLEN    16
#define CLAN_TAG_ADMIN_MAXLEN     64
#define INVITE_CLEANUP_INTERVAL   300.0
#define CLAN_MENU_TIME            MENU_TIME_FOREVER

enum ClanRank
{
    ClanRank_Member = 0,
    ClanRank_Officer,
    ClanRank_Owner
};

enum PromptState
{
    Prompt_None = 0,
    Prompt_ClanCreateName,
    Prompt_ClanLeaveConfirm,
    Prompt_ClanTagChoice,
    Prompt_ClanTagInput,
    Prompt_ClanSubTagInput
};

enum InviteMenuMode
{
    InviteMenu_Accept = 0,
    InviteMenu_Deny
};

enum ClanByPlayerCols
{
    ClanByPlayerCol_Id = 0,
    ClanByPlayerCol_Name,
    ClanByPlayerCol_Tag,
    ClanByPlayerCol_Owner,
    ClanByPlayerCol_IsOpen,
    ClanByPlayerCol_CreatedAt,
    ClanByPlayerCol_Rank,
    ClanByPlayerCol_JoinedAt
};

enum PendingInviteCols
{
    PendingInviteCol_Id = 0,
    PendingInviteCol_ClanId,
    PendingInviteCol_ClanName,
    PendingInviteCol_ClanTag,
    PendingInviteCol_InvitedBy,
    PendingInviteCol_ExpiresAt
};

enum ClanMenuContextCols
{
    ClanMenuCol_ClanId = 0,
    ClanMenuCol_Rank,
    ClanMenuCol_ClanName,
    ClanMenuCol_ClanTag,
    ClanMenuCol_IsOpen,
    ClanMenuCol_InviteCount
};

enum ClanMemberListCols
{
    ClanMemberListCol_SteamId64 = 0,
    ClanMemberListCol_Rank,
    ClanMemberListCol_NameColor
};

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = "Minecraft-style clans/factions scaffold backed by SQL",
    version = PLUGIN_VERSION,
    url = PLUGIN_URL
};

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    RegPluginLibrary("clans");
    CreateNative("Clans_GetTags", Native_Clans_GetTags);
    MarkNativeAsOptional("Tags_GetTag");
    return APLRes_Success;
}

native bool Tags_GetTag(int client, const char[] steamid64, char[] buffer, int maxlen);

Database g_Database = null;
bool g_bDatabaseReady = false;
char g_sDbDriver[16];
ConVar g_cvDatabaseConfig = null;
Handle g_hInviteCleanupTimer = null;

PromptState g_PromptState[MAXPLAYERS + 1];

public void OnPluginStart()
{
    g_cvDatabaseConfig = CreateConVar("sm_clans_database", "default", "Database config name from databases.cfg to use for clans.");
    AutoExecConfig(true, "clans");

    RegConsoleCmd("sm_clan", Command_ClanMenu, "Open the clan menu.");
    RegConsoleCmd("sm_clans", Command_ClansList, "Browse clans.");
    RegConsoleCmd("sm_clancreate", Command_ClanCreate, "Create a clan.");
    RegConsoleCmd("sm_clanleave", Command_ClanLeave, "Leave your clan or delete it if you are the owner.");
    RegConsoleCmd("sm_claninvite", Command_ClanInvite, "Invite a player to your clan.");
    RegConsoleCmd("sm_clankick", Command_ClanKick, "Kick a player from your clan.");
    RegConsoleCmd("sm_clantag", Command_ClanTag, "Set your clan tag or personal sub-tag.");
    RegConsoleCmd("sm_clanjoin", Command_ClanJoin, "Join an open clan.");
    RegConsoleCmd("sm_clanparent", Command_ClanParent, "Set or clear your clan's parent relation.");
    RegConsoleCmd("sm_clanmembers", Command_ClanMembers, "Show clan members.");
    RegConsoleCmd("sm_claninfo", Command_ClanInfo, "Show clan info.");

    /* Extra owner utility so open-clan menus are actually usable. */
    RegConsoleCmd("sm_clanopen", Command_ClanOpen, "Toggle whether your clan is open to direct joins.");

    /* Chat trigger aliases for invites. */
    RegConsoleCmd("sm_accept", Command_ClanAcceptInvite, "Accept a pending clan invite.");
    RegConsoleCmd("sm_yes", Command_ClanAcceptInvite, "Accept a pending clan invite.");
    RegConsoleCmd("sm_deny", Command_ClanDenyInvite, "Deny a pending clan invite.");

    AddCommandListener(CommandListener_Say, "say");
    AddCommandListener(CommandListener_Say, "say_team");

    ConnectDatabase();
}

public void OnPluginEnd()
{
    if (g_hInviteCleanupTimer != null)
    {
        delete g_hInviteCleanupTimer;
        g_hInviteCleanupTimer = null;
    }

    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }
}

public void OnClientDisconnect(int client)
{
    ResetClientState(client);
}

void ResetClientState(int client)
{
    g_PromptState[client] = Prompt_None;
}

void ConnectDatabase()
{
    char configName[64];
    g_cvDatabaseConfig.GetString(configName, sizeof(configName));
    Database.Connect(SQL_OnDatabaseConnected, configName);
}

public void SQL_OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[Clans] Database connection failed: %s", error);
        return;
    }

    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }

    g_Database = db;
    g_Database.Driver.GetIdentifier(g_sDbDriver, sizeof(g_sDbDriver));
    g_bDatabaseReady = false;

    if (!g_Database.SetCharset("utf8mb4"))
    {
        LogError("[Clans] Failed to set utf8mb4 charset");
    }

    CreateSchemaStep(0);
}

void CreateSchemaStep(int step)
{
    if (g_Database == null)
    {
        return;
    }

    char query[1024];
    if (!BuildSchemaQuery(step, query, sizeof(query)))
    {
        g_bDatabaseReady = true;
        CleanupExpiredInvites();

        if (g_hInviteCleanupTimer == null)
        {
            g_hInviteCleanupTimer = CreateTimer(INVITE_CLEANUP_INTERVAL, Timer_CleanupExpiredInvites, 0, TIMER_REPEAT);
        }

        PrintToServer("[Clans] Database ready using driver '%s'.", g_sDbDriver);
        return;
    }

    g_Database.Query(SQL_OnSchemaStepComplete, query, step);
}

public void SQL_OnSchemaStepComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[Clans] Schema creation failed on step %d: %s", data, error);
        return;
    }

    CreateSchemaStep(data + 1);
}

bool BuildSchemaQuery(int step, char[] query, int maxlen)
{
    bool mysql = IsMySql();

    switch (step)
    {
        case 0:
        {
            if (mysql)
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clans ("
                    ... "id INT NOT NULL AUTO_INCREMENT, "
                    ... "name VARCHAR(64) NULL UNIQUE, "
                    ... "tag VARCHAR(64) NULL, "
                    ... "owner BIGINT UNSIGNED NOT NULL, "
                    ... "is_open TINYINT(1) NOT NULL DEFAULT 0, "
                    ... "created_at INT UNSIGNED NOT NULL, "
                    ... "PRIMARY KEY (id)"
                    ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
            }
            else
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clans ("
                    ... "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                    ... "name VARCHAR(64) UNIQUE NULL, "
                    ... "tag VARCHAR(64) NULL, "
                    ... "owner BIGINT UNSIGNED NOT NULL, "
                    ... "is_open TINYINT(1) NOT NULL DEFAULT 0, "
                    ... "created_at INT UNSIGNED NOT NULL"
                    ... ")");
            }
            return true;
        }
        case 1:
        {
            if (mysql)
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clan_members ("
                    ... "clan_id INT NOT NULL, "
                    ... "steamid64 BIGINT UNSIGNED NOT NULL, "
                    ... "rank TINYINT NOT NULL DEFAULT 0, "
                    ... "joined_at INT UNSIGNED NOT NULL, "
                    ... "PRIMARY KEY (clan_id, steamid64), "
                    ... "UNIQUE KEY uq_clan_members_steamid64 (steamid64)"
                    ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
            }
            else
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clan_members ("
                    ... "clan_id INT NOT NULL, "
                    ... "steamid64 BIGINT UNSIGNED NOT NULL, "
                    ... "rank TINYINT NOT NULL DEFAULT 0, "
                    ... "joined_at INT UNSIGNED NOT NULL, "
                    ... "PRIMARY KEY (clan_id, steamid64), "
                    ... "UNIQUE (steamid64)"
                    ... ")");
            }
            return true;
        }
        case 2:
        {
            if (mysql)
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clan_invites ("
                    ... "id INT NOT NULL AUTO_INCREMENT, "
                    ... "clan_id INT NOT NULL, "
                    ... "steamid64 BIGINT UNSIGNED NOT NULL, "
                    ... "invited_by BIGINT UNSIGNED NOT NULL, "
                    ... "expires_at INT UNSIGNED NOT NULL, "
                    ... "PRIMARY KEY (id)"
                    ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
            }
            else
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clan_invites ("
                    ... "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                    ... "clan_id INT NOT NULL, "
                    ... "steamid64 BIGINT UNSIGNED NOT NULL, "
                    ... "invited_by BIGINT UNSIGNED NOT NULL, "
                    ... "expires_at INT UNSIGNED NOT NULL"
                    ... ")");
            }
            return true;
        }
        case 3:
        {
            if (mysql)
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clan_relations ("
                    ... "clan_id_a INT NOT NULL, "
                    ... "clan_id_b INT NOT NULL, "
                    ... "relation_type TINYINT NOT NULL, "
                    ... "created_at INT NOT NULL"
                    ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
            }
            else
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clan_relations ("
                    ... "clan_id_a INT NOT NULL, "
                    ... "clan_id_b INT NOT NULL, "
                    ... "relation_type TINYINT NOT NULL, "
                    ... "created_at INT NOT NULL"
                    ... ")");
            }
            return true;
        }
        case 4:
        {
            if (mysql)
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clan_sub_tags ("
                    ... "clan_id INT NOT NULL, "
                    ... "steamid64 BIGINT UNSIGNED NOT NULL, "
                    ... "tag VARCHAR(64) NOT NULL, "
                    ... "created_at INT UNSIGNED NOT NULL, "
                    ... "PRIMARY KEY (clan_id, steamid64), "
                    ... "UNIQUE KEY uq_clan_sub_tags_steamid64 (steamid64)"
                    ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
            }
            else
            {
                FormatEx(query, maxlen,
                    "CREATE TABLE IF NOT EXISTS clan_sub_tags ("
                    ... "clan_id INT NOT NULL, "
                    ... "steamid64 BIGINT UNSIGNED NOT NULL, "
                    ... "tag VARCHAR(64) NOT NULL, "
                    ... "created_at INT UNSIGNED NOT NULL, "
                    ... "PRIMARY KEY (clan_id, steamid64), "
                    ... "UNIQUE (steamid64)"
                    ... ")");
            }
            return true;
        }
    }

    query[0] = '\0';
    return false;
}

bool IsMySql()
{
    return StrEqual(g_sDbDriver, "mysql", false);
}

bool EnsureDatabaseReady(int client = 0)
{
    if (g_Database != null && g_bDatabaseReady)
    {
        return true;
    }

    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Database is not ready yet. Please try again in a moment.");
    }

    return false;
}

bool GetClientSteam64(int client, char[] steamid64, int maxlen)
{
    steamid64[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    return GetClientAuthId(client, AuthId_SteamID64, steamid64, maxlen, true);
}

int FindClientBySteam64(const char[] steamid64)
{
    char current[STEAMID64_MAXLEN];

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        if (!GetClientAuthId(client, AuthId_SteamID64, current, sizeof(current), true))
        {
            continue;
        }

        if (StrEqual(current, steamid64, false))
        {
            return client;
        }
    }

    return 0;
}

void ResolvePlayerDisplayName(const char[] steamid64, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    int client = FindClientBySteam64(steamid64);
    if (client > 0)
    {
        GetClientName(client, buffer, maxlen);
        return;
    }

    if (WhaleTracker_GetLastRecordedName(steamid64, buffer, maxlen) && buffer[0] != '\0')
    {
        return;
    }

    strcopy(buffer, maxlen, steamid64);
}

int FindClientByNameQuery(const char[] query)
{
    int partialClient = 0;
    int partialCount = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));

        if (StrEqual(name, query, false))
        {
            return client;
        }

        if (StrContains(name, query, false) != -1)
        {
            partialClient = client;
            partialCount++;
        }
    }

    return (partialCount == 1) ? partialClient : 0;
}

void EscapeSql(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';

    if (g_Database == null)
    {
        strcopy(output, maxlen, input);
        return;
    }

    int written = 0;
    if (!g_Database.Escape(input, output, maxlen, written))
    {
        LogError("[Clans] Failed to escape SQL string of length %d.", strlen(input));
        strcopy(output, maxlen, input);
    }
}

void GetClanRankLabel(ClanRank rank, char[] buffer, int maxlen)
{
    if (rank >= ClanRank_Owner)
    {
        strcopy(buffer, maxlen, "Owner");
        return;
    }

    if (rank >= ClanRank_Officer)
    {
        strcopy(buffer, maxlen, "Officer");
        return;
    }

    strcopy(buffer, maxlen, "Member");
}

static bool TryGetSelectedTag(int client, const char[] steamid64, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (GetFeatureStatus(FeatureType_Native, "Tags_GetTag") != FeatureStatus_Available)
    {
        return false;
    }

    if (client > 0 && IsClientInGame(client))
    {
        return Tags_GetTag(client, "", buffer, maxlen) && buffer[0] != '\0';
    }

    return Tags_GetTag(0, steamid64, buffer, maxlen) && buffer[0] != '\0';
}

static void BuildClanDisplayTag(const char[] rawTag, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (!rawTag[0])
    {
        return;
    }

    if (rawTag[0] == '[')
    {
        strcopy(buffer, maxlen, rawTag);
        return;
    }

    FormatEx(buffer, maxlen, "[{gold}%s{default}]", rawTag);
}

static void BuildClanMemberDisplayLine(const char[] steamid64, ClanRank rank, const char[] nameColor, char[] buffer, int maxlen)
{
    char name[MAX_NAME_LENGTH * 2];
    if (!WhaleTracker_GetLastRecordedName(steamid64, name, sizeof(name)) || !name[0])
    {
        strcopy(name, sizeof(name), steamid64);
    }

    int memberClient = FindClientBySteam64(steamid64);

    char rawTag[256];
    char displayTag[256];
    if (TryGetSelectedTag(memberClient, steamid64, rawTag, sizeof(rawTag)))
    {
        BuildClanDisplayTag(rawTag, displayTag, sizeof(displayTag));
    }
    else
    {
        displayTag[0] = '\0';
    }

    char displayName[384];
    if (nameColor[0])
    {
        FormatEx(displayName, sizeof(displayName), "{%s}%s{default}", nameColor, name);
    }
    else
    {
        strcopy(displayName, sizeof(displayName), name);
    }

    char rankLabel[16];
    GetClanRankLabel(rank, rankLabel, sizeof(rankLabel));

    if (displayTag[0])
    {
        FormatEx(buffer, maxlen, "%s: %s %s", rankLabel, displayTag, displayName);
        return;
    }

    FormatEx(buffer, maxlen, "%s: %s", rankLabel, displayName);
}

static void AnnounceClanInviteToMembers(int clanId, const char[] clanName, const char[] inviterSteam, const char[] targetSteam)
{
    DataPack pack = new DataPack();
    pack.WriteString(clanName);
    pack.WriteString(inviterSteam);
    pack.WriteString(targetSteam);

    GetClanMembers(clanId, SQL_OnAnnounceClanInviteToMembers, pack);
}

static void AnnounceClanInviteAcceptedToMembers(int clanId, const char[] clanName, const char[] accepterSteam)
{
    DataPack pack = new DataPack();
    pack.WriteString(clanName);
    pack.WriteString(accepterSteam);

    GetClanMembers(clanId, SQL_OnAnnounceClanInviteAcceptedToMembers, pack);
}

static int GetAllowedMainClanTagLength(int client)
{
    int allowed = CheckCommandAccess(client, "clans_long_tag", ADMFLAG_GENERIC, true) ? CLAN_TAG_ADMIN_MAXLEN : CLAN_TAG_PLAYER_MAXLEN;
    int storageSafe = CLAN_TAG_MAXLEN - CLAN_TAG_FORMAT_OVERHEAD;

    if (allowed > storageSafe)
    {
        allowed = storageSafe;
    }

    return allowed;
}

static int GetAllowedSubClanTagLength(int client)
{
    return CheckCommandAccess(client, "clans_long_tag", ADMFLAG_GENERIC, true) ? CLAN_TAG_ADMIN_MAXLEN : CLAN_TAG_PLAYER_MAXLEN;
}

static void FormatStoredClanTag(const char[] rawTag, char[] buffer, int maxlen)
{
    FormatEx(buffer, maxlen, "[{gold}%s{default}]", rawTag);
}

static void ExtractRawClanTag(const char[] storedTag, char[] buffer, int maxlen)
{
    static const char prefix[] = "[{gold}";
    static const char suffix[] = "{default}]";

    buffer[0] = '\0';

    if (!storedTag[0])
    {
        return;
    }

    int len = strlen(storedTag);
    int prefixLen = sizeof(prefix) - 1;
    int suffixLen = sizeof(suffix) - 1;

    if (len > (prefixLen + suffixLen))
    {
        bool prefixMatch = true;
        for (int i = 0; i < prefixLen; i++)
        {
            if (storedTag[i] != prefix[i])
            {
                prefixMatch = false;
                break;
            }
        }

        bool suffixMatch = true;
        for (int i = 0; i < suffixLen; i++)
        {
            if (storedTag[(len - suffixLen) + i] != suffix[i])
            {
                suffixMatch = false;
                break;
            }
        }

        if (prefixMatch && suffixMatch)
        {
            int rawLen = len - prefixLen - suffixLen;
            int copyLen = (rawLen < (maxlen - 1)) ? rawLen : (maxlen - 1);

            for (int i = 0; i < copyLen; i++)
            {
                buffer[i] = storedTag[prefixLen + i];
            }

            buffer[copyLen] = '\0';
            return;
        }
    }

    strcopy(buffer, maxlen, storedTag);
}

static bool AppendJoinedClanTag(char[] buffer, int maxlen, const char[] tag)
{
    if (!tag[0])
    {
        return false;
    }

    if (buffer[0])
    {
        StrCat(buffer, maxlen, "|");
    }

    StrCat(buffer, maxlen, tag);
    return true;
}

static bool GetClanTagsForSteam64(const char[] steamid64, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (!steamid64[0] || !EnsureDatabaseReady())
    {
        return false;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT tag_value, tag_type FROM ("
        ... "SELECT c.tag AS tag_value, 0 AS tag_type "
        ... "FROM clan_members cm "
        ... "INNER JOIN clans c ON c.id = cm.clan_id "
        ... "WHERE cm.steamid64 = '%s' AND c.tag IS NOT NULL AND c.tag <> '' "
        ... "UNION "
        ... "SELECT cst.tag AS tag_value, 1 AS tag_type "
        ... "FROM clan_members cm "
        ... "INNER JOIN clan_sub_tags cst ON cst.clan_id = cm.clan_id "
        ... "WHERE cm.steamid64 = '%s' AND cst.tag IS NOT NULL AND cst.tag <> ''"
        ... ") tag_list "
        ... "ORDER BY tag_type ASC, tag_value ASC",
        escapedSteam,
        escapedSteam);

    DBResultSet results = SQL_Query(g_Database, query);
    if (results == null)
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to fetch clan tags for %s: %s", steamid64, error);
        return false;
    }

    bool found = false;
    char tagValue[CLAN_TAG_STORE_MAXLEN];
    char rawTag[CLAN_SUB_TAG_STORE_MAXLEN];

    while (results.FetchRow())
    {
        results.FetchString(0, tagValue, sizeof(tagValue));
        TrimString(tagValue);

        if (results.FetchInt(1) == 0)
        {
            ExtractRawClanTag(tagValue, rawTag, sizeof(rawTag));
        }
        else
        {
            strcopy(rawTag, sizeof(rawTag), tagValue);
        }

        TrimString(rawTag);
        if (!AppendJoinedClanTag(buffer, maxlen, rawTag))
        {
            continue;
        }

        found = true;
    }

    delete results;
    return found;
}

public any Native_Clans_GetTags(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int maxlen = GetNativeCell(3);

    char buffer[4096];
    char steamid64[STEAMID64_MAXLEN];
    buffer[0] = '\0';
    steamid64[0] = '\0';

    bool found = false;
    if (GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        found = GetClanTagsForSteam64(steamid64, buffer, sizeof(buffer));
    }

    SetNativeString(2, buffer, maxlen, true);
    return found;
}

void CleanupExpiredInvites()
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    int now = GetTime();
    char query[256];
    FormatEx(query, sizeof(query), "DELETE FROM clan_invites WHERE expires_at <= %d", now);
    g_Database.Query(SQL_GenericQueryCallback, query);
}

public Action Timer_CleanupExpiredInvites(Handle timer, any data)
{
    CleanupExpiredInvites();
    return Plugin_Continue;
}

stock void GetClanById(int clanId, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT id, name, tag, owner, is_open, created_at FROM clans WHERE id = %d LIMIT 1",
        clanId);
    g_Database.Query(callback, query, data);
}

void GetClanInfoById(int clanId, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT c.name, c.tag, c.owner, COUNT(cm.steamid64) "
        ... "FROM clans c "
        ... "LEFT JOIN clan_members cm ON cm.clan_id = c.id "
        ... "WHERE c.id = %d "
        ... "GROUP BY c.id, c.name, c.tag, c.owner "
        ... "LIMIT 1",
        clanId);
    g_Database.Query(callback, query, data);
}

void GetClanByPlayer(const char[] steamid64, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT c.id, c.name, c.tag, c.owner, c.is_open, c.created_at, cm.rank, cm.joined_at "
        ... "FROM clans c "
        ... "INNER JOIN clan_members cm ON cm.clan_id = c.id "
        ... "WHERE cm.steamid64 = '%s' "
        ... "LIMIT 1",
        escapedSteam);

    g_Database.Query(callback, query, data);
}

void IsPlayerInClan(const char[] steamid64, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT clan_id, rank FROM clan_members WHERE steamid64 = '%s' LIMIT 1",
        escapedSteam);
    g_Database.Query(callback, query, data);
}

stock void GetClanMembers(int clanId, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT steamid64, rank, joined_at FROM clan_members WHERE clan_id = %d ORDER BY rank DESC, joined_at ASC",
        clanId);
    g_Database.Query(callback, query, data);
}

public void SQL_OnAnnounceClanInviteToMembers(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char clanName[CLAN_NAME_MAXLEN + 1];
    char inviterSteam[STEAMID64_MAXLEN];
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(inviterSteam, sizeof(inviterSteam));
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    if (error[0])
    {
        LogError("[Clans] Invite announcement member query failed: %s", error);
        return;
    }

    if (results == null)
    {
        return;
    }

    char inviterName[MAX_NAME_LENGTH * 2];
    char targetName[MAX_NAME_LENGTH * 2];
    ResolvePlayerDisplayName(inviterSteam, inviterName, sizeof(inviterName));
    ResolvePlayerDisplayName(targetSteam, targetName, sizeof(targetName));

    while (results.FetchRow())
    {
        char memberSteam[STEAMID64_MAXLEN];
        results.FetchString(0, memberSteam, sizeof(memberSteam));

        int member = FindClientBySteam64(memberSteam);
        if (member <= 0 || !IsClientInGame(member))
        {
            continue;
        }

        PrintToChat(member, "[Clans] %s invited %s to '%s'.", inviterName, targetName, clanName);
    }
}

public void SQL_OnAnnounceClanInviteAcceptedToMembers(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char clanName[CLAN_NAME_MAXLEN + 1];
    char accepterSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(accepterSteam, sizeof(accepterSteam));
    delete pack;

    if (error[0])
    {
        LogError("[Clans] Invite accept announcement member query failed: %s", error);
        return;
    }

    if (results == null)
    {
        return;
    }

    char accepterName[MAX_NAME_LENGTH * 2];
    ResolvePlayerDisplayName(accepterSteam, accepterName, sizeof(accepterName));

    while (results.FetchRow())
    {
        char memberSteam[STEAMID64_MAXLEN];
        results.FetchString(0, memberSteam, sizeof(memberSteam));

        int member = FindClientBySteam64(memberSteam);
        if (member <= 0 || !IsClientInGame(member))
        {
            continue;
        }

        PrintToChat(member, "[Clans] %s accepted an invite to '%s'.", accepterName, clanName);
    }
}

void CreateClan(const char[] ownerSteamId64, const char[] name, int requesterUserId = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedOwner[SQL_STEAMID64_MAXLEN];
    char escapedName[SQL_CLAN_NAME_MAXLEN];
    EscapeSql(ownerSteamId64, escapedOwner, sizeof(escapedOwner));
    EscapeSql(name, escapedName, sizeof(escapedName));

    char lastInsertExpr[32];
    if (IsMySql())
    {
        strcopy(lastInsertExpr, sizeof(lastInsertExpr), "LAST_INSERT_ID()");
    }
    else
    {
        strcopy(lastInsertExpr, sizeof(lastInsertExpr), "last_insert_rowid()");
    }
    int now = GetTime();

    Transaction txn = new Transaction();

    char query[512];
    FormatEx(query, sizeof(query),
        "INSERT INTO clans (name, tag, owner, is_open, created_at) VALUES ('%s', NULL, '%s', 0, %d)",
        escapedName,
        escapedOwner,
        now);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "INSERT INTO clan_members (clan_id, steamid64, rank, joined_at) VALUES (%s, '%s', %d, %d)",
        lastInsertExpr,
        escapedOwner,
        view_as<int>(ClanRank_Owner),
        now);
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(requesterUserId);
    pack.WriteString(name);
    pack.WriteString(ownerSteamId64);

    g_Database.Execute(txn, SQLTxn_OnCreateClanSuccess, SQLTxn_OnCreateClanFailure, pack);
}

void DeleteClan(int clanId, int requesterUserId = 0, bool refundOwner = false)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    Transaction txn = new Transaction();
    char query[256];

    FormatEx(query, sizeof(query), "DELETE FROM clan_relations WHERE clan_id_a = %d OR clan_id_b = %d", clanId, clanId);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query), "DELETE FROM clan_invites WHERE clan_id = %d", clanId);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query), "DELETE FROM clan_sub_tags WHERE clan_id = %d", clanId);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query), "DELETE FROM clan_members WHERE clan_id = %d", clanId);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query), "DELETE FROM clans WHERE id = %d", clanId);
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(requesterUserId);
    pack.WriteCell(refundOwner ? 1 : 0);
    pack.WriteCell(clanId);

    g_Database.Execute(txn, SQLTxn_OnDeleteClanSuccess, SQLTxn_OnDeleteClanFailure, pack);
}

void AddClanMember(int clanId, const char[] steamid64, SQLQueryCallback callback, any data = 0, ClanRank rank = ClanRank_Member)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "INSERT INTO clan_members (clan_id, steamid64, rank, joined_at) VALUES (%d, '%s', %d, %d)",
        clanId,
        escapedSteam,
        view_as<int>(rank),
        GetTime());
    g_Database.Query(callback, query, data);
}

stock void RemoveClanMember(int clanId, const char[] steamid64, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char cleanupQuery[256];
    FormatEx(cleanupQuery, sizeof(cleanupQuery),
        "DELETE FROM clan_sub_tags WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedSteam);
    g_Database.Query(SQL_GenericQueryCallback, cleanupQuery);

    char query[256];
    FormatEx(query, sizeof(query),
        "DELETE FROM clan_members WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedSteam);
    g_Database.Query(callback, query, data);
}

void SetClanTag(int clanId, const char[] tag, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedTag[SQL_CLAN_TAG_MAXLEN];
    EscapeSql(tag, escapedTag, sizeof(escapedTag));

    char query[384];
    FormatEx(query, sizeof(query),
        "UPDATE clans SET tag = '%s' WHERE id = %d",
        escapedTag,
        clanId);
    g_Database.Query(callback, query, data);
}

void SetClanSubTag(int clanId, const char[] steamid64, const char[] tag, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    char escapedTag[SQL_CLAN_SUB_TAG_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(tag, escapedTag, sizeof(escapedTag));

    char query[384];
    FormatEx(query, sizeof(query),
        "REPLACE INTO clan_sub_tags (clan_id, steamid64, tag, created_at) VALUES (%d, '%s', '%s', %d)",
        clanId,
        escapedSteam,
        escapedTag,
        GetTime());
    g_Database.Query(callback, query, data);
}

void SetClanOpen(int clanId, bool isOpen, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[128];
    FormatEx(query, sizeof(query),
        "UPDATE clans SET is_open = %d WHERE id = %d",
        isOpen ? 1 : 0,
        clanId);
    g_Database.Query(callback, query, data);
}

void CreateInvite(int clanId, const char[] steamid64, const char[] inviter, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    char escapedInviter[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(inviter, escapedInviter, sizeof(escapedInviter));

    char query[384];
    FormatEx(query, sizeof(query),
        "INSERT INTO clan_invites (clan_id, steamid64, invited_by, expires_at) VALUES (%d, '%s', '%s', %d)",
        clanId,
        escapedSteam,
        escapedInviter,
        GetTime() + INVITE_EXPIRE_SECONDS);
    g_Database.Query(callback, query, data);
}

void DeleteInvite(int inviteId, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[128];
    FormatEx(query, sizeof(query), "DELETE FROM clan_invites WHERE id = %d", inviteId);
    g_Database.Query(callback, query, data);
}

void GetPendingInvites(const char[] steamid64, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT i.id, i.clan_id, c.name, c.tag, i.invited_by, i.expires_at "
        ... "FROM clan_invites i "
        ... "INNER JOIN clans c ON c.id = i.clan_id "
        ... "WHERE i.steamid64 = '%s' AND i.expires_at > %d "
        ... "ORDER BY i.expires_at ASC",
        escapedSteam,
        GetTime());
    g_Database.Query(callback, query, data);
}

void SetParentRelation(int clanIdA, int clanIdB, int requesterUserId = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    Transaction txn = new Transaction();
    char query[256];

    FormatEx(query, sizeof(query), "DELETE FROM clan_relations WHERE clan_id_a = %d AND relation_type = 3", clanIdA);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "INSERT INTO clan_relations (clan_id_a, clan_id_b, relation_type, created_at) VALUES (%d, %d, 3, %d)",
        clanIdA,
        clanIdB,
        GetTime());
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(requesterUserId);
    pack.WriteCell(clanIdA);
    pack.WriteCell(clanIdB);

    g_Database.Execute(txn, SQLTxn_OnSetParentSuccess, SQLTxn_OnSetParentFailure, pack);
}

void ClearParentRelation(int clanIdA, int requesterUserId = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query), "DELETE FROM clan_relations WHERE clan_id_a = %d AND relation_type = 3", clanIdA);
    g_Database.Query(SQL_OnClearParentRelation, query, requesterUserId);
}

public void SQL_GenericQueryCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[Clans] SQL query failed: %s", error);
    }
}

public Action CommandListener_Say(int client, const char[] command, int argc)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    char text[192];
    GetCmdArgString(text, sizeof(text));
    StripQuotes(text);
    TrimString(text);

    if (!text[0])
    {
        return Plugin_Continue;
    }

    if (g_PromptState[client] == Prompt_ClanCreateName)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan creation cancelled.");
            return Plugin_Handled;
        }

        g_PromptState[client] = Prompt_None;
        HandleClanCreateInput(client, text);
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanLeaveConfirm)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan deletion cancelled.");
            return Plugin_Handled;
        }

        if (StrEqual(text, "/yes", false))
        {
            g_PromptState[client] = Prompt_None;
            StartOwnerDeleteClan(client);
            return Plugin_Handled;
        }

        PrintToChat(client, "[Clans] Type /yes to confirm clan deletion or /cancel to abort.");
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanTagChoice)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan tag action cancelled.");
            return Plugin_Handled;
        }

        if (StrEqual(text, "/change", false))
        {
            g_PromptState[client] = Prompt_ClanTagInput;
            PrintToChat(client, "[Clans] Type the new clan tag in chat. Type /cancel to abort.");
            return Plugin_Handled;
        }

        if (StrEqual(text, "/sub", false))
        {
            g_PromptState[client] = Prompt_ClanSubTagInput;
            PrintToChat(client, "[Clans] Type your clan sub-tag in chat. If you already have one, this will replace it. Type /cancel to abort.");
            return Plugin_Handled;
        }

        PrintToChat(client, "[Clans] Use /cancel, /change, or /sub.");
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanTagInput)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan tag update cancelled.");
            return Plugin_Handled;
        }

        g_PromptState[client] = Prompt_None;
        StartSetMainClanTagFromInput(client, text);
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanSubTagInput)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan sub-tag update cancelled.");
            return Plugin_Handled;
        }

        g_PromptState[client] = Prompt_None;
        StartSetClanSubTagFromInput(client, text);
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

bool ValidateClanName(const char[] name)
{
    int len = strlen(name);
    return (len > 0 && len <= CLAN_NAME_MAXLEN);
}

void StartClanTagPrompt(int client)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    GetClanByPlayer(steamid64, SQL_OnClanTagPromptContext, GetClientUserId(client));
}

void StartSetMainClanTagFromInput(int client, const char[] input)
{
    char rawTag[CLAN_TAG_MAXLEN + 1];
    strcopy(rawTag, sizeof(rawTag), input);
    StripQuotes(rawTag);
    TrimString(rawTag);

    if (!rawTag[0])
    {
        PrintToChat(client, "[Clans] Tag cannot be empty.");
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(rawTag);

    GetClanByPlayer(steamid64, SQL_OnClanTagContext, pack);
}

void ShowClanMainMenu(int client, int clanId, ClanRank rank, const char[] clanName, const char[] clanTag, bool isOpen, int inviteCount)
{
    Menu menu = new Menu(MenuHandler_ClanMain);

    char title[256];
    if (clanId > 0)
    {
        char rankName[16];
        GetClanRankLabel(rank, rankName, sizeof(rankName));

        if (clanTag[0])
        {
            FormatEx(title, sizeof(title), "Clan Menu\n%s %s\nRank: %s\nJoining: %s", clanName, clanTag, rankName, isOpen ? "Open" : "Closed");
        }
        else
        {
            FormatEx(title, sizeof(title), "Clan Menu\n%s\nRank: %s\nJoining: %s", clanName, rankName, isOpen ? "Open" : "Closed");
        }

        menu.SetTitle(title);

        if (rank >= ClanRank_Owner)
        {
            char deleteLabel[64];
            FormatEx(deleteLabel, sizeof(deleteLabel), "Delete clan (+%d refund)", CLAN_CREATE_COST);
            menu.AddItem("leave", deleteLabel);
        }
        else
        {
            menu.AddItem("leave", "Leave clan");
        }

        menu.AddItem("members", "Members");
        menu.AddItem("invite", "Invite player");

        if (rank >= ClanRank_Officer)
        {
            menu.AddItem("kick", "Kick player");
        }

        if (rank >= ClanRank_Owner)
        {
            menu.AddItem("tag", "Clan tag");
            menu.AddItem("open", isOpen ? "Close clan joining" : "Open clan joining");
            menu.AddItem("parent", "Parent clan");
        }
    }
    else
    {
        if (inviteCount > 0)
        {
            FormatEx(title, sizeof(title), "Clan Menu\nYou are not in a clan\nPending invites: %d", inviteCount);
        }
        else
        {
            strcopy(title, sizeof(title), "Clan Menu\nYou are not in a clan");
        }

        menu.SetTitle(title);

        char createLabel[64];
        FormatEx(createLabel, sizeof(createLabel), "Create clan (-%d points)", CLAN_CREATE_COST);
        menu.AddItem("create", createLabel);
        menu.AddItem("join", "Join open clan");

        if (inviteCount > 0)
        {
            char acceptLabel[64];
            char denyLabel[64];

            FormatEx(acceptLabel, sizeof(acceptLabel), "Accept invite%s (%d)", (inviteCount == 1) ? "" : "s", inviteCount);
            FormatEx(denyLabel, sizeof(denyLabel), "Deny invite%s (%d)", (inviteCount == 1) ? "" : "s", inviteCount);

            menu.AddItem("accept", acceptLabel);
            menu.AddItem("deny", denyLabel);
        }
    }

    menu.AddItem("refresh", "Refresh");
    menu.Display(client, CLAN_MENU_TIME);
}

public Action Command_ClanMenu(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT clan_id FROM clan_members WHERE steamid64 = '%s' LIMIT 1) AS clan_id, "
        ... "(SELECT rank FROM clan_members WHERE steamid64 = '%s' LIMIT 1) AS rank, "
        ... "(SELECT name FROM clans WHERE id = (SELECT clan_id FROM clan_members WHERE steamid64 = '%s' LIMIT 1) LIMIT 1) AS clan_name, "
        ... "(SELECT tag FROM clans WHERE id = (SELECT clan_id FROM clan_members WHERE steamid64 = '%s' LIMIT 1) LIMIT 1) AS clan_tag, "
        ... "(SELECT is_open FROM clans WHERE id = (SELECT clan_id FROM clan_members WHERE steamid64 = '%s' LIMIT 1) LIMIT 1) AS is_open, "
        ... "(SELECT COUNT(1) FROM clan_invites WHERE steamid64 = '%s' AND expires_at > %d) AS invite_count",
        escapedSteam,
        escapedSteam,
        escapedSteam,
        escapedSteam,
        escapedSteam,
        escapedSteam,
        GetTime());

    g_Database.Query(SQL_OnClanMenuContext, query, GetClientUserId(client));
    return Plugin_Handled;
}

public Action Command_ClansList(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT c.id, c.name, c.tag, COUNT(cm.steamid64) "
        ... "FROM clans c "
        ... "LEFT JOIN clan_members cm ON cm.clan_id = c.id "
        ... "GROUP BY c.id, c.name, c.tag "
        ... "ORDER BY COUNT(cm.steamid64) DESC, c.name ASC");

    g_Database.Query(SQL_OnClansListMenu, query, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClansListMenu(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan list query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load the clan list.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClansList);
    menu.SetTitle("Clans");
    menu.ExitButton = true;

    bool added = false;
    if (results != null)
    {
        while (results.FetchRow())
        {
            int clanId = results.FetchInt(0);
            int memberCount = results.FetchInt(3);

            char name[CLAN_NAME_MAXLEN + 1];
            char tag[CLAN_TAG_STORE_MAXLEN];
            char info[16];
            char display[192];

            results.FetchString(1, name, sizeof(name));
            results.FetchString(2, tag, sizeof(tag));
            IntToString(clanId, info, sizeof(info));

            if (tag[0])
            {
                FormatEx(display, sizeof(display), "%s %s (%d)", name, tag, memberCount);
            }
            else
            {
                FormatEx(display, sizeof(display), "%s (%d)", name, memberCount);
            }

            menu.AddItem(info, display);
            added = true;
        }
    }

    if (!added)
    {
        menu.AddItem("none", "No clans found", ITEMDRAW_DISABLED);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClansList(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        int clanId = StringToInt(info);
        if (clanId > 0)
        {
            GetClanInfoById(clanId, SQL_OnClanInfoMenu, GetClientUserId(param1));
        }
    }

    return 0;
}

public void SQL_OnClanInfoMenu(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan info menu query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan info.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Clan not found.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    char ownerSteam[STEAMID64_MAXLEN];
    char ownerName[MAX_NAME_LENGTH * 2];
    char title[192];
    char line[192];

    results.FetchString(0, clanName, sizeof(clanName));
    results.FetchString(1, clanTag, sizeof(clanTag));
    results.FetchString(2, ownerSteam, sizeof(ownerSteam));
    ResolvePlayerDisplayName(ownerSteam, ownerName, sizeof(ownerName));

    Menu menu = new Menu(MenuHandler_ClanInfoMenu);
    FormatEx(title, sizeof(title), "Clan Info\n%s", clanName);
    menu.SetTitle(title);

    FormatEx(line, sizeof(line), "Owner: %s", ownerName);
    menu.AddItem("owner", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Clan tag: %s", clanTag[0] ? clanTag : "(none)");
    menu.AddItem("tag", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Member count: %d", results.FetchInt(3));
    menu.AddItem("members", line, ITEMDRAW_DISABLED);

    menu.ExitButton = true;
    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClanInfoMenu(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public void SQL_OnClanMenuContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan menu context query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load your clan menu.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        ShowClanMainMenu(client, 0, ClanRank_Member, "", "", false, 0);
        return;
    }

    int clanId = results.FetchInt(ClanMenuCol_ClanId);
    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanMenuCol_Rank));
    int inviteCount = results.FetchInt(ClanMenuCol_InviteCount);
    bool isOpen = (results.FetchInt(ClanMenuCol_IsOpen) != 0);

    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(ClanMenuCol_ClanName, clanName, sizeof(clanName));
    results.FetchString(ClanMenuCol_ClanTag, clanTag, sizeof(clanTag));

    ShowClanMainMenu(client, clanId, rank, clanName, clanTag, isOpen, inviteCount);
}

public int MenuHandler_ClanMain(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        char info[32];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "create", false))
        {
            Command_ClanCreate(client, 0);
        }
        else if (StrEqual(info, "join", false))
        {
            Command_ClanJoin(client, 0);
        }
        else if (StrEqual(info, "accept", false))
        {
            Command_ClanAcceptInvite(client, 0);
        }
        else if (StrEqual(info, "deny", false))
        {
            Command_ClanDenyInvite(client, 0);
        }
        else if (StrEqual(info, "leave", false))
        {
            Command_ClanLeave(client, 0);
        }
        else if (StrEqual(info, "members", false))
        {
            Command_ClanMembers(client, 0);
        }
        else if (StrEqual(info, "tag", false))
        {
            StartClanTagPrompt(client);
        }
        else if (StrEqual(info, "invite", false))
        {
            ShowClanInviteTargetMenu(client);
        }
        else if (StrEqual(info, "kick", false))
        {
            ShowClanKickTargetMenu(client);
        }
        else if (StrEqual(info, "open", false))
        {
            Command_ClanOpen(client, 0);
        }
        else if (StrEqual(info, "parent", false))
        {
            Command_ClanParent(client, 0);
        }
        else if (StrEqual(info, "refresh", false))
        {
            Command_ClanMenu(client, 0);
        }
    }

    return 0;
}

public Action Command_ClanMembers(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetClanByPlayer(steamid64, SQL_OnClanMembersContext, GetClientUserId(client));
    return Plugin_Handled;
}

public Action Command_ClanInfo(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Clans] Usage: sm_claninfo <player|clan name|clan tag|sub-tag>");
        return Plugin_Handled;
    }

    char input[192];
    GetCmdArgString(input, sizeof(input));
    StripQuotes(input);
    TrimString(input);

    if (!input[0])
    {
        ReplyToCommand(client, "[Clans] Usage: sm_claninfo <player|clan name|clan tag|sub-tag>");
        return Plugin_Handled;
    }

    int target = FindClientByNameQuery(input);
    if (target > 0)
    {
        char steamid64[STEAMID64_MAXLEN];
        if (!GetClientSteam64(target, steamid64, sizeof(steamid64)))
        {
            PrintToChat(client, "[Clans] Could not read that player's SteamID64.");
            return Plugin_Handled;
        }

        GetClanByPlayer(steamid64, SQL_OnClanInfoPlayerLookup, GetClientUserId(client));
        return Plugin_Handled;
    }

    char escapedInput[256];
    char formattedTag[CLAN_TAG_STORE_MAXLEN];
    char escapedFormatted[256];
    EscapeSql(input, escapedInput, sizeof(escapedInput));
    FormatStoredClanTag(input, formattedTag, sizeof(formattedTag));
    EscapeSql(formattedTag, escapedFormatted, sizeof(escapedFormatted));

    char query[1400];
    FormatEx(query, sizeof(query),
        "SELECT DISTINCT c.id "
        ... "FROM clans c "
        ... "LEFT JOIN clan_sub_tags cst ON cst.clan_id = c.id "
        ... "WHERE LOWER(c.name) = LOWER('%s') "
        ... "OR LOWER(c.tag) = LOWER('%s') "
        ... "OR LOWER(c.tag) = LOWER('%s') "
        ... "OR LOWER(cst.tag) = LOWER('%s') "
        ... "OR LOWER(c.name) LIKE LOWER('%%%s%%') "
        ... "OR LOWER(c.tag) LIKE LOWER('%%%s%%') "
        ... "OR LOWER(cst.tag) LIKE LOWER('%%%s%%') "
        ... "ORDER BY CASE "
        ... "WHEN LOWER(c.name) = LOWER('%s') THEN 0 "
        ... "WHEN LOWER(c.tag) = LOWER('%s') THEN 1 "
        ... "WHEN LOWER(c.tag) = LOWER('%s') THEN 2 "
        ... "WHEN LOWER(cst.tag) = LOWER('%s') THEN 3 "
        ... "WHEN LOWER(c.name) LIKE LOWER('%%%s%%') THEN 4 "
        ... "WHEN LOWER(c.tag) LIKE LOWER('%%%s%%') THEN 5 "
        ... "WHEN LOWER(cst.tag) LIKE LOWER('%%%s%%') THEN 6 "
        ... "ELSE 7 END, c.id ASC "
        ... "LIMIT 1",
        escapedInput,
        escapedInput,
        escapedFormatted,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedFormatted,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedInput);

    g_Database.Query(SQL_OnClanInfoSearchLookup, query, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanInfoPlayerLookup(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan info player lookup failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan info.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] That player is not in a clan.");
        return;
    }

    GetClanInfoById(results.FetchInt(ClanByPlayerCol_Id), SQL_OnClanInfoById, GetClientUserId(client));
}

public void SQL_OnClanInfoSearchLookup(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan info search lookup failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan info.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] No clan matched that query.");
        return;
    }

    GetClanInfoById(results.FetchInt(0), SQL_OnClanInfoById, GetClientUserId(client));
}

public void SQL_OnClanInfoById(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan info query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan info.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Clan not found.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    char ownerSteam[STEAMID64_MAXLEN];
    char ownerName[MAX_NAME_LENGTH * 2];

    results.FetchString(0, clanName, sizeof(clanName));
    results.FetchString(1, clanTag, sizeof(clanTag));
    results.FetchString(2, ownerSteam, sizeof(ownerSteam));
    ResolvePlayerDisplayName(ownerSteam, ownerName, sizeof(ownerName));

    CPrintToChat(client, "{default}[Clans] %s", clanName);
    CPrintToChat(client, "{default}[Clans] Owner: %s", ownerName);
    CPrintToChat(client, "{default}[Clans] Clan tag: %s", clanTag[0] ? clanTag : "(none)");
    CPrintToChat(client, "{default}[Clans] Member count: %d", results.FetchInt(3));
}

public void SQL_OnClanMembersContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan members context query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan members.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(ClanByPlayerCol_Name, clanName, sizeof(clanName));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT cm.steamid64, cm.rank, COALESCE(fnc.color, '') "
        ... "FROM clan_members cm "
        ... "LEFT JOIN filters_namecolors fnc ON fnc.steamid = cm.steamid64 "
        ... "WHERE cm.clan_id = %d "
        ... "ORDER BY cm.rank DESC, cm.joined_at ASC",
        clanId);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(clanName);

    g_Database.Query(SQL_OnClanMembersList, query, pack);
}

public void SQL_OnClanMembersList(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan members list query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan members.");
        return;
    }

    CPrintToChat(client, "{default}[Clans] Members of %s:", clanName);

    ArrayList onlineMembers = new ArrayList(ByteCountToCells(512));
    bool printedAny = false;

    if (results != null)
    {
        while (results.FetchRow())
        {
            char steamid64[STEAMID64_MAXLEN];
            char nameColor[64];
            results.FetchString(ClanMemberListCol_SteamId64, steamid64, sizeof(steamid64));
            results.FetchString(ClanMemberListCol_NameColor, nameColor, sizeof(nameColor));

            char line[512];
            BuildClanMemberDisplayLine(steamid64, view_as<ClanRank>(results.FetchInt(ClanMemberListCol_Rank)), nameColor, line, sizeof(line));
            CPrintToChat(client, "{default}[Clans] %s", line);
            printedAny = true;

            if (FindClientBySteam64(steamid64) > 0)
            {
                onlineMembers.PushString(line);
            }
        }
    }

    if (!printedAny)
    {
        CPrintToChat(client, "{default}[Clans] None.");
    }

    CPrintToChat(client, "{default}[Clans] Online members:");

    if (onlineMembers.Length <= 0)
    {
        CPrintToChat(client, "{default}[Clans] None.");
        delete onlineMembers;
        return;
    }

    char line[512];
    for (int i = 0; i < onlineMembers.Length; i++)
    {
        onlineMembers.GetString(i, line, sizeof(line));
        CPrintToChat(client, "{default}[Clans] %s", line);
    }

    delete onlineMembers;
}

void StartSetClanSubTagFromInput(int client, const char[] input)
{
    char rawTag[CLAN_SUB_TAG_MAXLEN + 1];
    strcopy(rawTag, sizeof(rawTag), input);
    StripQuotes(rawTag);
    TrimString(rawTag);

    if (!rawTag[0])
    {
        PrintToChat(client, "[Clans] Sub-tag cannot be empty.");
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(rawTag);
    pack.WriteString(steamid64);

    GetClanByPlayer(steamid64, SQL_OnClanSubTagContext, pack);
}

void HandleClanCreateInput(int client, const char[] name)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    strcopy(clanName, sizeof(clanName), name);
    TrimString(clanName);

    if (!ValidateClanName(clanName))
    {
        PrintToChat(client, "[Clans] Clan names must be between 1 and %d characters.", CLAN_NAME_MAXLEN);
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    char escapedName[SQL_CLAN_NAME_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(clanName, escapedName, sizeof(escapedName));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clan_members WHERE steamid64 = '%s') AS in_clan, "
        ... "(SELECT COUNT(1) FROM clans WHERE name = '%s') AS name_taken",
        escapedSteam,
        escapedName);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(clanName);

    g_Database.Query(SQL_OnClanCreateValidate, query, pack);
}

public void SQL_OnClanTagPromptContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan tag prompt context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));
    char currentTag[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(ClanByPlayerCol_Tag, currentTag, sizeof(currentTag));
    TrimString(currentTag);

    if (!currentTag[0])
    {
        if (rank < ClanRank_Owner)
        {
            PrintToChat(client, "[Clans] Your clan owner must set a main clan tag before members can add sub-tags.");
            return;
        }

        g_PromptState[client] = Prompt_ClanTagInput;
        PrintToChat(client, "[Clans] Type your clan tag in chat. Type /cancel to abort.");
        return;
    }

    g_PromptState[client] = Prompt_ClanTagChoice;
    PrintToChat(client, "[Clans] Your clan already has a tag; use /cancel to cancel, /change to change the tag, and /sub to add an additional tag to your clan");
}

public Action Command_ClanCreate(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    IsPlayerInClan(steamid64, SQL_OnClanCreateInitialCheck, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanCreateInitialCheck(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Create initial check failed: %s", error);
        PrintToChat(client, "[Clans] Failed to check your clan state.");
        return;
    }

    if (results != null && results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    g_PromptState[client] = Prompt_ClanCreateName;
    PrintToChat(client, "[Clans] Type your clan name in chat. Type /cancel to abort.");
}

public void SQL_OnClanCreateValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Create validation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate clan creation.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Failed to validate clan creation.");
        return;
    }

    int inClan = results.FetchInt(0);
    int nameTaken = results.FetchInt(1);

    if (inClan > 0)
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    if (nameTaken > 0)
    {
        PrintToChat(client, "[Clans] That clan name is already taken.");
        return;
    }

    if (!WhaleTracker_SpendBonusPoints(client, CLAN_CREATE_COST))
    {
        PrintToChat(client, "[Clans] You need %d bonus points to create a clan.", CLAN_CREATE_COST);
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        WhaleTracker_GiveBonusPoints(client, CLAN_CREATE_COST);
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    CreateClan(steamid64, clanName, userId);
}

public void SQLTxn_OnCreateClanSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char ownerSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(ownerSteam, sizeof(ownerSteam));
    delete pack;

    int clanId = 0;
    if (numQueries > 0)
    {
        clanId = results[0].InsertId;
    }

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Clan '%s' created successfully. (ID %d)", clanName, clanId);
    }
}

public void SQLTxn_OnCreateClanFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char ownerSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(ownerSteam, sizeof(ownerSteam));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        WhaleTracker_GiveBonusPoints(client, CLAN_CREATE_COST);

        if (StrContains(error, "Duplicate", false) != -1 || StrContains(error, "UNIQUE", false) != -1)
        {
            PrintToChat(client, "[Clans] That clan name is already taken.");
        }
        else
        {
            PrintToChat(client, "[Clans] Failed to create clan '%s'.", clanName);
        }
    }

    LogError("[Clans] CreateClan transaction failed (query %d): %s", failIndex, error);
}

public Action Command_ClanLeave(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetClanByPlayer(steamid64, SQL_OnClanLeaveContext, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanLeaveContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Leave context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));

    if (rank >= ClanRank_Owner)
    {
        g_PromptState[client] = Prompt_ClanLeaveConfirm;
        PrintToChat(client, "[Clans] You are the clan owner. Type /yes to delete the clan and refund %d bonus points, or /cancel to abort.", CLAN_CREATE_COST);
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(ClanByPlayerCol_Name, clanName, sizeof(clanName));

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    Transaction txn = new Transaction();
    char query[256];

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_sub_tags WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedSteam);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_members WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedSteam);
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(clanName);

    g_Database.Execute(txn, SQL_OnClanLeaveSuccess, SQL_OnClanLeaveFailure, pack);
}

void StartOwnerDeleteClan(int client)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    GetClanByPlayer(steamid64, SQL_OnOwnerDeleteClanContext, GetClientUserId(client));
}

public void SQL_OnOwnerDeleteClanContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Owner delete context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] You are no longer the clan owner.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    DeleteClan(clanId, GetClientUserId(client), true);
}

public void SQL_OnClanLeaveSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    PrintToChat(client, "[Clans] You left '%s'.", clanName);
}

public void SQL_OnClanLeaveFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Failed to leave your clan.");
    }

    LogError("[Clans] Leave clan transaction failed while leaving '%s' (query %d): %s", clanName, failIndex, error);
}

public void SQLTxn_OnDeleteClanSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    bool refundOwner = (pack.ReadCell() != 0);
    int clanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        if (refundOwner)
        {
            WhaleTracker_GiveBonusPoints(client, CLAN_CREATE_COST);
        }

        PrintToChat(client, "[Clans] Clan %d deleted.", clanId);
    }
}

public void SQLTxn_OnDeleteClanFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    pack.ReadCell();
    int clanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Failed to delete clan %d.", clanId);
    }

    LogError("[Clans] DeleteClan transaction failed (query %d): %s", failIndex, error);
}

void StartClanInviteToTarget(int client, int target)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    if (target <= 0 || target > MaxClients || !IsClientInGame(target) || IsFakeClient(target))
    {
        PrintToChat(client, "[Clans] That player is not available.");
        return;
    }

    if (target == client)
    {
        PrintToChat(client, "[Clans] You cannot invite yourself.");
        return;
    }

    char inviterSteam[STEAMID64_MAXLEN];
    char targetSteam[STEAMID64_MAXLEN];

    if (!GetClientSteam64(client, inviterSteam, sizeof(inviterSteam)) || !GetClientSteam64(target, targetSteam, sizeof(targetSteam)))
    {
        PrintToChat(client, "[Clans] Failed to read a SteamID64.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));
    pack.WriteString(targetSteam);

    GetClanByPlayer(inviterSteam, SQL_OnClanInviteInviterContext, pack);
}

void ShowClanInviteTargetMenu(int client)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanInviteTarget);
    menu.SetTitle("Invite player to clan");
    menu.ExitBackButton = true;

    bool added = false;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (target == client || !IsClientInGame(target) || IsFakeClient(target))
        {
            continue;
        }

        char steamid64[STEAMID64_MAXLEN];
        if (!GetClientSteam64(target, steamid64, sizeof(steamid64)))
        {
            continue;
        }

        char targetName[MAX_NAME_LENGTH];
        GetClientName(target, targetName, sizeof(targetName));

        menu.AddItem(steamid64, targetName);
        added = true;
    }

    if (!added)
    {
        menu.AddItem("none", "No valid players online", ITEMDRAW_DISABLED);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClanInviteTarget(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanMenu(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        char steamid64[STEAMID64_MAXLEN];
        menu.GetItem(param2, steamid64, sizeof(steamid64));

        int target = FindClientBySteam64(steamid64);
        if (target <= 0)
        {
            PrintToChat(param1, "[Clans] That player is no longer available.");
            ShowClanInviteTargetMenu(param1);
            return 0;
        }

        StartClanInviteToTarget(param1, target);
    }

    return 0;
}

public Action Command_ClanInvite(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Clans] Usage: sm_claninvite <target>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    int target = FindTarget(client, arg, true, false);
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    StartClanInviteToTarget(client, target);
    return Plugin_Handled;
}

public void SQL_OnClanInviteInviterContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int inviterUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int inviter = GetClientOfUserId(inviterUserId);
    if (inviter <= 0 || !IsClientInGame(inviter))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Invite clan lookup failed: %s", error);
        PrintToChat(inviter, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(inviter, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(ClanByPlayerCol_Name, clanName, sizeof(clanName));

    char escapedTarget[SQL_STEAMID64_MAXLEN];
    EscapeSql(targetSteam, escapedTarget, sizeof(escapedTarget));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clan_members WHERE steamid64 = '%s') AS in_clan, "
        ... "(SELECT COUNT(1) FROM clan_invites WHERE clan_id = %d AND steamid64 = '%s' AND expires_at > %d) AS invite_exists",
        escapedTarget,
        clanId,
        escapedTarget,
        GetTime());

    DataPack next = new DataPack();
    next.WriteCell(inviterUserId);
    next.WriteCell(targetUserId);
    next.WriteCell(clanId);
    next.WriteString(clanName);
    next.WriteString(targetSteam);

    g_Database.Query(SQL_OnClanInviteTargetValidate, query, next);
}

public void SQL_OnClanInviteTargetValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int inviterUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int inviter = GetClientOfUserId(inviterUserId);
    if (inviter <= 0 || !IsClientInGame(inviter))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Invite target validation failed: %s", error);
        PrintToChat(inviter, "[Clans] Failed to validate the invite target.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(inviter, "[Clans] Failed to validate the invite target.");
        return;
    }

    if (results.FetchInt(0) > 0)
    {
        PrintToChat(inviter, "[Clans] That player is already in a clan.");
        return;
    }

    if (results.FetchInt(1) > 0)
    {
        PrintToChat(inviter, "[Clans] That player already has a pending invite from your clan.");
        return;
    }

    char inviterSteam[STEAMID64_MAXLEN];
    if (!GetClientSteam64(inviter, inviterSteam, sizeof(inviterSteam)))
    {
        PrintToChat(inviter, "[Clans] Could not read your SteamID64.");
        return;
    }

    DataPack next = new DataPack();
    next.WriteCell(inviterUserId);
    next.WriteCell(targetUserId);
    next.WriteCell(clanId);
    next.WriteString(clanName);
    next.WriteString(targetSteam);
    next.WriteString(inviterSteam);

    CreateInvite(clanId, targetSteam, inviterSteam, SQL_OnClanInviteCreated, next);
}

public void SQL_OnClanInviteCreated(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int inviterUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char targetSteam[STEAMID64_MAXLEN];
    char inviterSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(targetSteam, sizeof(targetSteam));
    pack.ReadString(inviterSteam, sizeof(inviterSteam));
    delete pack;

    int inviter = GetClientOfUserId(inviterUserId);
    int target = GetClientOfUserId(targetUserId);

    if (error[0])
    {
        if (inviter > 0 && IsClientInGame(inviter))
        {
            PrintToChat(inviter, "[Clans] Failed to create the invite.");
        }
        LogError("[Clans] CreateInvite failed: %s", error);
        return;
    }

    if (inviter > 0 && IsClientInGame(inviter))
    {
        char targetName[MAX_NAME_LENGTH];
        ResolvePlayerDisplayName(targetSteam, targetName, sizeof(targetName));
        PrintToChat(inviter, "[Clans] Invite sent to %s for '%s'.", targetName, clanName);
    }

    if (target > 0 && IsClientInGame(target))
    {
        char inviterName[MAX_NAME_LENGTH];
        ResolvePlayerDisplayName(inviterSteam, inviterName, sizeof(inviterName));
        PrintToChat(target, "[Clans] %s invited you to join '%s'. Type !accept or !yes to accept, or !deny to decline.", inviterName, clanName);
    }

    AnnounceClanInviteToMembers(clanId, clanName, inviterSteam, targetSteam);
}

void StartClanKickTarget(int client, int target)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    if (target <= 0 || target > MaxClients || !IsClientInGame(target) || IsFakeClient(target))
    {
        PrintToChat(client, "[Clans] That player is not available.");
        return;
    }

    if (target == client)
    {
        PrintToChat(client, "[Clans] Use sm_clanleave to leave your clan.");
        return;
    }

    char actorSteam[STEAMID64_MAXLEN];
    char targetSteam[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, actorSteam, sizeof(actorSteam)) || !GetClientSteam64(target, targetSteam, sizeof(targetSteam)))
    {
        PrintToChat(client, "[Clans] Failed to read a SteamID64.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));
    pack.WriteString(targetSteam);

    GetClanByPlayer(actorSteam, SQL_OnClanKickActorContext, pack);
}

void ShowClanKickTargetMenu(int client)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    GetClanByPlayer(steamid64, SQL_OnClanKickMenuContext, GetClientUserId(client));
}

public void SQL_OnClanKickMenuContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick menu context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load kick targets.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    ClanRank actorRank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));

    if (actorRank < ClanRank_Officer)
    {
        PrintToChat(client, "[Clans] Only officers and owners can kick members.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(view_as<int>(actorRank));

    GetClanMembers(clanId, SQL_OnClanKickMenuMembers, pack);
}

public void SQL_OnClanKickMenuMembers(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    ClanRank actorRank = view_as<ClanRank>(pack.ReadCell());
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick menu member query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load kick targets.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanKickTarget);
    menu.SetTitle("Kick clan member");
    menu.ExitBackButton = true;

    bool added = false;
    while (results != null && results.FetchRow())
    {
        char memberSteam[STEAMID64_MAXLEN];
        results.FetchString(0, memberSteam, sizeof(memberSteam));

        int target = FindClientBySteam64(memberSteam);
        if (target <= 0 || target == client)
        {
            continue;
        }

        ClanRank targetRank = view_as<ClanRank>(results.FetchInt(1));
        if (targetRank >= ClanRank_Owner)
        {
            continue;
        }

        if (actorRank == ClanRank_Officer && targetRank >= ClanRank_Officer)
        {
            continue;
        }

        char targetName[MAX_NAME_LENGTH];
        char targetRankName[16];
        char display[128];

        ResolvePlayerDisplayName(memberSteam, targetName, sizeof(targetName));
        GetClanRankLabel(targetRank, targetRankName, sizeof(targetRankName));
        FormatEx(display, sizeof(display), "%s (%s)", targetName, targetRankName);

        menu.AddItem(memberSteam, display);
        added = true;
    }

    if (!added)
    {
        menu.AddItem("none", "No kickable online members", ITEMDRAW_DISABLED);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClanKickTarget(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanMenu(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        char steamid64[STEAMID64_MAXLEN];
        menu.GetItem(param2, steamid64, sizeof(steamid64));

        int target = FindClientBySteam64(steamid64);
        if (target <= 0)
        {
            PrintToChat(param1, "[Clans] That player is no longer available.");
            ShowClanKickTargetMenu(param1);
            return 0;
        }

        StartClanKickTarget(param1, target);
    }

    return 0;
}

public Action Command_ClanKick(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Clans] Usage: sm_clankick <target>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    int target = FindTarget(client, arg, true, false);
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    StartClanKickTarget(client, target);
    return Plugin_Handled;
}

public void SQL_OnClanKickActorContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int actor = GetClientOfUserId(actorUserId);
    if (actor <= 0 || !IsClientInGame(actor))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick actor context failed: %s", error);
        PrintToChat(actor, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(actor, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    ClanRank actorRank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));

    if (actorRank < ClanRank_Officer)
    {
        PrintToChat(actor, "[Clans] Only officers and owners can kick members.");
        return;
    }

    char escapedTarget[SQL_STEAMID64_MAXLEN];
    EscapeSql(targetSteam, escapedTarget, sizeof(escapedTarget));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT rank FROM clan_members WHERE clan_id = %d AND steamid64 = '%s' LIMIT 1",
        clanId,
        escapedTarget);

    DataPack next = new DataPack();
    next.WriteCell(actorUserId);
    next.WriteCell(targetUserId);
    next.WriteCell(clanId);
    next.WriteCell(view_as<int>(actorRank));
    next.WriteString(targetSteam);

    g_Database.Query(SQL_OnClanKickTargetValidate, query, next);
}

public void SQL_OnClanKickTargetValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int clanId = pack.ReadCell();
    ClanRank actorRank = view_as<ClanRank>(pack.ReadCell());
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int actor = GetClientOfUserId(actorUserId);
    if (actor <= 0 || !IsClientInGame(actor))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick target validation failed: %s", error);
        PrintToChat(actor, "[Clans] Failed to validate the kick target.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(actor, "[Clans] That player is not in your clan.");
        return;
    }

    ClanRank targetRank = view_as<ClanRank>(results.FetchInt(0));

    if (targetRank >= ClanRank_Owner)
    {
        PrintToChat(actor, "[Clans] You cannot kick the clan owner.");
        return;
    }

    if (actorRank == ClanRank_Officer && targetRank >= ClanRank_Officer)
    {
        PrintToChat(actor, "[Clans] Officers can only kick regular members.");
        return;
    }

    char escapedTarget[SQL_STEAMID64_MAXLEN];
    EscapeSql(targetSteam, escapedTarget, sizeof(escapedTarget));

    Transaction txn = new Transaction();
    char query[256];

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_sub_tags WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedTarget);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_members WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedTarget);
    txn.AddQuery(query);

    DataPack next = new DataPack();
    next.WriteCell(actorUserId);
    next.WriteCell(targetUserId);
    next.WriteString(targetSteam);

    g_Database.Execute(txn, SQL_OnClanKickSuccess, SQL_OnClanKickFailure, next);
}

public void SQL_OnClanKickSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int actor = GetClientOfUserId(actorUserId);
    int target = GetClientOfUserId(targetUserId);

    char targetName[MAX_NAME_LENGTH];
    ResolvePlayerDisplayName(targetSteam, targetName, sizeof(targetName));

    if (actor > 0 && IsClientInGame(actor))
    {
        PrintToChat(actor, "[Clans] You kicked %s from the clan.", targetName);
    }

    if (target > 0 && IsClientInGame(target))
    {
        PrintToChat(target, "[Clans] You were kicked from your clan.");
    }
}

public void SQL_OnClanKickFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    pack.ReadCell();
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int actor = GetClientOfUserId(actorUserId);
    if (actor > 0 && IsClientInGame(actor))
    {
        PrintToChat(actor, "[Clans] Failed to kick that player.");
    }

    LogError("[Clans] Kick transaction failed for %s (query %d): %s", targetSteam, failIndex, error);
}

public Action Command_ClanTag(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        StartClanTagPrompt(client);
        return Plugin_Handled;
    }

    char rawTag[CLAN_TAG_MAXLEN + 1];
    GetCmdArgString(rawTag, sizeof(rawTag));
    StartSetMainClanTagFromInput(client, rawTag);
    return Plugin_Handled;
}

public void SQL_OnClanTagContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char rawTag[CLAN_TAG_MAXLEN + 1];
    pack.ReadString(rawTag, sizeof(rawTag));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Tag context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only the clan owner can set or change the main clan tag.");
        return;
    }

    int allowed = GetAllowedMainClanTagLength(client);
    if (strlen(rawTag) > allowed)
    {
        PrintToChat(client, "[Clans] Tag is too long. Max length: %d.", allowed);
        return;
    }

    char formattedTag[CLAN_TAG_STORE_MAXLEN];
    FormatStoredClanTag(rawTag, formattedTag, sizeof(formattedTag));

    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    char escapedTag[SQL_CLAN_TAG_MAXLEN];
    EscapeSql(formattedTag, escapedTag, sizeof(escapedTag));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT COUNT(1) FROM clans WHERE tag = '%s' AND id != %d",
        escapedTag,
        clanId);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(clanId);
    next.WriteString(formattedTag);

    g_Database.Query(SQL_OnClanTagUniqueCheck, query, next);
}

public void SQL_OnClanTagUniqueCheck(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char formattedTag[CLAN_TAG_STORE_MAXLEN];
    pack.ReadString(formattedTag, sizeof(formattedTag));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Tag uniqueness check failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate the clan tag.");
        return;
    }

    if (results != null && results.FetchRow() && results.FetchInt(0) > 0)
    {
        PrintToChat(client, "[Clans] That clan tag is already taken.");
        return;
    }

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(formattedTag);

    SetClanTag(clanId, formattedTag, SQL_OnClanTagSet, next);
}

public void SQL_OnClanTagSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char formattedTag[CLAN_TAG_MAXLEN + 1];
    pack.ReadString(formattedTag, sizeof(formattedTag));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Set tag failed: %s", error);
        PrintToChat(client, "[Clans] Failed to set the clan tag.");
        return;
    }

    PrintToChat(client, "[Clans] Clan tag updated to %s", formattedTag);
}

public void SQL_OnClanSubTagContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char rawTag[CLAN_SUB_TAG_MAXLEN + 1];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(rawTag, sizeof(rawTag));
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Sub-tag context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    char currentClanTag[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(ClanByPlayerCol_Tag, currentClanTag, sizeof(currentClanTag));
    TrimString(currentClanTag);

    if (!currentClanTag[0])
    {
        PrintToChat(client, "[Clans] Your clan must have a main clan tag before members can use sub-tags.");
        return;
    }

    int allowed = GetAllowedSubClanTagLength(client);
    if (strlen(rawTag) > allowed)
    {
        PrintToChat(client, "[Clans] Sub-tag is too long. Max length: %d.", allowed);
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    char escapedTag[SQL_CLAN_SUB_TAG_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(rawTag, escapedTag, sizeof(escapedTag));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT COUNT(1) FROM clan_sub_tags WHERE tag = '%s' AND steamid64 != '%s'",
        escapedTag,
        escapedSteam);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(clanId);
    next.WriteString(rawTag);
    next.WriteString(steamid64);

    g_Database.Query(SQL_OnClanSubTagUniqueCheck, query, next);
}

public void SQL_OnClanSubTagUniqueCheck(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char rawTag[CLAN_SUB_TAG_MAXLEN + 1];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(rawTag, sizeof(rawTag));
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Sub-tag uniqueness check failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate your clan sub-tag.");
        return;
    }

    if (results != null && results.FetchRow() && results.FetchInt(0) > 0)
    {
        PrintToChat(client, "[Clans] That clan sub-tag is already taken.");
        return;
    }

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(rawTag);

    SetClanSubTag(clanId, steamid64, rawTag, SQL_OnClanSubTagSet, next);
}

public void SQL_OnClanSubTagSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char rawTag[CLAN_SUB_TAG_MAXLEN + 1];
    pack.ReadString(rawTag, sizeof(rawTag));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Set sub-tag failed: %s", error);
        PrintToChat(client, "[Clans] Failed to set your clan sub-tag.");
        return;
    }

    PrintToChat(client, "[Clans] Clan sub-tag updated to '%s'.", rawTag);
}

public Action Command_ClanOpen(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    int requestedState = -1;
    if (args >= 1)
    {
        char arg[8];
        GetCmdArg(1, arg, sizeof(arg));
        requestedState = (StringToInt(arg) != 0) ? 1 : 0;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetClanByPlayer(steamid64, SQL_OnClanOpenContext, requestedState == -1 ? (GetClientUserId(client) * 10) + 9 : (GetClientUserId(client) * 10) + requestedState);
    return Plugin_Handled;
}

public void SQL_OnClanOpenContext(Database db, DBResultSet results, const char[] error, any data)
{
    int userId = data / 10;
    int encoded = data % 10;
    int requestedState = (encoded == 9) ? -1 : encoded;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan open context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only the clan owner can change join settings.");
        return;
    }

    bool newOpen = (requestedState == -1) ? (results.FetchInt(ClanByPlayerCol_IsOpen) == 0) : (requestedState != 0);
    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    DataPack pack = new DataPack();
    pack.WriteCell(userId);
    pack.WriteCell(newOpen ? 1 : 0);

    SetClanOpen(clanId, newOpen, SQL_OnClanOpenSet, pack);
}

public void SQL_OnClanOpenSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    bool isOpen = (pack.ReadCell() != 0);
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Set clan open failed: %s", error);
        PrintToChat(client, "[Clans] Failed to update open-clan settings.");
        return;
    }

    PrintToChat(client, "[Clans] Clan join setting updated: %s.", isOpen ? "open" : "closed");
}

public Action Command_ClanJoin(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    IsPlayerInClan(steamid64, SQL_OnClanJoinMembershipCheck, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanJoinMembershipCheck(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Join membership check failed: %s", error);
        PrintToChat(client, "[Clans] Failed to check your clan state.");
        return;
    }

    if (results != null && results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query), "SELECT id, name, tag FROM clans WHERE is_open = 1 ORDER BY name ASC");
    g_Database.Query(SQL_OnClanJoinOpenList, query, GetClientUserId(client));
}

public void SQL_OnClanJoinOpenList(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Join open list failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load open clans.");
        return;
    }

    Menu menu = new Menu(MenuHandler_JoinOpenClan);
    menu.SetTitle("Join Open Clan");

    if (results == null || results.RowCount <= 0)
    {
        menu.AddItem("none", "No open clans available", ITEMDRAW_DISABLED);
        menu.Display(client, CLAN_MENU_TIME);
        return;
    }

    char info[16];
    char name[CLAN_NAME_MAXLEN + 1];
    while (results.FetchRow())
    {
        int clanId = results.FetchInt(0);
        results.FetchString(1, name, sizeof(name));
        IntToString(clanId, info, sizeof(info));
        menu.AddItem(info, name);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_JoinOpenClan(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        int clanId = StringToInt(info);
        if (clanId > 0)
        {
            StartJoinOpenClan(param1, clanId);
        }
    }

    return 0;
}

void StartJoinOpenClan(int client, int clanId)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[768];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clan_members WHERE steamid64 = '%s') AS in_clan, "
        ... "(SELECT COUNT(1) FROM clans WHERE id = %d AND is_open = 1) AS clan_open, "
        ... "(SELECT name FROM clans WHERE id = %d LIMIT 1) AS clan_name",
        escapedSteam,
        clanId,
        clanId);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(clanId);
    pack.WriteString(steamid64);

    g_Database.Query(SQL_OnJoinOpenClanValidate, query, pack);
}

public void SQL_OnJoinOpenClanValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Join validation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate that clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Failed to validate that clan.");
        return;
    }

    if (results.FetchInt(0) > 0)
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    if (results.FetchInt(1) <= 0)
    {
        PrintToChat(client, "[Clans] That clan is no longer open.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(2, clanName, sizeof(clanName));

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(clanName);

    AddClanMember(clanId, steamid64, SQL_OnJoinOpenClanSuccess, next, ClanRank_Member);
}

public void SQL_OnJoinOpenClanSuccess(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        if (StrContains(error, "Duplicate", false) != -1 || StrContains(error, "UNIQUE", false) != -1)
        {
            PrintToChat(client, "[Clans] You are already in a clan.");
        }
        else
        {
            PrintToChat(client, "[Clans] Failed to join '%s'.", clanName);
        }
        LogError("[Clans] Join open clan failed: %s", error);
        return;
    }

    PrintToChat(client, "[Clans] You joined '%s'.", clanName);
}

public Action Command_ClanParent(int client, int args)
{
    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT clan_id, rank FROM clan_members WHERE steamid64 = '%s' LIMIT 1",
        escapedSteam);

    g_Database.Query(SQL_OnClanParentContext, query, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanParentContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Parent context query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load parent-clan data.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int ownerClanId = results.FetchInt(0);
    ClanRank rank = view_as<ClanRank>(results.FetchInt(1));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only clan owners can manage parent relations.");
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT id, name, tag FROM clans WHERE is_open = 1 AND id <> %d ORDER BY name ASC",
        ownerClanId);

    g_Database.Query(SQL_OnClanParentMenuList, query, GetClientUserId(client));
}

public void SQL_OnClanParentMenuList(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Parent menu query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load open clans.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanParent);
    menu.SetTitle("Choose parent clan");
    menu.AddItem("clear", "Clear parent relation");

    bool added = false;
    while (results != null && results.FetchRow())
    {
        int clanId = results.FetchInt(0);

        char info[16];
        IntToString(clanId, info, sizeof(info));

        char clanName[CLAN_NAME_MAXLEN + 1];
        char clanTag[CLAN_TAG_STORE_MAXLEN];
        char display[160];

        results.FetchString(1, clanName, sizeof(clanName));
        results.FetchString(2, clanTag, sizeof(clanTag));

        if (clanTag[0])
        {
            FormatEx(display, sizeof(display), "%s %s", clanName, clanTag);
        }
        else
        {
            strcopy(display, sizeof(display), clanName);
        }

        menu.AddItem(info, display);
        added = true;
    }

    if (!added)
    {
        menu.AddItem("noop", "No open clans available", ITEMDRAW_DISABLED);
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClanParent(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "clear", false))
        {
            StartClanParentSelection(client, 0);
        }
        else
        {
            StartClanParentSelection(client, StringToInt(info));
        }
    }

    return 0;
}

void StartClanParentSelection(int client, int selectedParentClanId)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT clan_id, rank FROM clan_members WHERE steamid64 = '%s' LIMIT 1",
        escapedSteam);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(selectedParentClanId);

    g_Database.Query(SQL_OnClanParentRevalidateOwner, query, pack);
}

public void SQL_OnClanParentRevalidateOwner(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int selectedParentClanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Parent owner revalidation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate your clan state.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int ownerClanId = results.FetchInt(0);
    ClanRank rank = view_as<ClanRank>(results.FetchInt(1));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only clan owners can manage parent relations.");
        return;
    }

    if (selectedParentClanId <= 0)
    {
        ClearParentRelation(ownerClanId, userId);
        return;
    }

    if (selectedParentClanId == ownerClanId)
    {
        PrintToChat(client, "[Clans] Your clan cannot be its own parent.");
        return;
    }

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clans WHERE id = %d AND is_open = 1) AS parent_ok, "
        ... "(SELECT name FROM clans WHERE id = %d LIMIT 1) AS parent_name",
        selectedParentClanId,
        selectedParentClanId);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(ownerClanId);
    next.WriteCell(selectedParentClanId);

    g_Database.Query(SQL_OnClanParentValidateTarget, query, next);
}

public void SQL_OnClanParentValidateTarget(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int ownerClanId = pack.ReadCell();
    int selectedParentClanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Parent target validation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate that parent clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Failed to validate that parent clan.");
        return;
    }

    if (results.FetchInt(0) <= 0)
    {
        PrintToChat(client, "[Clans] That clan is not open or no longer exists.");
        return;
    }

    SetParentRelation(ownerClanId, selectedParentClanId, userId);
}

public void SQLTxn_OnSetParentSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    pack.ReadCell();
    pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    PrintToChat(client, "[Clans] Parent clan relation saved.");
}

public void SQLTxn_OnSetParentFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    pack.ReadCell();
    pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Failed to save the parent clan relation.");
    }

    LogError("[Clans] Parent relation transaction failed at query %d: %s", failIndex, error);
}

public void SQL_OnClearParentRelation(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clear parent relation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to clear the parent relation.");
        return;
    }

    PrintToChat(client, "[Clans] Parent clan relation cleared.");
}

void AddInviteMenuItem(Menu menu, int inviteId, const char[] clanName, const char[] clanTag, int expiresAt)
{
    char info[16];
    IntToString(inviteId, info, sizeof(info));

    int secondsLeft = expiresAt - GetTime();
    if (secondsLeft < 0)
    {
        secondsLeft = 0;
    }

    int daysLeft = (secondsLeft + 86399) / 86400;
    if (daysLeft < 1)
    {
        daysLeft = 1;
    }

    char display[192];
    if (clanTag[0])
    {
        FormatEx(display, sizeof(display), "%s %s (%d day%s left)", clanName, clanTag, daysLeft, (daysLeft == 1) ? "" : "s");
    }
    else
    {
        FormatEx(display, sizeof(display), "%s (%d day%s left)", clanName, daysLeft, (daysLeft == 1) ? "" : "s");
    }

    menu.AddItem(info, display);
}

public Action Command_ClanAcceptInvite(int client, int args)
{
    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetPendingInvites(steamid64, SQL_OnPendingInvitesForAccept, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnPendingInvitesForAccept(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Pending invite query (accept) failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load your clan invites.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You have no pending clan invites.");
        return;
    }

    int firstInviteId = results.FetchInt(PendingInviteCol_Id);
    char firstClanName[CLAN_NAME_MAXLEN + 1];
    char firstClanTag[CLAN_TAG_STORE_MAXLEN];
    int firstExpiresAt = results.FetchInt(PendingInviteCol_ExpiresAt);

    results.FetchString(PendingInviteCol_ClanName, firstClanName, sizeof(firstClanName));
    results.FetchString(PendingInviteCol_ClanTag, firstClanTag, sizeof(firstClanTag));

    if (!results.FetchRow())
    {
        StartAcceptInvite(client, firstInviteId);
        return;
    }

    Menu menu = new Menu(MenuHandler_AcceptInvite);
    menu.SetTitle("Select a clan invite to accept");

    AddInviteMenuItem(menu, firstInviteId, firstClanName, firstClanTag, firstExpiresAt);

    do
    {
        int inviteId = results.FetchInt(PendingInviteCol_Id);
        char clanName[CLAN_NAME_MAXLEN + 1];
        char clanTag[CLAN_TAG_STORE_MAXLEN];
        int expiresAt = results.FetchInt(PendingInviteCol_ExpiresAt);

        results.FetchString(PendingInviteCol_ClanName, clanName, sizeof(clanName));
        results.FetchString(PendingInviteCol_ClanTag, clanTag, sizeof(clanTag));

        AddInviteMenuItem(menu, inviteId, clanName, clanTag, expiresAt);
    }
    while (results.FetchRow());

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_AcceptInvite(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        StartAcceptInvite(client, StringToInt(info));
    }

    return 0;
}

void StartAcceptInvite(int client, int inviteId)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    int now = GetTime();

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clan_members WHERE steamid64 = '%s') AS in_clan, "
        ... "(SELECT COUNT(1) FROM clan_invites WHERE id = %d AND steamid64 = '%s' AND expires_at > %d) AS invite_ok, "
        ... "(SELECT clan_id FROM clan_invites WHERE id = %d AND steamid64 = '%s' AND expires_at > %d LIMIT 1) AS clan_id, "
        ... "(SELECT name FROM clans WHERE id = (SELECT clan_id FROM clan_invites WHERE id = %d AND steamid64 = '%s' AND expires_at > %d LIMIT 1) LIMIT 1) AS clan_name",
        escapedSteam,
        inviteId,
        escapedSteam,
        now,
        inviteId,
        escapedSteam,
        now,
        inviteId,
        escapedSteam,
        now);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(inviteId);
    pack.WriteString(steamid64);

    g_Database.Query(SQL_OnAcceptInviteValidate, query, pack);
}

public void SQL_OnAcceptInviteValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int inviteId = pack.ReadCell();
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Accept invite validation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate that invite.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Failed to validate that invite.");
        return;
    }

    if (results.FetchInt(0) > 0)
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    if (results.FetchInt(1) <= 0)
    {
        PrintToChat(client, "[Clans] That invite is no longer valid.");
        return;
    }

    int clanId = results.FetchInt(2);
    if (clanId <= 0)
    {
        PrintToChat(client, "[Clans] That invite is no longer valid.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(3, clanName, sizeof(clanName));

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    int now = GetTime();

    Transaction txn = new Transaction();
    char query[1024];

    FormatEx(query, sizeof(query),
        "INSERT INTO clan_members (clan_id, steamid64, rank, joined_at) "
        ... "SELECT i.clan_id, '%s', %d, %d "
        ... "FROM clan_invites i "
        ... "INNER JOIN clans c ON c.id = i.clan_id "
        ... "WHERE i.id = %d AND i.steamid64 = '%s' AND i.expires_at > %d LIMIT 1",
        escapedSteam,
        view_as<int>(ClanRank_Member),
        now,
        inviteId,
        escapedSteam,
        now);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_invites WHERE steamid64 = '%s' "
        ... "AND EXISTS (SELECT 1 FROM clan_members WHERE steamid64 = '%s')",
        escapedSteam,
        escapedSteam);
    txn.AddQuery(query);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(steamid64);
    next.WriteString(clanName);
    next.WriteCell(clanId);

    g_Database.Execute(txn, SQLTxn_OnAcceptInviteSuccess, SQLTxn_OnAcceptInviteFailure, next);
}

public void SQLTxn_OnAcceptInviteSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char steamid64[STEAMID64_MAXLEN];
    char fallbackClanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(steamid64, sizeof(steamid64));
    pack.ReadString(fallbackClanName, sizeof(fallbackClanName));
    int clanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT c.name FROM clan_members m INNER JOIN clans c ON c.id = m.clan_id WHERE m.steamid64 = '%s' LIMIT 1",
        escapedSteam);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(fallbackClanName);
    next.WriteString(steamid64);
    next.WriteCell(clanId);

    g_Database.Query(SQL_OnAcceptInviteVerify, query, next);
}

public void SQLTxn_OnAcceptInviteFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char ignoredSteam[STEAMID64_MAXLEN];
    char ignoredClan[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(ignoredSteam, sizeof(ignoredSteam));
    pack.ReadString(ignoredClan, sizeof(ignoredClan));
    pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        if (StrContains(error, "Duplicate", false) != -1 || StrContains(error, "UNIQUE", false) != -1)
        {
            PrintToChat(client, "[Clans] You are already in a clan.");
        }
        else
        {
            PrintToChat(client, "[Clans] Failed to accept that invite.");
        }
    }

    LogError("[Clans] Accept invite transaction failed at query %d: %s", failIndex, error);
}

public void SQL_OnAcceptInviteVerify(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char fallbackClanName[CLAN_NAME_MAXLEN + 1];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(fallbackClanName, sizeof(fallbackClanName));
    pack.ReadString(steamid64, sizeof(steamid64));
    int clanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Accept invite verify query failed: %s", error);
        PrintToChat(client, "[Clans] Invite processed, but verification failed.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] That invite was no longer valid.");
        return;
    }

    char actualClanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(0, actualClanName, sizeof(actualClanName));
    if (!actualClanName[0])
    {
        strcopy(actualClanName, sizeof(actualClanName), fallbackClanName);
    }

    PrintToChat(client, "[Clans] You joined '%s'.", actualClanName);
    AnnounceClanInviteAcceptedToMembers(clanId, actualClanName, steamid64);
}

public Action Command_ClanDenyInvite(int client, int args)
{
    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetPendingInvites(steamid64, SQL_OnPendingInvitesForDeny, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnPendingInvitesForDeny(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Pending invite query (deny) failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load your clan invites.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You have no pending clan invites.");
        return;
    }

    int firstInviteId = results.FetchInt(PendingInviteCol_Id);
    char firstClanName[CLAN_NAME_MAXLEN + 1];
    char firstClanTag[CLAN_TAG_STORE_MAXLEN];
    int firstExpiresAt = results.FetchInt(PendingInviteCol_ExpiresAt);

    results.FetchString(PendingInviteCol_ClanName, firstClanName, sizeof(firstClanName));
    results.FetchString(PendingInviteCol_ClanTag, firstClanTag, sizeof(firstClanTag));

    if (!results.FetchRow())
    {
        StartDenyInvite(client, firstInviteId);
        return;
    }

    Menu menu = new Menu(MenuHandler_DenyInvite);
    menu.SetTitle("Select a clan invite to deny");

    AddInviteMenuItem(menu, firstInviteId, firstClanName, firstClanTag, firstExpiresAt);

    do
    {
        int inviteId = results.FetchInt(PendingInviteCol_Id);
        char clanName[CLAN_NAME_MAXLEN + 1];
        char clanTag[CLAN_TAG_STORE_MAXLEN];
        int expiresAt = results.FetchInt(PendingInviteCol_ExpiresAt);

        results.FetchString(PendingInviteCol_ClanName, clanName, sizeof(clanName));
        results.FetchString(PendingInviteCol_ClanTag, clanTag, sizeof(clanTag));

        AddInviteMenuItem(menu, inviteId, clanName, clanTag, expiresAt);
    }
    while (results.FetchRow());

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_DenyInvite(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        StartDenyInvite(client, StringToInt(info));
    }

    return 0;
}

void StartDenyInvite(int client, int inviteId)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(inviteId);

    DeleteInvite(inviteId, SQL_OnDenyInviteDeleted, pack);
}

public void SQL_OnDenyInviteDeleted(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int inviteId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Deny invite delete failed: %s", error);
        PrintToChat(client, "[Clans] Failed to deny that invite.");
        return;
    }

    PrintToChat(client, "[Clans] Invite #%d denied.", inviteId);
}
