#include <sourcemod>
#include <sdktools>
#include <tf2>
#include <adt_array>
#undef REQUIRE_PLUGIN
#include <afkmanager>
#define REQUIRE_PLUGIN

#define BASE_STR_LEN 128

#define JOIN_TEAM_BLU "blue"
#define JOIN_TEAM_RED "red"
#define JOIN_TEAM_AUTO "auto"
#define JOIN_TEAM_SPECTATOR "spectate"

public Plugin myinfo = {
    name = "Spectate When Full",
    author = "Eric Zhang",
    description = "Allows players to spectate when the server is full.",
    version = "1.0",
    url = "https://ericaftereric.top/"
};

ConVar cvarMaxPlayersInGame;
ConVar cvarVisibleMaxPlayers;

ConVar cvarSourceTVEnabled;
ConVar cvarReplayEnabled;

enum struct PlayerQueue {
    ArrayList clients;

    void Init() {
        this.clients = new ArrayList();
    }

    void Deinit() {
        delete this.clients;
    }

    void Offer(int client) {
        this.clients.Push(client);
    }

    int Poll() {
        int lastIndex = this.clients.Length - 1;
        int value = this.clients.Get(lastIndex);
        this.clients.Erase(lastIndex);
        return value;
    }

    bool RemoveFromQueue(int client) {
        if (this.InQueue(client)) {
            return false;
        }
        this.clients.Erase(this.clients.FindValue(client));
        return true;
    }

    bool InQueue(int client) {
        return this.clients.FindValue(client) != -1;
    }

    void Clear() {
        this.clients.Clear();
    }

    bool IsEmpty() {
        return this.clients.Length == 0;
    }
}

PlayerQueue waitQueue;
// queue operations (poll/offer) are useless here but i am reusing this struct
PlayerQueue spectatorQueue;

public void OnPluginStart() {
    LoadTranslations("spec-when-full.phrases.txt");

    waitQueue.Init();
    spectatorQueue.Init();

    cvarMaxPlayersInGame = CreateConVar("sm_fullspec_maxplayers_in_game", "24", "Maximum amount of players allowed in game. Set to -1 to disable.");
    cvarVisibleMaxPlayers = FindConVar("sv_visiblemaxplayers");
    cvarSourceTVEnabled = FindConVar("tv_enable");
    cvarReplayEnabled = FindConVar("replay_enable");

    cvarMaxPlayersInGame.AddChangeHook(OnMaxPlayerCvarChanged);
    cvarVisibleMaxPlayers.AddChangeHook(OnMaxPlayerCvarChanged);

    RegConsoleCmd("sm_autojoin", Cmd_AutoJoin, "Spectator auto-join.");
    AddCommandListener(OnClientJoinTeam, "jointeam");

    AutoExecConfig();
}

public void OnAllPluginsLoaded() {
    if (FindPluginByFile("reservedslots.smx") != INVALID_HANDLE) {
        LogMessage("Unloading reservedslots to prevent conflicts...");
        ServerCommand("sm plugins unload reservedslots");
    }
}

public void OnServerEnterHibernation() {
    waitQueue.Clear();
    spectatorQueue.Clear();
}

public void OnConfigsExecuted() {
    SetVisibleMaxPlayers();
}

public void OnPluginEnd() {
    waitQueue.Deinit();
    spectatorQueue.Deinit();
}

public void OnMaxPlayerCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    SetVisibleMaxPlayers();
}

public void OnClientDisconnect(int client) {
    waitQueue.RemoveFromQueue(client);
    spectatorQueue.RemoveFromQueue(client);
}

public void OnClientDisconnect_Post(int client) {
    RunPlayerChangeChecks();
}

void SetVisibleMaxPlayers() {
    if (cvarMaxPlayersInGame.IntValue == -1) {
        cvarVisibleMaxPlayers.IntValue = -1;
        return;
    }
    int maxHumanPlayers = GetActualMaxHumanPlayers();
    if (maxHumanPlayers <= cvarMaxPlayersInGame.IntValue) {
        LogError("Max human players is less than the maximum amount of players allowed in game.");
        cvarMaxPlayersInGame.IntValue = maxHumanPlayers;
        cvarVisibleMaxPlayers.IntValue = -1;
        return;
    }
    cvarVisibleMaxPlayers.IntValue = maxHumanPlayers - cvarMaxPlayersInGame.IntValue;
}

public Action OnClientJoinTeam(int client, const char[] command, int argc) {
    bool isServerOverloaded = GetHumanCount() >= cvarMaxPlayersInGame.IntValue;
    if (!isServerOverloaded) {
        return Plugin_Continue;
    }
    char team[BASE_STR_LEN];
    GetCmdArg(1, team, sizeof(team));
    if (StrEqual(team, JOIN_TEAM_SPECTATOR, false)) {
        ChangeClientTeam(client, TFTeam_Spectator);
        spectatorQueue.Offer(client);
        // handle when we have a full server but someone on red/blu switches to spec
        if (isServerOverloaded) {
            RunPlayerChangeChecks();
        }
        return Plugin_Handled;
    }
    // just in case someone typed jointeam hdfsiufhsdfi
    if (!(StrEqual(team, JOIN_TEAM_AUTO, false) || StrEqual(team, JOIN_TEAM_BLU, false) || StrEqual(team, JOIN_TEAM_RED, false))) {
        return Plugin_Continue;
    }
    bool inSpecQueue = spectatorQueue.InQueue(client);
    bool isServerFull = IsServerFull();
    // handle when the server is overloaded but there are less than 24 players on both teams
    if (!isServerFull) {
        spectatorQueue.RemoveFromQueue(client);
        waitQueue.RemoveFromQueue(client);
        return Plugin_Continue;
    }
    if (isServerFull || inSpecQueue) {
        if (!inSpecQueue) {
            spectatorQueue.Offer(client);
        }
        ChangeClientTeam(client, TFTeam_Spectator);
        PrintToChat(client, "%t", "SPEC_WHEN_FULL_JOIN_SPEC");
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

public Action Cmd_AutoJoin(int client, int args) {
    if (!IsServerFull()) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_FULL");
        return Plugin_Handled;
    }
    if (GetClientTeam(client) != view_as<int>(TFTeam_Spectator)) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_SPEC");
        return Plugin_Handled;
    }
    if (waitQueue.InQueue(client)) {
        waitQueue.RemoveFromQueue(client);
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_AUTOJOIN_REMOVE_QUEUE");
        return Plugin_Handled;
    }
    waitQueue.Offer(client);
    ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_AUTOJOIN_PLACE_QUEUE");
    return Plugin_Handled;
}

public Action OnAFKKick(int client) {
    if (waitQueue.InQueue(client)) {
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

void RunPlayerChangeChecks() {
    if (waitQueue.IsEmpty()) {
        return;
    }
    while (!IsServerFull()) {
        int client = waitQueue.Poll();
        spectatorQueue.RemoveFromQueue(client);
        FakeClientCommand(client, "jointeam " ... JOIN_TEAM_AUTO);
    }
}

int GetPlayersInGame() {
    return GetTeamClientCount(TFTeam_Blue) + GetTeamClientCount(TFTeam_Red);
}

bool IsServerFull() {
    return GetPlayersInGame() >= cvarMaxPlayersInGame.IntValue;
}

int GetActualMaxHumanPlayers() {
    return GetMaxHumanPlayers() - GetPlayersToDeduct();
}

int GetHumanCount() {
    return GetClientCount() - GetPlayersToDeduct();
}

int GetPlayersToDeduct() {
    int playersToDeduct = 0;
    if (cvarSourceTVEnabled.BoolValue) {
        playersToDeduct++;
    }
    if (cvarReplayEnabled.BoolValue) {
        playersToDeduct++;
    }
    return playersToDeduct;
}
