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
ConVar cvarPutSpecInAutoJoin;

ConVar cvarVisibleMaxPlayers;
ConVar cvarSourceTVEnabled;
ConVar cvarReplayEnabled;

// store userid inside as it will persist during map resets
enum struct PlayerQueue {
    ArrayList clients;

    void Init() {
        this.clients = new ArrayList();
    }

    void Deinit() {
        delete this.clients;
    }

    void OfferViaUserId(int userId) {
        this.clients.Push(userId);
    }

    void Offer(int client) {
        this.OfferViaUserId(GetClientUserId(client));
    }

    int Poll() {
        if (this.IsEmpty()) {
            return -1;
        }
        int value = this.clients.Get(0);
        this.clients.Erase(0);
        return GetClientOfUserId(value);
    }

    bool RemoveFromQueue(int client) {
        return this.RemoveUserIdFromQueue(GetClientUserId(client));
    }

    bool RemoveUserIdFromQueue(int userId) {
        int index = this.clients.FindValue(userId);
        if (index == -1) {
            return false;
        }
        this.clients.Erase(index);
        return true;
    }

    bool InQueue(int client) {
        return this.clients.FindValue(GetClientUserId(client)) != -1;
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
    cvarPutSpecInAutoJoin = CreateConVar("sm_fullspec_put_spec_in_autojoin", "1", "Automatically put spectators into autojoin when server is full.");

    cvarVisibleMaxPlayers = FindConVar("sv_visiblemaxplayers");
    cvarSourceTVEnabled = FindConVar("tv_enable");
    cvarReplayEnabled = FindConVar("replay_enable");

    cvarMaxPlayersInGame.AddChangeHook(OnMaxPlayerCvarChanged);
    cvarVisibleMaxPlayers.AddChangeHook(OnMaxPlayerCvarChanged);

    RegConsoleCmd("sm_autojoin", Cmd_AutoJoin, "Spectator auto-join.");
    RegConsoleCmd("sm_checkautojoin", Cmd_CheckAutoJoinQueue, "See the auto join queue.");

    AddCommandListener(OnClientJoinTeam, "jointeam");

    HookEvent("player_connect", Event_OnPlayerConnect);
    HookEvent("player_disconnect", Event_OnPlayerDisconnect);
    HookEvent("server_shutdown", Event_OnServerShutdown);

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

public void Event_OnPlayerConnect(Event event, const char[] name, bool dontBroadcast) {
    int humanCount = GetHumanCount();
    int maxPlayers = cvarMaxPlayersInGame.IntValue;
    // start tracking spectators when server gets full
    if (humanCount == maxPlayers) {
        for (int i = 1; i <= MaxClients; i++) {
            if (!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i) || IsClientReplay(i)) {
                continue;
            }
            if (IsClientObserver(i) && !spectatorQueue.InQueue(i)) {
                spectatorQueue.Offer(i);
            }
        }
    } else if (humanCount > maxPlayers) {
        spectatorQueue.OfferViaUserId(event.GetInt("userid"));
    }
}

public void Event_OnPlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
    int userid = event.GetInt("userid");
    waitQueue.RemoveUserIdFromQueue(userid);
    spectatorQueue.RemoveUserIdFromQueue(userid);
    // wait 1 second before running autojoin checks as at this point the client might still be in game
    CreateTimer(1.0, Timer_RunPlayerCheck);
}

public Action Timer_RunPlayerCheck(Handle timer) {
    RunPlayerChangeChecks();
    return Plugin_Continue;
}

public void Event_OnServerShutdown(Event event, const char[] name, bool dontBroadcast) {
    waitQueue.Clear();
    spectatorQueue.Clear();
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
    cvarVisibleMaxPlayers.IntValue = cvarMaxPlayersInGame.IntValue;
}

public Action OnClientJoinTeam(int client, const char[] command, int argc) {
    bool isServerOverloaded = GetHumanCount() >= cvarMaxPlayersInGame.IntValue;
    if (!isServerOverloaded) {
        RunPlayerChangeChecks();
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
    if (isServerFull || inSpecQueue) {
        if (!inSpecQueue) {
            spectatorQueue.Offer(client);
        }
        ChangeClientTeam(client, TFTeam_Spectator);
        bool putInAutoJoin = cvarPutSpecInAutoJoin.BoolValue;
        if (putInAutoJoin && !waitQueue.InQueue(client)) {
            waitQueue.Offer(client);
        }
        PrintToChat(client, "%t", putInAutoJoin ? "SPEC_WHEN_FULL_JOIN_SPEC_AUTO" : "SPEC_WHEN_FULL_JOIN_SPEC");
        return Plugin_Handled;
    }
    // handle when the server is overloaded but there are less than 24 players on both teams
    spectatorQueue.RemoveFromQueue(client);
    waitQueue.RemoveFromQueue(client);
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

public Action Cmd_CheckAutoJoinQueue(int client, int args) {
    if (client <= 0) {
        return Plugin_Handled;
    }
    if (!IsServerFull()) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_FULL");
        return Plugin_Handled;
    }
    if (waitQueue.IsEmpty()) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_AUTOJOIN_EMPTY");
        return Plugin_Handled;
    }
    char title[BASE_STR_LEN];
    Format(title, sizeof(title), "%T", client, "SPEC_WHEN_FULL_SPEC_QUEUE_MENU_TITLE");
    Menu menu = new Menu(Menu_AutoJoinList);
    menu.SetTitle(title);
    menu.Pagination = 10;
    menu.ExitButton = true;
    for (int i = 0; i < waitQueue.clients.Length; i++) {
        int specClientIndex = GetClientOfUserId(waitQueue.clients.Get(i));
        char clientName[MAX_NAME_LENGTH];
        GetClientName(specClientIndex, clientName, sizeof(clientName));
        menu.AddItem(clientName, clientName, ITEMDRAW_DISABLED);
    }
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public void Menu_AutoJoinList(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End) {
        delete menu;
    }
}

public Action OnAFKKick(int client) {
    if (waitQueue.InQueue(client)) {
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

public void OnAFKSwitch(int client) {
    if (GetHumanCount() < cvarMaxPlayersInGame.IntValue) {
        return;
    }
    if (!spectatorQueue.InQueue(client)) {
        spectatorQueue.Offer(client);
    }
    RunPlayerChangeChecks();
}

void RunPlayerChangeChecks() {
    while (!IsServerFull() && !waitQueue.IsEmpty()) {
        int client = waitQueue.Poll();
        spectatorQueue.RemoveFromQueue(client);
        FakeClientCommand(client, "jointeam " ... JOIN_TEAM_AUTO);
    }
    if (GetHumanCount() < cvarMaxPlayersInGame.IntValue) {
        // stop tracking spectators when server is not full
        spectatorQueue.Clear();
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
    return GetClientCount(false) - GetPlayersToDeduct();
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
