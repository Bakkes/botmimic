/**
 * Bot Mimic - Record your movments and have bots playing it back.
 * by Peace-Maker
 * visit http://wcfan.de
 * 
 * Changelog:
 * 2.0   - 22.07.2013: Released rewrite
 * 2.0.1 - 01.08.2013: Actually made DHooks an optional dependency.
 */

#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <sdkhooks>
#include <smlib>
#include <botmimic>

#undef REQUIRE_EXTENSIONS
#include <dhooks>

#define PLUGIN_VERSION "2.0.1"

#define BM_MAGIC 0xdeadbeef
#define BINARY_FORMAT_VERSION 0x01

#define DEFAULT_RECORD_FOLDER "data/botmimic/"

// Flags set in FramInfo.additionalFields to inform, that there's more info afterwards.
#define ADDITIONAL_FIELD_TELEPORTED_ORIGIN (1<<0)
#define ADDITIONAL_FIELD_TELEPORTED_ANGLES (1<<1)
#define ADDITIONAL_FIELD_TELEPORTED_VELOCITY (1<<2)

#define FRAME_INFO_SIZE 14
enum FrameInfo {
	playerButtons = 0,
	playerImpulse,
	Float:actualVelocity[3],
	Float:predictedVelocity[3],
	Float:predictedAngles[2], // Ignore roll
	CSWeaponID:newWeapon,
	playerSubtype,
	playerSeed,
	additionalFields // see ADDITIONAL_FIELD_* defines
}

#define AT_SIZE 10
#define AT_ORIGIN 0
#define AT_ANGLES 1
#define AT_VELOCITY 2
#define AT_FLAGS 3
enum AdditionalTeleport {
	Float:atOrigin[3],
	Float:atAngles[3],
	Float:atVelocity[3],
	atFlags
}

// Save the position of clients every 10000 ticks
// This is to avoid bots getting stuck in walls due to slightly lower jumps, if they don't touch the ground.
#define ORIGIN_SNAPSHOT_INTERVAL 10000

#define FILE_HEADER_LENGTH 74
enum FileHeader {
	FH_binaryFormatVersion = 0,
	FH_recordEndTime,
	String:FH_recordName[MAX_RECORD_NAME_LENGTH],
	FH_tickCount,
	Float:FH_initialPosition[3],
	Float:FH_initialAngles[3],
	Handle:FH_frames
}

// Where did he start recording. The bot is teleported to this position on replay.
new Float:g_fInitialPosition[MAXPLAYERS+1][3];
new Float:g_fInitialAngles[MAXPLAYERS+1][3];
// Array of frames
new Handle:g_hRecording[MAXPLAYERS+1];
new Handle:g_hRecordingAdditionalTeleport[MAXPLAYERS+1];
new g_iCurrentAdditionalTeleportIndex[MAXPLAYERS+1];
// How many calls to OnPlayerRunCmd were recorded?
new g_iRecordedTicks[MAXPLAYERS+1];
// What's the last active weapon
new g_iRecordPreviousWeapon[MAXPLAYERS+1];
// Count ticks till we save the position again
new g_iOriginSnapshotInterval[MAXPLAYERS+1];
// The name of this recording
new String:g_sRecordName[MAXPLAYERS+1][MAX_RECORD_NAME_LENGTH];
new String:g_sRecordPath[MAXPLAYERS+1][PLATFORM_MAX_PATH];
new String:g_sRecordCategory[MAXPLAYERS+1][PLATFORM_MAX_PATH];
new String:g_sRecordSubDir[MAXPLAYERS+1][PLATFORM_MAX_PATH];

new Handle:g_hLoadedRecords;
new Handle:g_hLoadedRecordsAdditionalTeleport;
new Handle:g_hLoadedRecordsCategory;
new Handle:g_hSortedRecordList;
new Handle:g_hSortedCategoryList;

new Handle:g_hBotMimicsRecord[MAXPLAYERS+1] = {INVALID_HANDLE,...};
new g_iBotMimicTick[MAXPLAYERS+1] = {0,...};
new g_iBotMimicRecordTickCount[MAXPLAYERS+1] = {0,...};
new g_iBotActiveWeapon[MAXPLAYERS+1] = {-1,...};
new bool:g_bValidTeleportCall[MAXPLAYERS+1];

new Handle:g_hfwdOnStartRecording;
new Handle:g_hfwdOnStopRecording;
new Handle:g_hfwdOnRecordSaved;
new Handle:g_hfwdOnRecordDeleted;
new Handle:g_hfwdOnPlayerStartsMimicing;
new Handle:g_hfwdOnPlayerStopsMimicing;
new Handle:g_hfwdOnPlayerMimicLoops;

// DHooks
new Handle:g_hTeleport;

public Plugin:myinfo = 
{
	name = "Bot Mimic",
	author = "Jannik \"Peace-Maker\" Hartung",
	description = "Bots mimic your movements!",
	version = PLUGIN_VERSION,
	url = "http://www.wcfan.de/"
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	RegPluginLibrary("botmimic");
	CreateNative("BotMimic_StartRecording", StartRecording);
	CreateNative("BotMimic_StopRecording", StopRecording);
	CreateNative("BotMimic_DeleteRecord", DeleteRecord);
	CreateNative("BotMimic_IsPlayerRecording", IsPlayerRecording);
	CreateNative("BotMimic_IsPlayerMimicing", IsPlayerMimicing);
	CreateNative("BotMimic_GetRecordPlayerMimics", GetRecordPlayerMimics);
	CreateNative("BotMimic_PlayRecordFromFile", PlayRecordFromFile);
	CreateNative("BotMimic_PlayRecordByName", PlayRecordByName);
	CreateNative("BotMimic_ResetPlayback", ResetPlayback);
	CreateNative("BotMimic_StopPlayerMimic", StopPlayerMimic);
	CreateNative("BotMimic_GetFileHeaders", GetFileHeaders);
	CreateNative("BotMimic_ChangeRecordName", ChangeRecordName);
	CreateNative("BotMimic_GetLoadedRecordCategoryList", GetLoadedRecordCategoryList);
	CreateNative("BotMimic_GetLoadedRecordList", GetLoadedRecordList);
	CreateNative("BotMimic_GetFileCategory", GetFileCategory);
	
	g_hfwdOnStartRecording = CreateGlobalForward("BotMimic_OnStartRecording", ET_Hook, Param_Cell, Param_String, Param_String, Param_String, Param_String);
	g_hfwdOnStopRecording = CreateGlobalForward("BotMimic_OnStopRecording", ET_Hook, Param_Cell, Param_String, Param_String, Param_String, Param_String, Param_CellByRef);
	g_hfwdOnRecordSaved = CreateGlobalForward("BotMimic_OnRecordSaved", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String, Param_String);
	g_hfwdOnRecordDeleted = CreateGlobalForward("BotMimic_OnRecordDeleted", ET_Ignore, Param_String, Param_String, Param_String);
	g_hfwdOnPlayerStartsMimicing = CreateGlobalForward("BotMimic_OnPlayerStartsMimicing", ET_Hook, Param_Cell, Param_String, Param_String, Param_String);
	g_hfwdOnPlayerStopsMimicing = CreateGlobalForward("BotMimic_OnPlayerStopsMimicing", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String);
	g_hfwdOnPlayerMimicLoops = CreateGlobalForward("BotMimic_OnPlayerMimicLoops", ET_Ignore, Param_Cell);
}

public OnPluginStart()
{
	new Handle:hVersion = CreateConVar("sm_botmimic_version", PLUGIN_VERSION, "Bot Mimic version", FCVAR_PLUGIN|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	if(hVersion != INVALID_HANDLE)
	{
		SetConVarString(hVersion, PLUGIN_VERSION);
		HookConVarChange(hVersion, ConVar_VersionChanged);
	}
	
	// Maps path to .rec -> record enum
	g_hLoadedRecords = CreateTrie();
	g_hLoadedRecordsAdditionalTeleport = CreateTrie();
	
	// Maps path to .rec -> record category
	g_hLoadedRecordsCategory = CreateTrie();
	
	// Save all paths to .rec files in the trie sorted by time
	g_hSortedRecordList = CreateArray(ByteCountToCells(PLATFORM_MAX_PATH));
	g_hSortedCategoryList = CreateArray(ByteCountToCells(64));
	
	HookEvent("player_spawn", Event_OnPlayerSpawn);
	HookEvent("player_death", Event_OnPlayerDeath);
	
	// Optionally setup a hook on CBaseEntity::Teleport to keep track of sudden place changes
	new Handle:hGameData = LoadGameConfigFile("sdktools.games");
	if(hGameData == INVALID_HANDLE)
		return;
	new iOffset = GameConfGetOffset(hGameData, "Teleport");
	CloseHandle(hGameData);
	if(iOffset == -1)
		return;
	
	if(LibraryExists("dhooks"))
	{
		g_hTeleport = DHookCreate(iOffset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, DHooks_OnTeleport);
		if(g_hTeleport == INVALID_HANDLE)
			return;
		DHookAddParam(g_hTeleport, HookParamType_VectorPtr);
		DHookAddParam(g_hTeleport, HookParamType_ObjectPtr);
		DHookAddParam(g_hTeleport, HookParamType_VectorPtr);
		
		for(new i=1;i<=MaxClients;i++)
		{
			if(IsClientInGame(i))
				OnClientPutInServer(i);
		}
	}
}

public ConVar_VersionChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	SetConVarString(convar, PLUGIN_VERSION);
}

/**
 * Public forwards
 */
public OnMapStart()
{
	// Clear old records for old map
	new iSize = GetArraySize(g_hSortedRecordList);
	decl String:sPath[PLATFORM_MAX_PATH];
	new iFileHeader[FILE_HEADER_LENGTH];
	new Handle:hAdditionalTeleport;
	for(new i=0;i<iSize;i++)
	{
		GetArrayString(g_hSortedRecordList, i, sPath, sizeof(sPath));
		GetTrieArray(g_hLoadedRecords, sPath, iFileHeader, _:FileHeader);
		if(iFileHeader[_:_:FH_frames] != INVALID_HANDLE)
			CloseHandle(iFileHeader[_:_:FH_frames]);
		if(GetTrieValue(g_hLoadedRecordsAdditionalTeleport, sPath, hAdditionalTeleport))
			CloseHandle(hAdditionalTeleport);
	}
	ClearTrie(g_hLoadedRecords);
	ClearTrie(g_hLoadedRecordsAdditionalTeleport);
	ClearTrie(g_hLoadedRecordsCategory);
	ClearArray(g_hSortedRecordList);
	ClearArray(g_hSortedCategoryList);
	
	// Create our record directory
	BuildPath(Path_SM, sPath, sizeof(sPath), DEFAULT_RECORD_FOLDER);
	if(!DirExists(sPath))
		CreateDirectory(sPath, 511);
	
	// Check for categories
	new Handle:hDir = OpenDirectory(sPath);
	if(hDir == INVALID_HANDLE)
		return;
	
	new String:sFile[64], FileType:fileType;
	while(ReadDirEntry(hDir, sFile, sizeof(sFile), fileType))
	{
		switch(fileType)
		{
			// Check all directories for records on this map
			case FileType_Directory:
			{
				// INFINITE RECURSION ANYONE?
				if(StrEqual(sFile, ".") || StrEqual(sFile, ".."))
					continue;
				
				BuildPath(Path_SM, sPath, sizeof(sPath), "%s%s", DEFAULT_RECORD_FOLDER, sFile);
				ParseRecordsInDirectory(sPath, sFile, false);
			}
		}
		
	}
	CloseHandle(hDir);
}

public OnClientPutInServer(client)
{
	if(LibraryExists("dhooks"))
		DHookEntity(g_hTeleport, false, client);
}

public OnClientDisconnect(client)
{
	if(g_hRecording[client] != INVALID_HANDLE)
		BotMimic_StopRecording(client);
	
	if(g_hBotMimicsRecord[client] != INVALID_HANDLE)
		BotMimic_StopPlayerMimic(client);
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	// client is recording his movements
	if(g_hRecording[client] != INVALID_HANDLE)
	{
		new iFrame[FRAME_INFO_SIZE];
		iFrame[playerButtons] = buttons;
		iFrame[playerImpulse] = impulse;
		
		new Float:vVel[3];
		Entity_GetAbsVelocity(client, vVel);
		iFrame[actualVelocity] = vVel;
		iFrame[predictedVelocity] = vel;
		Array_Copy(angles, iFrame[predictedAngles], 2);
		iFrame[newWeapon] = CSWeapon_NONE;
		iFrame[playerSubtype] = subtype;
		iFrame[playerSeed] = seed;
		
		// Save the current position 
		if(g_iOriginSnapshotInterval[client] > ORIGIN_SNAPSHOT_INTERVAL)
		{
			new Float:origin[3], iAT[AT_SIZE];
			GetClientAbsOrigin(client, origin);
			Array_Copy(origin, iAT[_:atOrigin], 3);
			iAT[_:atFlags] |= ADDITIONAL_FIELD_TELEPORTED_ORIGIN;
			PushArrayArray(g_hRecordingAdditionalTeleport[client], iAT, AT_SIZE);
			g_iOriginSnapshotInterval[client] = 0;
		}
		
		g_iOriginSnapshotInterval[client]++;
		
		// Check for additional Teleports
		if(GetArraySize(g_hRecordingAdditionalTeleport[client]) > g_iCurrentAdditionalTeleportIndex[client])
		{
			new iAT[AT_SIZE];
			GetArrayArray(g_hRecordingAdditionalTeleport[client], g_iCurrentAdditionalTeleportIndex[client], iAT, AT_SIZE);
			// Remember, we were teleported this frame!
			iFrame[additionalFields] |= iAT[_:atFlags];
			g_iCurrentAdditionalTeleportIndex[client]++;
		}
		
		new iNewWeapon = -1;
		
		// Did he change his weapon?
		if(weapon)
		{
			iNewWeapon = weapon;
		}
		// Picked up a new one?
		else
		{
			new iWeapon = Client_GetActiveWeapon(client);
			
			// He's holding a weapon and
			if(iWeapon != -1 && 
			// we just started recording. Always save the first weapon!
			   (g_iRecordedTicks[client] == 0 ||
			// This is a new weapon, he didn't held before.
			   g_iRecordPreviousWeapon[client] != iWeapon))
			{
				iNewWeapon = iWeapon;
			}
		}
		
		if(iNewWeapon != -1)
		{
			// Save it
			if(IsValidEntity(iNewWeapon) && IsValidEdict(iNewWeapon))
			{
				g_iRecordPreviousWeapon[client] = iNewWeapon;
				
				new String:sClassName[64];
				GetEdictClassname(iNewWeapon, sClassName, sizeof(sClassName));
				ReplaceString(sClassName, sizeof(sClassName), "weapon_", "", false);
				
				new String:sWeaponAlias[64];
				CS_GetTranslatedWeaponAlias(sClassName, sWeaponAlias, sizeof(sWeaponAlias));
				new CSWeaponID:weaponId = CS_AliasToWeaponID(sWeaponAlias);
				
				iFrame[newWeapon] = weaponId;
			}
		}
		
		PushArrayArray(g_hRecording[client], iFrame, _:FrameInfo);
		
		g_iRecordedTicks[client]++;
	}
	
	// Bot is mimicing something
	else if(g_hBotMimicsRecord[client] != INVALID_HANDLE)
	{
		// Is this a valid living bot?
		if(!IsPlayerAlive(client) || GetClientTeam(client) < CS_TEAM_T)
			return Plugin_Continue;
		
		if(g_iBotMimicTick[client] >= g_iBotMimicRecordTickCount[client])
		{
			g_iBotMimicTick[client] = 0;
			g_iCurrentAdditionalTeleportIndex[client] = 0;
		}
		
		new iFrame[FRAME_INFO_SIZE];
		GetArrayArray(g_hBotMimicsRecord[client], g_iBotMimicTick[client], iFrame, _:FrameInfo);
		
		buttons = iFrame[playerButtons];
		impulse = iFrame[playerImpulse];
		Array_Copy(iFrame[predictedVelocity], vel, 3);
		Array_Copy(iFrame[predictedAngles], angles, 2);
		subtype = iFrame[playerSubtype];
		seed = iFrame[playerSeed];
		weapon = 0;
		
		decl Float:fAcutalVelocity[3];
		Array_Copy(iFrame[actualVelocity], fAcutalVelocity, 3);
		
		// We're supposed to teleport stuff?
		if(iFrame[additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY))
		{
			new iAT[AT_SIZE], Handle:hAdditionalTeleport, String:sPath[PLATFORM_MAX_PATH];
			GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));
			GetTrieValue(g_hLoadedRecordsAdditionalTeleport, sPath, hAdditionalTeleport);
			GetArrayArray(hAdditionalTeleport, g_iCurrentAdditionalTeleportIndex[client], iAT, AT_SIZE);
			
			new Float:fOrigin[3], Float:fAngles[3], Float:fVelocity[3];
			Array_Copy(iAT[_:atOrigin], fOrigin, 3);
			Array_Copy(iAT[_:atAngles], fAngles, 3);
			Array_Copy(iAT[_:atVelocity], fVelocity, 3);
			
			// The next call to Teleport is ok.
			g_bValidTeleportCall[client] = true;
			
			// THATS STUPID!
			// Only pass the arguments, if they were set..
			if(iAT[_:atFlags] & ADDITIONAL_FIELD_TELEPORTED_ORIGIN)
			{
				if(iAT[_:atFlags] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				{
					if(iAT[_:atFlags] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
						TeleportEntity(client, fOrigin, fAngles, fVelocity);
					else
						TeleportEntity(client, fOrigin, fAngles, NULL_VECTOR);
				}
				else
				{
					if(iAT[_:atFlags] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
						TeleportEntity(client, fOrigin, NULL_VECTOR, fVelocity);
					else
						TeleportEntity(client, fOrigin, NULL_VECTOR, NULL_VECTOR);
				}
			}
			else
			{
				if(iAT[_:atFlags] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				{
					if(iAT[_:atFlags] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
						TeleportEntity(client, NULL_VECTOR, fAngles, fVelocity);
					else
						TeleportEntity(client, NULL_VECTOR, fAngles, NULL_VECTOR);
				}
				else
				{
					if(iAT[_:atFlags] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
						TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, fVelocity);
				}
			}
			
			g_iCurrentAdditionalTeleportIndex[client]++;
		}
		
		// This is the first tick. Teleport him to the initial position
		if(g_iBotMimicTick[client] == 0)
		{
			g_bValidTeleportCall[client] = true;
			TeleportEntity(client, g_fInitialPosition[client], g_fInitialAngles[client], fAcutalVelocity);
			Client_RemoveAllWeapons(client);
			
			Call_StartForward(g_hfwdOnPlayerMimicLoops);
			Call_PushCell(client);
			Call_Finish();
		}
		else
		{
			g_bValidTeleportCall[client] = true;
			TeleportEntity(client, NULL_VECTOR, angles, fAcutalVelocity);
		}
		
		if(iFrame[newWeapon] != CSWeapon_NONE)
		{
			decl String:sAlias[64];
			CS_WeaponIDToAlias(iFrame[newWeapon], sAlias, sizeof(sAlias));
			
			Format(sAlias, sizeof(sAlias), "weapon_%s", sAlias);
			
			if(g_iBotMimicTick[client] > 0 && Client_HasWeapon(client, sAlias))
			{
				weapon = Client_GetWeapon(client, sAlias);
				g_iBotActiveWeapon[client] = weapon;
				SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", weapon);
				Client_SetActiveWeapon(client, weapon);
			}
			else
			{
				weapon = Client_GiveWeapon(client, sAlias, false);
				g_iBotActiveWeapon[client] = weapon;
				SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", weapon);
				Client_SetActiveWeapon(client, weapon);
			}
		}
		
		g_iBotMimicTick[client]++;
		
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}

/**
 * Event Callbacks
 */
public Event_OnPlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(!client)
		return;
	
	// Restart moving on spawn!
	if(g_hBotMimicsRecord[client] != INVALID_HANDLE)
	{
		g_iBotMimicTick[client] = 0;
		g_iCurrentAdditionalTeleportIndex[client] = 0;
	}
}

public Event_OnPlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(!client)
		return;
	
	// This one has been recording currently
	if(g_hRecording[client] != INVALID_HANDLE)
	{
		BotMimic_StopRecording(client, true);
	}
	// This bot has been playing one
	else if(g_hBotMimicsRecord[client] != INVALID_HANDLE)
	{
		// Respawn the bot after death!
		g_iBotMimicTick[client] = 0;
		g_iCurrentAdditionalTeleportIndex[client] = 0;
		if(GetClientTeam(client) >= CS_TEAM_T)
			CreateTimer(1.0, Timer_DelayedRespawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

/**
 * Timer Callbacks
 */
public Action:Timer_DelayedRespawn(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if(!client)
		return Plugin_Stop;
	
	if(g_hBotMimicsRecord[client] != INVALID_HANDLE && IsClientInGame(client) && !IsPlayerAlive(client) && IsFakeClient(client) && GetClientTeam(client) >= CS_TEAM_T)
		CS_RespawnPlayer(client);
	
	return Plugin_Stop;
}


/**
 * SDKHooks Callbacks
 */
// Don't allow mimicing players any other weapon than the one recorded!!
public Action:Hook_WeaponCanSwitchTo(client, weapon)
{
	if(g_hBotMimicsRecord[client] == INVALID_HANDLE)
		return Plugin_Continue;
	
	if(g_iBotActiveWeapon[client] != weapon)
	{
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

/**
 * DHooks Callbacks
 */
public MRESReturn:DHooks_OnTeleport(client, Handle:hParams)
{
	// This one is currently mimicing something.
	if(g_hBotMimicsRecord[client] != INVALID_HANDLE)
	{
		// We didn't allow that teleporting. STOP THAT.
		if(!g_bValidTeleportCall[client])
			return MRES_Supercede;
		g_bValidTeleportCall[client] = false;
		return MRES_Ignored;
	}
	
	// Don't care if he's not recording.
	if(g_hRecording[client] == INVALID_HANDLE)
		return MRES_Ignored;
	
	new Float:origin[3], Float:angles[3], Float:velocity[3];
	new bool:bOriginNull = DHookIsNullParam(hParams, 1);
	new bool:bAnglesNull = DHookIsNullParam(hParams, 2);
	new bool:bVelocityNull = DHookIsNullParam(hParams, 3);
	
	if(!bOriginNull)
		DHookGetParamVector(hParams, 1, origin);
	
	if(!bAnglesNull)
	{
		for(new i=0;i<3;i++)
			angles[i] = DHookGetParamObjectPtrVar(hParams, 2, i*4, ObjectValueType_Float);
	}
	
	if(!bVelocityNull)
		DHookGetParamVector(hParams, 3, velocity);
	
	if(bOriginNull && bAnglesNull && bVelocityNull)
		return MRES_Ignored;
	
	new iAT[AT_SIZE];
	Array_Copy(origin, iAT[_:atOrigin], 3);
	Array_Copy(angles, iAT[_:atAngles], 3);
	Array_Copy(velocity, iAT[_:atVelocity], 3);
	
	// Remember, 
	if(!bOriginNull)
		iAT[_:atFlags] |= ADDITIONAL_FIELD_TELEPORTED_ORIGIN;
	if(!bAnglesNull)
		iAT[_:atFlags] |= ADDITIONAL_FIELD_TELEPORTED_ANGLES;
	if(!bVelocityNull)
		iAT[_:atFlags] |= ADDITIONAL_FIELD_TELEPORTED_VELOCITY;
	
	PushArrayArray(g_hRecordingAdditionalTeleport[client], iAT, AT_SIZE);
	
	return MRES_Ignored;
}

/**
 * Natives
 */
public StartRecording(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if(g_hRecording[client] != INVALID_HANDLE)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is already recording.");
		return;
	}
	
	if(g_hBotMimicsRecord[client] != INVALID_HANDLE)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is currently mimicing another record.");
		return;
	}
	
	g_hRecording[client] = CreateArray(_:FrameInfo);
	g_hRecordingAdditionalTeleport[client] = CreateArray(_:AdditionalTeleport);
	GetClientAbsOrigin(client, g_fInitialPosition[client]);
	GetClientEyeAngles(client, g_fInitialAngles[client]);
	g_iRecordedTicks[client] = 0;
	g_iOriginSnapshotInterval[client] = 0;
	
	GetNativeString(2, g_sRecordName[client], MAX_RECORD_NAME_LENGTH);
	GetNativeString(3, g_sRecordCategory[client], PLATFORM_MAX_PATH);
	GetNativeString(4, g_sRecordSubDir[client], PLATFORM_MAX_PATH);
	
	if(g_sRecordCategory[client][0] == '\0')
		strcopy(g_sRecordCategory[client], sizeof(g_sRecordCategory[]), DEFAULT_CATEGORY);
	
	// Path:
	// data/botmimic/%CATEGORY%/map_name/%SUBDIR%/record.rec
	// subdir can be omitted, default category is "default"
	
	// All demos reside in the default path (data/botmimic)
	BuildPath(Path_SM, g_sRecordPath[client], PLATFORM_MAX_PATH, "%s%s", DEFAULT_RECORD_FOLDER, g_sRecordCategory[client]);
	
	// Remove trailing slashes
	if(g_sRecordPath[client][strlen(g_sRecordPath[client])-1] == '\\' ||
		g_sRecordPath[client][strlen(g_sRecordPath[client])-1] == '/')
		g_sRecordPath[client][strlen(g_sRecordPath[client])-1] = '\0';
	
	new Action:result;
	Call_StartForward(g_hfwdOnStartRecording);
	Call_PushCell(client);
	Call_PushString(g_sRecordName[client]);
	Call_PushString(g_sRecordCategory[client]);
	Call_PushString(g_sRecordSubDir[client]);
	Call_PushString(g_sRecordPath[client]);
	Call_Finish(result);
	
	if(result >= Plugin_Handled)
		BotMimic_StopRecording(client, false);
}

public StopRecording(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	// Not recording..
	if(g_hRecording[client] == INVALID_HANDLE)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return;
	}
	
	new bool:save = GetNativeCell(2);
	
	new Action:result;
	Call_StartForward(g_hfwdOnStopRecording);
	Call_PushCell(client);
	Call_PushString(g_sRecordName[client]);
	Call_PushString(g_sRecordCategory[client]);
	Call_PushString(g_sRecordSubDir[client]);
	Call_PushString(g_sRecordPath[client]);
	Call_PushCellRef(save);
	Call_Finish(result);
	
	// Don't stop recording?
	if(result >= Plugin_Handled)
		return;
	
	if(save)
	{
		new iEndTime = GetTime();
		
		decl String:sMapName[64], String:sPath[PLATFORM_MAX_PATH];
		GetCurrentMap(sMapName, sizeof(sMapName));
		
		// Check if the default record folder exists?
		BuildPath(Path_SM, sPath, sizeof(sPath), DEFAULT_RECORD_FOLDER);
		// Remove trailing slashes
		if(sPath[strlen(sPath)-1] == '\\' || sPath[strlen(sPath)-1] == '/')
			sPath[strlen(sPath)-1] = '\0';
		
		if(!CheckCreateDirectory(sPath, 511))
			return;
		
		// Check if the category folder exists?
		BuildPath(Path_SM, sPath, sizeof(sPath), "%s%s", DEFAULT_RECORD_FOLDER, g_sRecordCategory[client]);
		if(!CheckCreateDirectory(sPath, 511))
			return;
		
		// Check, if there is a folder for this map already
		Format(sPath, sizeof(sPath), "%s/%s", g_sRecordPath[client], sMapName);
		if(!CheckCreateDirectory(sPath, 511))
			return;
		
		// Check if the subdirectory exists
		if(g_sRecordSubDir[client][0] != '\0')
		{
			Format(sPath, sizeof(sPath), "%s/%s", sPath, g_sRecordSubDir[client]);
			if(!CheckCreateDirectory(sPath, 511))
				return;
		}
		
		Format(sPath, sizeof(sPath), "%s/%d.rec", sPath, iEndTime);
		
		// Add to our loaded record list
		new iHeader[FILE_HEADER_LENGTH];
		iHeader[_:FH_binaryFormatVersion] = BINARY_FORMAT_VERSION;
		iHeader[_:FH_recordEndTime] = iEndTime;
		iHeader[_:FH_tickCount] = GetArraySize(g_hRecording[client]);
		strcopy(iHeader[_:FH_recordName], MAX_RECORD_NAME_LENGTH, g_sRecordName[client]);
		Array_Copy(g_fInitialPosition[client], iHeader[_:FH_initialPosition], 3);
		Array_Copy(g_fInitialAngles[client], iHeader[_:FH_initialAngles], 3);
		iHeader[_:FH_frames] = g_hRecording[client];
		
		if(GetArraySize(g_hRecordingAdditionalTeleport[client]) > 0)
		{
			SetTrieValue(g_hLoadedRecordsAdditionalTeleport, sPath, g_hRecordingAdditionalTeleport[client]);
		}
		else
		{
			CloseHandle(g_hRecordingAdditionalTeleport[client]);
		}
		
		WriteRecordToDisk(sPath, iHeader);
		
		SetTrieArray(g_hLoadedRecords, sPath, iHeader, _:FileHeader);
		SetTrieString(g_hLoadedRecordsCategory, sPath, g_sRecordCategory[client]);
		PushArrayString(g_hSortedRecordList, sPath);
		if(FindStringInArray(g_hSortedCategoryList, g_sRecordCategory[client]) == -1)
			PushArrayString(g_hSortedCategoryList, g_sRecordCategory[client]);
		SortRecordList();
		
		Call_StartForward(g_hfwdOnRecordSaved);
		Call_PushCell(client);
		Call_PushString(g_sRecordName[client]);
		Call_PushString(g_sRecordCategory[client]);
		Call_PushString(g_sRecordSubDir[client]);
		Call_PushString(sPath);
		Call_Finish();
	}
	else
	{
		CloseHandle(g_hRecording[client]);
		CloseHandle(g_hRecordingAdditionalTeleport[client]);
	}
	
	g_hRecording[client] = INVALID_HANDLE;
	g_hRecordingAdditionalTeleport[client] = INVALID_HANDLE;
	g_iRecordedTicks[client] = 0;
	g_iRecordPreviousWeapon[client] = 0;
	g_sRecordName[client][0] = 0;
	g_sRecordPath[client][0] = 0;
	g_sRecordCategory[client][0] = 0;
	g_sRecordSubDir[client][0] = 0;
	g_iCurrentAdditionalTeleportIndex[client] = 0;
	g_iOriginSnapshotInterval[client] = 0;
}

public DeleteRecord(Handle:plugin, numParams)
{
	new iLen;
	GetNativeStringLength(1, iLen);
	new String:sPath[iLen+1];
	GetNativeString(1, sPath, iLen+1);
	
	// Do we have this record loaded?
	new iFileHeader[FILE_HEADER_LENGTH];
	if(!GetTrieArray(g_hLoadedRecords, sPath, iFileHeader, _:FileHeader))
	{
		if(!FileExists(sPath))
			return -1;
		
		// Try to load it to make sure it's a record file we're deleting here!
		new BMError:error = LoadRecordFromFile(sPath, DEFAULT_CATEGORY, iFileHeader, true, false);
		if(error == BM_FileNotFound || error == BM_BadFile)
			return -1;
	}
	
	new iCount;
	if(iFileHeader[_:FH_frames] != INVALID_HANDLE)
	{
		for(new i=1;i<=MaxClients;i++)
		{
			// Stop the bots from mimicing this one
			if(g_hBotMimicsRecord[i] == iFileHeader[_:FH_frames])
			{
				BotMimic_StopPlayerMimic(i);
				iCount++;
			}
		}
		
		// Discard the frames
		CloseHandle(iFileHeader[_:FH_frames]);
	}
	
	new String:sCategory[64];
	GetTrieString(g_hLoadedRecordsCategory, sPath, sCategory, sizeof(sCategory));
	
	RemoveFromTrie(g_hLoadedRecords, sPath);
	RemoveFromTrie(g_hLoadedRecordsCategory, sPath);
	RemoveFromArray(g_hSortedRecordList, FindStringInArray(g_hSortedRecordList, sPath));
	new Handle:hAT;
	if(GetTrieValue(g_hLoadedRecordsAdditionalTeleport, sPath, hAT))
		CloseHandle(hAT);
	RemoveFromTrie(g_hLoadedRecordsAdditionalTeleport, sPath);
	
	// Delete the file
	if(FileExists(sPath))
	{
		DeleteFile(sPath);
	}
	
	Call_StartForward(g_hfwdOnRecordDeleted);
	Call_PushString(iFileHeader[_:FH_recordName]);
	Call_PushString(sCategory);
	Call_PushString(sPath);
	Call_Finish();
	
	return iCount;
}

public IsPlayerRecording(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return false;
	}
	
	return g_hRecording[client] != INVALID_HANDLE;
}

public IsPlayerMimicing(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return false;
	}
	
	return g_hBotMimicsRecord[client] != INVALID_HANDLE;
}

public GetRecordPlayerMimics(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if(!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}
	
	new iLen = GetNativeCell(3);
	new String:sPath[iLen];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, iLen);
	SetNativeString(2, sPath, iLen);
}

public StopPlayerMimic(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if(!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}
	
	new String:sPath[PLATFORM_MAX_PATH];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));
	
	g_hBotMimicsRecord[client] = INVALID_HANDLE;
	g_iBotMimicTick[client] = 0;
	g_iCurrentAdditionalTeleportIndex[client] = 0;
	g_iBotMimicRecordTickCount[client] = 0;
	g_bValidTeleportCall[client] = false;
	
	new iFileHeader[FILE_HEADER_LENGTH];
	GetTrieArray(g_hLoadedRecords, sPath, iFileHeader, _:FileHeader);
	
	SDKUnhook(client, SDKHook_WeaponCanSwitchTo, Hook_WeaponCanSwitchTo);
	
	new String:sCategory[64];
	GetTrieString(g_hLoadedRecordsCategory, sPath, sCategory, sizeof(sCategory));
	
	Call_StartForward(g_hfwdOnPlayerStopsMimicing);
	Call_PushCell(client);
	Call_PushString(iFileHeader[_:FH_recordName]);
	Call_PushString(sCategory);
	Call_PushString(sPath);
	Call_Finish();
}

public PlayRecordFromFile(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		return _:BM_BadClient;
	}
	
	new iLen;
	GetNativeStringLength(2, iLen);
	decl String:sPath[iLen+1];
	GetNativeString(2, sPath, iLen+1);
	
	if(!FileExists(sPath))
		return _:BM_FileNotFound;
	
	return _:PlayRecord(client, sPath);
}

public PlayRecordByName(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		return _:BM_BadClient;
	}
	
	new iLen;
	GetNativeStringLength(2, iLen);
	decl String:sName[iLen+1];
	GetNativeString(2, sName, iLen+1);
	
	decl String:sPath[PLATFORM_MAX_PATH];
	new iSize = GetArraySize(g_hSortedRecordList);
	new iFileHeader[FILE_HEADER_LENGTH], iRecentTimeStamp, String:sRecentPath[PLATFORM_MAX_PATH];
	for(new i=0;i<iSize;i++)
	{
		GetArrayString(g_hSortedRecordList, i, sPath, sizeof(sPath));
		GetTrieArray(g_hLoadedRecords, sPath, iFileHeader, _:FileHeader);
		if(StrEqual(sName, iFileHeader[_:FH_recordName]))
		{
			if(iRecentTimeStamp == 0 || iRecentTimeStamp < iFileHeader[FH_recordEndTime])
			{
				iRecentTimeStamp = iFileHeader[FH_recordEndTime];
				strcopy(sRecentPath, sizeof(sRecentPath), sPath);
			}
		}
	}
	
	if(!iRecentTimeStamp || !FileExists(sRecentPath))
		return _:BM_FileNotFound;
	
	return _:PlayRecord(client, sRecentPath);
}

public ResetPlayback(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if(!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}
	
	g_iBotMimicTick[client] = 0;
	g_iCurrentAdditionalTeleportIndex[client] = 0;
}

public GetFileHeaders(Handle:plugin, numParams)
{
	new iLen;
	GetNativeStringLength(1, iLen);
	decl String:sPath[iLen+1];
	GetNativeString(1, sPath, iLen+1);
	
	if(!FileExists(sPath))
	{
		return _:BM_FileNotFound;
	}
	
	new iFileHeader[FILE_HEADER_LENGTH];
	if(!GetTrieArray(g_hLoadedRecords, sPath, iFileHeader, _:FileHeader))
	{
		decl String:sCategory[64];
		if(!GetTrieString(g_hLoadedRecordsCategory, sPath, sCategory, sizeof(sCategory)))
			strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
		new BMError:error = LoadRecordFromFile(sPath, sCategory, iFileHeader, true, false);
		if(error != BM_NoError)
			return _:error;
	}
	
	new iLengthOfBMFileHeader = _:BMFileHeader;
	new iExposedFileHeader[iLengthOfBMFileHeader];
	iExposedFileHeader[_:BMFH_binaryFormatVersion] = iFileHeader[_:FH_binaryFormatVersion];
	iExposedFileHeader[_:BMFH_recordEndTime] = iFileHeader[_:FH_recordEndTime];
	strcopy(iExposedFileHeader[_:BMFH_recordName], MAX_RECORD_NAME_LENGTH, iFileHeader[_:FH_recordName]);
	iExposedFileHeader[_:BMFH_tickCount] = iFileHeader[_:FH_tickCount];
	Array_Copy(iFileHeader[_:BMFH_initialPosition], iExposedFileHeader[_:FH_initialPosition], 3);
	Array_Copy(iFileHeader[_:BMFH_initialAngles], iExposedFileHeader[_:FH_initialAngles], 3);
	
	SetNativeArray(2, iExposedFileHeader, _:BMFileHeader);
	return _:BM_NoError;
}

public ChangeRecordName(Handle:plugin, numParams)
{
	new iLen;
	GetNativeStringLength(1, iLen);
	decl String:sPath[iLen+1];
	GetNativeString(1, sPath, iLen+1);
	
	if(!FileExists(sPath))
	{
		return _:BM_FileNotFound;
	}
	
	decl String:sCategory[64];
	if(!GetTrieString(g_hLoadedRecordsCategory, sPath, sCategory, sizeof(sCategory)))
		strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
	
	new iFileHeader[FILE_HEADER_LENGTH];
	if(!GetTrieArray(g_hLoadedRecords, sPath, iFileHeader, _:FileHeader))
	{
		new BMError:error = LoadRecordFromFile(sPath, sCategory, iFileHeader, false, false);
		if(error != BM_NoError)
			return _:error;
	}
	
	// Load the whole record first or we'd lose the frames!
	if(iFileHeader[_:FH_frames] == INVALID_HANDLE)
		LoadRecordFromFile(sPath, sCategory, iFileHeader, false, true);
	
	GetNativeStringLength(2, iLen);
	decl String:sName[iLen+1];
	GetNativeString(2, sName, iLen+1);
	
	strcopy(iFileHeader[_:FH_recordName], MAX_RECORD_NAME_LENGTH, sName);
	SetTrieArray(g_hLoadedRecords, sPath, iFileHeader, _:FileHeader);
	
	WriteRecordToDisk(sPath, iFileHeader);
	
	return _:BM_NoError;
}

public GetLoadedRecordCategoryList(Handle:plugin, numParams)
{
	return _:g_hSortedCategoryList;
}

public GetLoadedRecordList(Handle:plugin, numParams)
{
	return _:g_hSortedRecordList;
}

public GetFileCategory(Handle:plugin, numParams)
{
	new iLen;
	GetNativeStringLength(1, iLen);
	decl String:sPath[iLen+1];
	GetNativeString(1, sPath, iLen+1);
	
	iLen = GetNativeCell(3);
	new String:sCategory[iLen];
	new bool:bFound = GetTrieString(g_hLoadedRecordsCategory, sPath, sCategory, iLen);
	
	SetNativeString(2, sCategory, iLen);
	return _:bFound;
}


/**
 * Helper functions
 */

ParseRecordsInDirectory(const String:sPath[], const String:sCategory[], bool:subdir)
{
	decl String:sMapFilePath[PLATFORM_MAX_PATH];
	// We already are in the map folder? Don't add it again!
	if(subdir)
	{
		strcopy(sMapFilePath, sizeof(sMapFilePath), sPath);
	}
	// We're in a category. add the mapname to load the correct records for the current map
	else
	{
		decl String:sMapName[64];
		GetCurrentMap(sMapName, sizeof(sMapName));
		Format(sMapFilePath, sizeof(sMapFilePath), "%s/%s", sPath, sMapName);
	}
	
	new Handle:hDir = OpenDirectory(sMapFilePath);
	if(hDir == INVALID_HANDLE)
		return;
	
	new String:sFile[64], FileType:fileType, String:sFilePath[PLATFORM_MAX_PATH], iFileHeader[FILE_HEADER_LENGTH];
	while(ReadDirEntry(hDir, sFile, sizeof(sFile), fileType))
	{
		switch(fileType)
		{
			// This is a record for this map.
			case FileType_File:
			{
				Format(sFilePath, sizeof(sFilePath), "%s/%s", sMapFilePath, sFile);
				LoadRecordFromFile(sFilePath, sCategory, iFileHeader, true, false);
			}
			// There's a subdir containing more records.
			case FileType_Directory:
			{
				// INFINITE RECURSION ANYONE?
				if(StrEqual(sFile, ".") || StrEqual(sFile, ".."))
					continue;
				
				Format(sFilePath, sizeof(sFilePath), "%s/%s", sMapFilePath, sFile);
				ParseRecordsInDirectory(sFilePath, sCategory, true);
			}
		}
		
	}
	CloseHandle(hDir);
}

WriteRecordToDisk(const String:sPath[], iFileHeader[FILE_HEADER_LENGTH])
{
	new Handle:hFile = OpenFile(sPath, "wb");
	if(hFile == INVALID_HANDLE)
	{
		LogError("Can't open the record file for writing! (%s)", sPath);
		return;
	}
	
	WriteFileCell(hFile, BM_MAGIC, 4);
	WriteFileCell(hFile, iFileHeader[_:FH_binaryFormatVersion], 1);
	WriteFileCell(hFile, iFileHeader[_:FH_recordEndTime], 4);
	WriteFileCell(hFile, strlen(iFileHeader[_:FH_recordName]), 1);
	WriteFileString(hFile, iFileHeader[_:FH_recordName], false);
	
	WriteFile(hFile, _:iFileHeader[_:FH_initialPosition], 3, 4);
	WriteFile(hFile, _:iFileHeader[_:FH_initialAngles], 2, 4);
	
	new Handle:hAdditionalTeleport, iATIndex;
	GetTrieValue(g_hLoadedRecordsAdditionalTeleport, sPath, hAdditionalTeleport);
	
	new iTickCount = iFileHeader[_:FH_tickCount];
	WriteFileCell(hFile, iTickCount, 4);
	
	new iFrame[FRAME_INFO_SIZE];
	for(new i=0;i<iTickCount;i++)
	{
		GetArrayArray(iFileHeader[_:FH_frames], i, iFrame, _:FrameInfo);
		WriteFile(hFile, iFrame, _:FrameInfo, 4);
		
		// Handle the optional Teleport call
		if(hAdditionalTeleport != INVALID_HANDLE && iFrame[_:additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY))
		{
			new iAT[AT_SIZE];
			GetArrayArray(hAdditionalTeleport, iATIndex, iAT, AT_SIZE);
			if(iFrame[_:additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ORIGIN)
				WriteFile(hFile, _:iAT[_:atOrigin], 3, 4);
			if(iFrame[_:additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				WriteFile(hFile, _:iAT[_:atAngles], 3, 4);
			if(iFrame[_:additionalFields] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
				WriteFile(hFile, _:iAT[_:atVelocity], 3, 4);
			iATIndex++;
		}
	}
	
	CloseHandle(hFile);
}

BMError:LoadRecordFromFile(const String:path[], const String:sCategory[], headerInfo[FILE_HEADER_LENGTH], bool:onlyHeader, bool:forceReload)
{
	if(!FileExists(path))
		return BM_FileNotFound;
	
	// Already loaded that file?
	new bool:bAlreadyLoaded = false;
	if(GetTrieArray(g_hLoadedRecords, path, headerInfo, _:FileHeader))
	{
		// Header already loaded.
		if(onlyHeader && !forceReload)
			return BM_NoError;
		
		bAlreadyLoaded = true;
	}
	
	new Handle:hFile = OpenFile(path, "rb");
	if(hFile == INVALID_HANDLE)
		return BM_FileNotFound;
	
	new iMagic;
	ReadFileCell(hFile, iMagic, 4);
	if(iMagic != BM_MAGIC)
	{
		CloseHandle(hFile);
		return BM_BadFile;
	}
	
	new iBinaryFormatVersion;
	ReadFileCell(hFile, iBinaryFormatVersion, 1);
	headerInfo[_:FH_binaryFormatVersion] = iBinaryFormatVersion;
	
	if(iBinaryFormatVersion > BINARY_FORMAT_VERSION)
	{
		CloseHandle(hFile);
		return BM_NewerBinaryVersion;
	}
	
	new iRecordTime, iNameLength;
	ReadFileCell(hFile, iRecordTime, 4);
	ReadFileCell(hFile, iNameLength, 1);
	decl String:sRecordName[iNameLength+1];
	ReadFileString(hFile, sRecordName, iNameLength+1, iNameLength);
	sRecordName[iNameLength] = '\0';
	
	ReadFile(hFile, _:headerInfo[_:FH_initialPosition], 3, 4);
	ReadFile(hFile, _:headerInfo[_:FH_initialAngles], 2, 4);
	
	new iTickCount;
	ReadFileCell(hFile, iTickCount, 4);
	
	headerInfo[_:FH_recordEndTime] = iRecordTime;
	strcopy(headerInfo[_:FH_recordName], MAX_RECORD_NAME_LENGTH, sRecordName);
	headerInfo[_:FH_tickCount] = iTickCount;
	headerInfo[_:FH_frames] = INVALID_HANDLE;
	
	//PrintToServer("Record %s:", sRecordName);
	//PrintToServer("File %s:", path);
	//PrintToServer("EndTime: %d, BinaryVersion: 0x%x, ticks: %d, initialPosition: %f,%f,%f, initialAngles: %f,%f,%f", iRecordTime, iBinaryFormatVersion, iTickCount, headerInfo[_:FH_initialPosition][0], headerInfo[_:FH_initialPosition][1], headerInfo[_:FH_initialPosition][2], headerInfo[_:FH_initialAngles][0], headerInfo[_:FH_initialAngles][1], headerInfo[_:FH_initialAngles][2]);
	
	SetTrieArray(g_hLoadedRecords, path, headerInfo, _:FileHeader);
	SetTrieString(g_hLoadedRecordsCategory, path, sCategory);
	
	if(!bAlreadyLoaded)
		PushArrayString(g_hSortedRecordList, path);
	
	if(FindStringInArray(g_hSortedCategoryList, sCategory) == -1)
		PushArrayString(g_hSortedCategoryList, sCategory);
	
	// Sort it by record end time
	SortRecordList();
	
	if(onlyHeader)
	{
		CloseHandle(hFile);
		return BM_NoError;
	}
	
	new Handle:hRecordFrames = CreateArray(_:FrameInfo);
	new Handle:hAdditionalTeleport = CreateArray(AT_SIZE);
	
	new iFrame[FRAME_INFO_SIZE];
	for(new i=0;i<iTickCount;i++)
	{
		ReadFile(hFile, iFrame, _:FrameInfo, 4);
		PushArrayArray(hRecordFrames, iFrame, _:FrameInfo);
		
		if(iFrame[_:additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY))
		{
			new iAT[AT_SIZE];
			if(iFrame[_:additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ORIGIN)
				ReadFile(hFile, _:iAT[_:atOrigin], 3, 4);
			if(iFrame[_:additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				ReadFile(hFile, _:iAT[_:atAngles], 3, 4);
			if(iFrame[_:additionalFields] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
				ReadFile(hFile, _:iAT[_:atVelocity], 3, 4);
			iAT[_:atFlags] = iFrame[_:additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY);
			PushArrayArray(hAdditionalTeleport, iAT, AT_SIZE);
		}
	}
	
	headerInfo[_:FH_frames] = hRecordFrames;
	
	SetTrieArray(g_hLoadedRecords, path, headerInfo, _:FileHeader);
	if(GetArraySize(hAdditionalTeleport) > 0)
		SetTrieValue(g_hLoadedRecordsAdditionalTeleport, path, hAdditionalTeleport);
	
	CloseHandle(hFile);
	return BM_NoError;
}

SortRecordList()
{
	SortADTArrayCustom(g_hSortedRecordList, SortFuncADT_ByEndTime);
	SortADTArray(g_hSortedCategoryList, Sort_Descending, Sort_String);
}

public SortFuncADT_ByEndTime(index1, index2, Handle:array, Handle:hndl)
{
	new String:path1[PLATFORM_MAX_PATH], String:path2[PLATFORM_MAX_PATH];
	GetArrayString(array, index1, path1, sizeof(path1));
	GetArrayString(array, index2, path2, sizeof(path2));
	
	new header1[FILE_HEADER_LENGTH], header2[FILE_HEADER_LENGTH];
	GetTrieArray(g_hLoadedRecords, path1, header1, _:FileHeader);
	GetTrieArray(g_hLoadedRecords, path2, header2, _:FileHeader);
	
	return header1[_:FH_recordEndTime] - header2[_:FH_recordEndTime];
}

BMError:PlayRecord(client, const String:path[])
{
	// He's currently recording. Don't start to play some record on him at the same time.
	if(g_hRecording[client] != INVALID_HANDLE)
	{
		return BM_BadClient;
	}
	
	new iFileHeader[FILE_HEADER_LENGTH];
	GetTrieArray(g_hLoadedRecords, path, iFileHeader, _:FileHeader);
	
	// That record isn't fully loaded yet. Do that now.
	if(iFileHeader[_:FH_frames] == INVALID_HANDLE)
	{
		decl String:sCategory[64];
		if(!GetTrieString(g_hLoadedRecordsCategory, path, sCategory, sizeof(sCategory)))
			strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
		new BMError:error = LoadRecordFromFile(path, sCategory, iFileHeader, false, true);
		if(error != BM_NoError)
			return error;
	}
	
	g_hBotMimicsRecord[client] = iFileHeader[_:FH_frames];
	g_iBotMimicTick[client] = 0;
	g_iBotMimicRecordTickCount[client] = iFileHeader[_:FH_tickCount];
	g_iCurrentAdditionalTeleportIndex[client] = 0;
	
	Array_Copy(iFileHeader[_:FH_initialPosition], g_fInitialPosition[client], 3);
	Array_Copy(iFileHeader[_:FH_initialAngles], g_fInitialAngles[client], 3);
	
	SDKHook(client, SDKHook_WeaponCanSwitchTo, Hook_WeaponCanSwitchTo);
	
	// Respawn him to get him moving!
	if(IsClientInGame(client) && !IsPlayerAlive(client) && GetClientTeam(client) >= CS_TEAM_T)
		CS_RespawnPlayer(client);
	
	new String:sCategory[64];
	GetTrieString(g_hLoadedRecordsCategory, path, sCategory, sizeof(sCategory));
	
	new Action:result;
	Call_StartForward(g_hfwdOnPlayerStartsMimicing);
	Call_PushCell(client);
	Call_PushString(iFileHeader[_:FH_recordName]);
	Call_PushString(sCategory);
	Call_PushString(path);
	Call_Finish(result);
	
	// Someone doesn't want this guy to play that record.
	if(result >= Plugin_Handled)
	{
		g_hBotMimicsRecord[client] = INVALID_HANDLE;
		g_iBotMimicRecordTickCount[client] = 0;
	}
	
	return BM_NoError;
}



stock bool:CheckCreateDirectory(const String:sPath[], mode)
{
	if(!DirExists(sPath))
	{
		CreateDirectory(sPath, mode);
		if(!DirExists(sPath))
		{
			LogError("Can't create a new directory. Please create one manually! (%s)", sPath);
			return false;
		}
	}
	return true;
}

stock GetFileFromFrameHandle(Handle:frames, String:path[], maxlen)
{
	new iSize = GetArraySize(g_hSortedRecordList);
	decl String:sPath[PLATFORM_MAX_PATH], iFileHeader[FILE_HEADER_LENGTH];
	for(new i=0;i<iSize;i++)
	{
		GetArrayString(g_hSortedRecordList, i, sPath, sizeof(sPath));
		GetTrieArray(g_hLoadedRecords, sPath, iFileHeader, _:FileHeader);
		if(iFileHeader[_:FH_frames] != frames)
			continue;
		
		strcopy(path, maxlen, sPath);
		break;
	}
}