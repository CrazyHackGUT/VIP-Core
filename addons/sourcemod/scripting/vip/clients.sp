
ResetClient(iClient)
{
	g_iClientInfo[iClient] &= ~IS_VIP;
	
	UTIL_CloseHandleEx(g_hFeatures[iClient]);
	UTIL_CloseHandleEx(g_hFeatureStatus[iClient]);
}

public OnClientPutInServer(iClient)
{
//	g_iClientInfo[iClient] = 0;
	DebugMessage("OnClientPostAdminCheck %N (%i): %b", iClient, iClient, g_iClientInfo[iClient])

	Clients_CheckVipAccess(iClient, true);
}

public OnClientDisconnect(iClient)
{
/*	if(g_bIsClientVIP[iClient])
	{
		SaveClient(iClient);
	}*/

	ResetClient(iClient);
	UTIL_CloseHandleEx(g_ClientData[iClient]);
	g_iClientInfo[iClient] = 0;
}

Clients_CheckVipAccess(iClient, bool:bNotify = false)
{
	g_iClientInfo[iClient] &= ~IS_LOADED;

	ResetClient(iClient);

	if(IsFakeClient(iClient) == false && (GLOBAL_INFO & IS_STARTED) && g_hDatabase)
	{
		Clients_LoadClient(iClient, bool:bNotify);
	//	DebugMessage("Clients_CheckVipAccess %N:\tИгрок %sявляется VIP игроком", iClient, g_bIsClientVIP[iClient] ? "":"не ")
	}
	else
	{
		g_iClientInfo[iClient] |= IS_LOADED;
		CreateForward_OnClientLoaded(iClient);
	}
}

Clients_LoadClient(iClient, bool:bNotify)
{
	decl String:sQuery[512], String:sAuth[32], String:sName[MAX_NAME_LENGTH*2+1], String:sIP[24];

	GetClientAuthId(iClient, AuthId_Engine, sAuth, sizeof(sAuth));

	GetClientIP(iClient, sIP, sizeof(sIP));
	GetClientName(iClient, sQuery, sizeof(sQuery));
	
	DebugMessage("Clients_LoadClient %N (%i), %b: - > %x, %u", iClient, iClient, g_iClientInfo[iClient], g_hDatabase, g_hDatabase)
	SQL_EscapeString(g_hDatabase, sQuery, sName, sizeof(sName));

	if (GLOBAL_INFO & IS_MySQL)
	{
		FormatEx(sQuery, sizeof(sQuery), "SELECT `u`.`id`, \
												`u`.`auth_type`, \
												`o`.`expires`, \
												`o`.`group` \
												FROM `vip_users` AS `u` \
												LEFT JOIN `vip_overrides` AS `o` \
												ON `o`.`user_id` = `u`.`id` \
												WHERE `o`.`server_id` = '%i' \
												AND ((`u`.`auth` = '%s' AND `u`.`auth_type` = '0') \
												OR (`u`.`auth` = '%s' AND `u`.`auth_type` = '1') \
												OR (`u`.`auth` = '%s' AND `u`.`auth_type` = '2')) LIMIT 1;",
												g_CVAR_iServerID, sAuth, sIP, sName);
	}
	else
	{
		FormatEx(sQuery, sizeof(sQuery), "SELECT `id`, `auth_type`, `expires`, `group` \
											FROM `vip_users` \
											WHERE (`auth` = '%s' AND `auth_type` = '0') \
											OR (`auth` = '%s' AND `auth_type` = '1') \
											OR (`auth` = '%s' AND `auth_type` = '2') LIMIT 1;",
											sAuth, sIP, sName);
	}

	DataPack hDataPack = new DataPack();
	hDataPack.WriteCell(UID(iClient));
	hDataPack.WriteCell(bNotify);
	hDataPack.WriteString(sAuth);
	
	DebugMessage(sQuery)
	SQL_TQuery(g_hDatabase, SQL_Callback_OnClientAuthorized, sQuery, hDataPack);
}

public SQL_Callback_OnClientAuthorized(Handle:hOwner, Handle:hQuery, const String:sError[], any:hPack)
{
	DataPack hDataPack = view_as<DataPack>(hPack);
	if (hQuery == null || sError[0])
	{
		LogError("SQL_Callback_OnClientAuthorized: %s", sError);
		delete hDataPack;
		return;
	}
	
	hDataPack.Reset();

	int iClient = CID(hDataPack.ReadCell());
	DebugMessage("SQL_Callback_OnClientAuthorized: %i", iClient)
	if (iClient)
	{
		if(SQL_FetchRow(hQuery))
		{
			int iExpires = SQL_FetchInt(hQuery, 2),
			iClientID = SQL_FetchInt(hQuery, 0);
			DebugMessage("Clients_LoadClient %N (%i):\texpires: %i", iClient, iClient, iExpires)
			if(iExpires > 0)
			{
				int iTime = GetTime();
				DebugMessage("Clients_LoadClient %N (%i):\tTime: %i", iClient, iClient, iTime)
				
				if(iTime > iExpires)
				{
					delete hDataPack;
					DebugMessage("Clients_LoadClient %N (%i):\tTime: %i", iClient, iClient, iTime)
					
					if(g_CVAR_iDeleteExpired == 0 || iTime >= ((g_CVAR_iDeleteExpired*86400)+iExpires))
					{
						if(g_CVAR_bLogsEnable)
						{
							LogToFile(g_sLogFile, "%T", "REMOVING_PLAYER", LANG_SERVER, iClient);
						}
						
						DebugMessage("Clients_LoadClient %N (%i):\tDelete", iClient, iClient)
						
						DB_RemoveClientFromID(0, iClientID, false);
					}

					CreateForward_OnVIPClientRemoved(iClient, "Expired");
					
					DisplayClientInfo(iClient, "expired_info");
					
					g_iClientInfo[iClient] |= IS_LOADED;
					CreateForward_OnClientLoaded(iClient);
					return;
				}
				
				Clients_CreateExpiredTimer(iClient, iExpires, iTime);
			}

			char sGroup[64];
			SQL_FetchString(hQuery, 3, sGroup, sizeof(sGroup));
			DebugMessage("Clients_LoadClient %N (%i):\tvip_group: %s", iClient, iClient, sGroup)
			if(sGroup[0] && UTIL_CheckValidVIPGroup(sGroup))
			{
				VIP_AuthType AuthType = view_as<VIP_AuthType>(SQL_FetchInt(hQuery, 1));
				Clients_CreateClientVIPSettings(iClient, iExpires, AuthType);

				SetTrieValue(g_hFeatures[iClient], KEY_CID, SQL_FetchInt(hQuery, 0));

				SetTrieString(g_hFeatures[iClient], KEY_GROUP, sGroup);
				DebugMessage("AreClientCookiesCached %b", AreClientCookiesCached(iClient))
				if(AreClientCookiesCached(iClient))
				{
					Clients_LoadVIPFeatures(iClient);
				}
				else
				{
					CreateTimer(1.0, Timer_CheckCookies, UID(iClient), TIMER_FLAG_NO_MAPCHANGE);
				}
				
				g_iClientInfo[iClient] |= IS_VIP;
				g_iClientInfo[iClient] |= IS_LOADED;

				CreateForward_OnClientLoaded(iClient);
				Clients_OnVIPClientLoaded(iClient);

				if(g_CVAR_bUpdateName && AuthType != AUTH_NAME)
				{
					DB_UpdateClientName(iClient);
				}

				if(hDataPack.ReadCell())
				{
					if(g_CVAR_bAutoOpenMenu)
					{
						DisplayMenu(g_hVIPMenu, iClient, MENU_TIME_FOREVER);
					}

					DisplayClientInfo(iClient, iExpires == 0 ? "connect_info_perm":"connect_info_time");
				}
			}
			else
			{
				hDataPack.ReadCell();
				char sAuth[32];
				hDataPack.ReadString(sAuth, sizeof(sAuth));
				LogError("Invalid VIP-Group/Некорректная VIP-группа: %s (Игрок: %s)", sGroup, sAuth);
			}
		}
		else
		{
			CreateForward_OnClientLoaded(iClient);
		}
	}

	delete hDataPack;
}

public Action:Timer_CheckCookies(Handle:hTimer, any:UserID)
{
	new iClient = CID(UserID);
	DebugMessage("Timer_CheckCookies -> UserID: %i, iClient: %i, IsClientVIP: %b,", UserID, iClient, g_bIsClientVIP[iClient])
	if(iClient && g_iClientInfo[iClient] & IS_VIP)
	{
		DebugMessage("AreClientCookiesCached %b", AreClientCookiesCached(iClient))
		if(AreClientCookiesCached(iClient))
		{
			Clients_LoadVIPFeatures(iClient);
			
			return Plugin_Stop;
		}
		
		CreateTimer(1.0, Timer_CheckCookies, UserID, TIMER_FLAG_NO_MAPCHANGE);
	}
	
	return Plugin_Stop;
}

Clients_OnVIPClientLoaded(iClient)
{
	CreateForward_OnVIPClientLoaded(iClient);

	Features_TurnOnAll(iClient);
}

Clients_CreateClientVIPSettings(iClient, iExp, VIP_AuthType:AuthType = AUTH_STEAM)
{
	g_hFeatures[iClient] = new StringMap();
	g_hFeatureStatus[iClient] = new StringMap();

	SetTrieValue(g_hFeatures[iClient], KEY_EXPIRES, iExp);
	SetTrieValue(g_hFeatures[iClient], KEY_AUTHTYPE, AuthType);
}

#if DEBUG_MODE 1

public OnClientCookiesCached(iClient)
{
	DebugMessage("OnClientCookiesCached %i %N", iClient, iClient)
	
	DebugMessage("AreClientCookiesCached %b", AreClientCookiesCached(iClient))
}
#endif

Clients_LoadVIPFeatures(iClient)
{
	DebugMessage("LoadVIPFeatures %N", iClient)
	
	DebugMessage("AreClientCookiesCached %b", AreClientCookiesCached(iClient))

	new iFeatures = GetArraySize(g_hFeaturesArray);
	DebugMessage("FeaturesArraySize: %i", iFeatures)
	if(iFeatures > 0)
	{
		char sFeatureName[FEATURE_NAME_LENGTH];

		GetTrieString(g_hFeatures[iClient], KEY_GROUP, sFeatureName, sizeof(sFeatureName));
		if(UTIL_CheckValidVIPGroup(sFeatureName))
		{
			decl String:sBuffer[64],
			Handle:hCookie,
			VIP_ToggleState:Status,
			i;
					
			ArrayList hArray;
			for(i=0; i < iFeatures; ++i)
			{
				GetArrayString(g_hFeaturesArray, i, sFeatureName, sizeof(sFeatureName));
				if(GetTrieValue(GLOBAL_TRIE, sFeatureName, hArray))
				{
					DebugMessage("LoadClientFeature: %i - %s", i, sFeatureName)

					if(GetValue(iClient, VIP_ValueType:hArray.Get(FEATURES_VALUE_TYPE), sFeatureName))
					{
						DebugMessage("GetValue: == true")
						if(VIP_FeatureType:hArray.Get(FEATURES_ITEM_TYPE) == TOGGLABLE)
						{
							hCookie = Handle:hArray.Get(FEATURES_COOKIE);

							GetClientCookie(iClient, hCookie, sBuffer, sizeof(sBuffer));
							DebugMessage("GetFeatureCookie: %s", sBuffer)
							if(sBuffer[0] == '\0' ||
							(StringToIntEx(sBuffer, _:Status) &&
							(_:Status > 2 || _:Status < 0)))
							{
								Status = ENABLED;
								IntToString(_:Status, sBuffer, sizeof(sBuffer));
								SetClientCookie(iClient, hCookie, sBuffer);
							//	Features_SaveStatus(iClient, sFeatureName, hCookie, Status);
							}
						}
						else
						{
							Status = ENABLED;
						}

						Features_SetStatus(iClient, sFeatureName, Status);
					//	Function_OnItemToggle(view_as<Handle>(hArray.Get(FEATURES_PLUGIN)), Function:hArray.Get(FEATURES_ITEM_SELECT), iClient, sFeatureName, NO_ACCESS, ENABLED);
					}
				}
			}
		}
	}
}

bool:GetValue(iClient, VIP_ValueType:ValueType, const String:sFeatureName[])
{
	DebugMessage("GetValue: %i - %s", ValueType, sFeatureName)
	switch(ValueType)
	{
		case VIP_NULL:
		{
			return false;
		}
		case BOOL:
		{
			if(bool:KvGetNum(g_hGroups, sFeatureName))
			{
				DebugMessage("value: 1")
				return SetTrieValue(g_hFeatures[iClient], sFeatureName, true);
			}
			return false;
		}
		case INT:
		{
			decl iValue;
			iValue = KvGetNum(g_hGroups, sFeatureName);
			if(iValue != 0)
			{
				DebugMessage("value: %i", iValue)
				return SetTrieValue(g_hFeatures[iClient], sFeatureName, iValue);
			}
			return false;
		}
		case FLOAT:
		{
			decl Float:fValue;
			fValue = KvGetFloat(g_hGroups, sFeatureName);
			if(fValue != 0.0)
			{
				DebugMessage("value: %f", fValue)
				return SetTrieValue(g_hFeatures[iClient], sFeatureName, fValue);
			}
			
			return false;
		}
		case STRING:
		{
			decl String:sBuffer[256];
			KvGetString(g_hGroups, sFeatureName, sBuffer, sizeof(sBuffer));
			if(sBuffer[0])
			{
				DebugMessage("value: %s", sBuffer)
				return SetTrieString(g_hFeatures[iClient], sFeatureName, sBuffer);
			}
			return false;
		}
		default:
		{
			return false;
		}
	}

	return false;
}

Clients_CreateExpiredTimer(iClient, iExp, iTime)
{
	decl iTimeLeft;
	GetMapTimeLeft(iTimeLeft);
	DebugMessage("Clients_CreateExpiredTimer %N (%i):\tiTimeLeft: %i", iClient, iClient, iTimeLeft)
	if(iTimeLeft > 0)
	{
		DebugMessage("Clients_CreateExpiredTimer %N (%i):\tiTimeLeft+iTime: %i", iClient, iClient, iTimeLeft+iTime)
		if((iTimeLeft+iTime) > iExp)
		{
			DebugMessage("Clients_CreateExpiredTimer %N (%i):\tTimerDealy: %f", iClient, iClient, float((iExp - iTime)+3))
			
			CreateTimer(float((iExp - iTime)+3), Timer_VIP_Expired, UID(iClient), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
}

public Event_MatchEndRestart(Handle:hEvent, const String:name[], bool:dontBroadcast)
{
	if(g_CVAR_iDeleteExpired != -1)
	{
		RemoveExpiredPlayers();
	}
}

public Event_PlayerSpawn(Handle:hEvent, const String:sEvName[], bool:bDontBroadcast)
{
	new UserID = GetEventInt(hEvent, "userid");
	new iClient = CID(UserID);
	DebugMessage("Event_PlayerSpawn: %N (%i)", iClient, iClient)
	if(!(g_iClientInfo[iClient] & IS_SPAWNED))
	{
		CreateTimer(g_CVAR_fSpawnDelay, Timer_OnPlayerSpawn, UserID, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Event_PlayerDeath(Handle:hEvent, const String:sEvName[], bool:bDontBroadcast)
{
	new iClient = CID(GetEventInt(hEvent, "userid"));
	DebugMessage("Event_PlayerDeath: %N (%i)", iClient, iClient)
	g_iClientInfo[iClient] &= ~IS_SPAWNED;
}

public Action:Timer_OnPlayerSpawn(Handle:hTimer, any:UserID)
{
	new iClient = CID(UserID);
	if(iClient && IsClientInGame(iClient))
	{
		new iTeam = GetClientTeam(iClient);
		if(iTeam > 1 && IsPlayerAlive(iClient))
		{
			DebugMessage("Timer_OnPlayerSpawn: %N (%i)", iClient, iClient)

			if(g_iClientInfo[iClient] & IS_VIP)
			{
				decl iExp;
				if(GetTrieValue(g_hFeatures[iClient], KEY_EXPIRES, iExp) && iExp > 0 && iExp < GetTime())
				{
					Clients_ExpiredClient(iClient);
				}
			}

			g_iClientInfo[iClient] |= IS_SPAWNED;
			CreateForward_OnPlayerSpawn(iClient, iTeam);
		}
	}
	return Plugin_Stop;
}

public Event_RoundEnd(Handle:hEvent, const String:name[], bool:dontBroadcast)
{
	DebugMessage("Event_RoundEnd")
	decl iTime, iExp, i;
	iTime = GetTime();
	for(i = 1; i <= MaxClients; ++i)
	{
		if(IsClientInGame(i))
		{
			g_iClientInfo[i] &= ~IS_SPAWNED;
			if((g_iClientInfo[i] & IS_VIP) && GetTrieValue(g_hFeatures[i], KEY_EXPIRES, iExp) && iExp > 0 && iExp < iTime)
			{
				Clients_ExpiredClient(i);
			}
		}
	}
}

public Action:Timer_VIP_Expired(Handle:hTimer, any:UserID)
{
	DebugMessage("Timer_VIP_Expired %i:", UserID)
	
	new iClient = CID(UserID);
	if(iClient && g_iClientInfo[iClient] & IS_VIP)
	{
		decl iExp;
		if(GetTrieValue(g_hFeatures[iClient], KEY_EXPIRES, iExp) && iExp > 0 && iExp < GetTime())
		{
			DebugMessage("Timer_VIP_Expired %N:", iClient)
			
			Clients_ExpiredClient(iClient);
		}
	}
}

Clients_ExpiredClient(iClient)
{
	DebugMessage("Clients_ExpiredClient %N:", iClient)
	Features_TurnOffAll(iClient);
	
	decl iClientID;
	GetTrieValue(g_hFeatures[iClient], KEY_EXPIRES, iClientID);
	if(g_CVAR_iDeleteExpired == 0 || GetTime() >= ((g_CVAR_iDeleteExpired*86400)+iClientID))
	{
		if(GetTrieValue(g_hFeatures[iClient], "IsTempVIP", iClientID) == false)
		{
			if(GetTrieValue(g_hFeatures[iClient], KEY_CID, iClientID))
			{
				if(g_CVAR_bLogsEnable)
				{
					LogToFile(g_sLogFile, "%T", "REMOVING_PLAYER", LANG_SERVER, iClient);
				}
				
				DB_RemoveClientFromID(0, iClientID, false);
			}
		}
	}

	ResetClient(iClient);

	CreateForward_OnVIPClientRemoved(iClient, "Expired");

	DisplayClientInfo(iClient, "expired_info");
}