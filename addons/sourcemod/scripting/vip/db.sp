DB_OnPluginStart()
{
	DB_Connect();
}

DB_Connect()
{
//	DebugMessage("DB_Connect: %b", g_bIsVIPLoaded)
	DebugMessage("DB_Connect")
	
	if (GLOBAL_INFO & IS_LOADING)
	{
		return;
	}

	if (g_hDatabase != null)
	{
		UNSET_BIT(GLOBAL_INFO, IS_LOADING);
		return;
	}
	
	SET_BIT(GLOBAL_INFO, IS_LOADING);

	if (SQL_CheckConfig("vip"))
	{
		Database.Connect(OnDBConnect, "vip", 1);
	}
	else
	{
		char sError[256];
		sError[0] = '\0';
		g_hDatabase = SQLite_UseDatabase("vip", sError, sizeof(sError));
		OnDBConnect(g_hDatabase, sError, 0);
	}
}

public void OnDBConnect(Database hDatabase, const char[] sError, any data)
{
	if (hDatabase == null || sError[0])
	{
		SetFailState("OnDBConnect %s", sError);
		UNSET_BIT(GLOBAL_INFO, IS_MySQL);
	//	CreateTimer(5.0, Timer_DB_Reconnect);
		return;
	}

	g_hDatabase = hDatabase;

	char sDriver[8];
	g_hDatabase.Driver.GetIdentifier(SZF(sDriver));

	if(strcmp(sDriver, "mysql", false) == 0)
	{
		SET_BIT(GLOBAL_INFO, IS_MySQL);
		
		g_hDatabase.SetCharset("utf8");

		SQL_FastQuery(g_hDatabase, "SET NAMES \"UTF8\"");
		SQL_FastQuery(g_hDatabase, "SET NAMES 'utf8'");
		SQL_FastQuery(g_hDatabase, "SET CHARSET 'utf8'");
	}
	else
	{
		UNSET_BIT(GLOBAL_INFO, IS_MySQL);
	}

	DebugMessage("OnDBConnect %x, %u - > (MySQL: %b)", g_hDatabase, g_hDatabase, GLOBAL_INFO & IS_MySQL)

	CreateTables();
}
/*
public Action:Timer_DB_Reconnect(Handle:timer)
{
	if (g_hDatabase == null)
	{
		DB_Connect();
	}
	return Plugin_Stop;
}
*/
CreateTables()
{
	DebugMessage("CreateTables")
	SQL_LockDatabase(g_hDatabase);
	if (GLOBAL_INFO & IS_MySQL)
	{
		SQL_FastQuery(g_hDatabase, "SET NAMES \"UTF8\"");
		SQL_FastQuery(g_hDatabase, "SET CHARSET \"UTF8\"");
		SQL_TQuery(g_hDatabase, SQL_Callback_ErrorCheck,	"CREATE TABLE IF NOT EXISTS `vip_users` (\
																		`id` INT(10) UNSIGNED NOT NULL AUTO_INCREMENT, \
																		`auth` VARCHAR(64) UNIQUE NOT NULL, \
																		`name` VARCHAR(64) NOT NULL default 'unknown', \
																		`auth_type` TINYINT(2) UNSIGNED NOT NULL default '0', \
																		PRIMARY KEY (`id`), \
																		UNIQUE KEY `auth_id` (`auth`)) DEFAULT CHARSET=utf8 AUTO_INCREMENT=1;");

		SQL_TQuery(g_hDatabase, SQL_Callback_ErrorCheck,	"CREATE TABLE IF NOT EXISTS `vip_overrides` (\
																		`user_id` INT(10) UNSIGNED NOT NULL, \
																		`server_id` INT(10) UNSIGNED NOT NULL, \
																		`group` VARCHAR(64) default NULL, \
																		`expires` INT(10) UNSIGNED NOT NULL default '0', \
																		PRIMARY KEY (`user_id`, `server_id`), \
																		UNIQUE KEY `user_id` (`user_id`, `server_id`), \
																		CONSTRAINT `vip_overrides_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `vip_users` (`id`)  ON DELETE CASCADE ON UPDATE CASCADE\
																		) DEFAULT CHARSET=utf8;");
	}
	else
	{
		SQL_TQuery(g_hDatabase, SQL_Callback_ErrorCheck,	"CREATE TABLE IF NOT EXISTS `vip_users` (\
																		`id` INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, \
																		`auth` VARCHAR(32) UNIQUE NOT NULL, \
																		`name` VARCHAR(64) NOT NULL default 'unknown', \
																		`auth_type` INTEGER NOT NULL default '0', \
																		`group` VARCHAR(64) default NULL, \
																		`expires` INTEGER NOT NULL default '0');");
	}

	SQL_UnlockDatabase(g_hDatabase);
	
	UNSET_BIT(GLOBAL_INFO, IS_LOADING);

	OnReadyToStart();

	UTIL_ReloadVIPPlayers(0, false);
	
	if(g_CVAR_iDeleteExpired != -1)
	{
		RemoveExpiredPlayers();
	}
}

public SQL_Callback_ErrorCheck(Handle:hOwner, Handle:hQuery, const String:sError[], any:data)
{
	if (sError[0])
	{
		LogError("SQL_Callback_ErrorCheck: %s", sError);
	}
}

DB_UpdateClientName(iClient)
{
	SQL_FastQuery(g_hDatabase, "SET NAMES 'utf8'");

	decl Handle:hStmt, String:sError[256];

	hStmt = SQL_PrepareQuery(g_hDatabase, "UPDATE `vip_users` SET `name` = ? WHERE `id` = ?;", SZF(sError));
	if (hStmt != null)
	{
		decl String:sName[MAX_NAME_LENGTH], iClientID;
		GetTrieValue(g_hFeatures[iClient], KEY_CID, iClientID);
		GetClientName(iClient, SZF(sName));

		SQL_BindParamString(hStmt, 0, sName, false);	
		SQL_BindParamInt(hStmt, 1, iClientID, false);

		if (!SQL_Execute(hStmt))
		{
			SQL_GetError(hStmt, SZF(sError));
			LogError("[VIP Core] Fail SQL_Execute: %s", sError);
		}

		CloseHandle(hStmt);
	}
	else
	{
		LogError("[VIP Core] Fail SQL_PrepareQuery: %s", sError);
	}
}

DB_RemoveClientFromID(iClient = 0, iClientID, bool:bNotify)
{
	DebugMessage("DB_RemoveClientFromID %N (%i): - > iClientID: %i, : bNotify: %b", iClient, iClient, iClientID, bNotify)
	decl String:sQuery[256], Handle:hDataPack;
	hDataPack = CreateDataPack();
	WritePackCell(hDataPack, iClientID);
	WritePackCell(hDataPack, bNotify);
	if(iClient)
	{
		WritePackCell(hDataPack, UID(iClient));
	}
	else
	{
		WritePackCell(hDataPack, 0);
	}
	
	if (GLOBAL_INFO & IS_MySQL)
	{
		FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `vip_overrides` WHERE `user_id` = '%i' AND `server_id` = '%i';", iClientID, g_CVAR_iServerID);
	}
	else
	{
		FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `vip_users` WHERE `id` = '%i';", iClientID);
	}

	DebugMessage(sQuery)
	SQL_TQuery(g_hDatabase, SQL_Callback_RemoveClient, sQuery, hDataPack);
}

public SQL_Callback_RemoveClient(Handle:hOwner, Handle:hQuery, const String:sError[], any:hDataPack)
{
	if (sError[0])
	{
		LogError("SQL_Callback_RemoveClient: %s", sError);
		return;
	}
	
	if(SQL_GetAffectedRows(hOwner))
	{
		ResetPack(hDataPack);

		new iClientID = ReadPackCell(hDataPack);

		if(g_CVAR_bLogsEnable)
		{
			LogToFile(g_sLogFile, "%T", "ADMIN_VIP_PLAYER_DELETED", LANG_SERVER, iClientID);
		//	LogToFile(g_sLogFile, "%T", "ADMIN_VIP_PLAYER_DELETED", LANG_SERVER, iClient, iClientID);
		}

		if (GLOBAL_INFO & IS_MySQL)
		{
			decl String:sQuery[256];
			FormatEx(sQuery, sizeof(sQuery), "SELECT COUNT(*) AS vip_count FROM `vip_overrides` WHERE `user_id` = '%i';", iClientID);
			SQL_TQuery(g_hDatabase, SQL_Callback_RemoveClient2, sQuery, iClientID);
		}

		if(bool:ReadPackCell(hDataPack))
		{
			new iClient = ReadPackCell(hDataPack);
			
			if(iClient)
			{
				iClient = CID(iClient);
				if(iClient == 0)
				{
					return;
				}
			}

			ReplyToCommand(iClient, "%t", "ADMIN_VIP_PLAYER_DELETED", iClientID);
		}
	}
}

public SQL_Callback_RemoveClient2(Handle:hOwner, Handle:hQuery, const String:sError[], any:iClientID)
{
	if (sError[0])
	{
		LogError("SQL_Callback_RemoveClient: %s", sError);
		return;
	}
	
	if (SQL_FetchRow(hQuery) && SQL_FetchInt(hQuery, 0) == 0)
	{
		decl String:sQuery[256];
		FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `vip_users` WHERE `id` = '%i';", iClientID);

		SQL_TQuery(g_hDatabase, SQL_Callback_ErrorCheck, sQuery, iClientID);
	}
}
/*
public SQL_Callback_DeleteExpired(Handle:hOwner, Handle:hQuery, const String:sError[], any:iClientID)
{
	if (sError[0])
	{
		LogError("SQL_Callback_DeleteExpired: %s", sError);
		return;
	}

	if(SQL_GetAffectedRows(hOwner))
	{
		if(g_CVAR_iDeleteExpired != -1)
		{
			decl String:sQuery[256];
			FormatEx(sQuery, sizeof(sQuery), "SELECT COUNT(*) AS vip_count FROM `vip_overrides` WHERE `user_id` = '%i';", iClientID);
			SQL_TQuery(g_hDatabase, SQL_Callback_RemoveClient2, sQuery, iClientID);

			if(g_CVAR_bLogsEnable)
			{
				LogToFile(g_sLogFile, "%T", "ADMIN_VIP_PLAYER_DELETED", LANG_SERVER, iClientID);
			//	LogToFile(g_sLogFile, "%T", "ADMIN_VIP_PLAYER_DELETED", LANG_SERVER, iClient, iClientID);
			}
		}
	}
}
*/

RemoveExpiredPlayers()
{
	decl String:sQuery[512];

	if (GLOBAL_INFO & IS_MySQL)
	{
		FormatEx(sQuery, sizeof(sQuery), "SELECT `user_id`, \
												`expires` \
												FROM `vip_overrides` \
												WHERE `server_id` = '%i';",
												g_CVAR_iServerID);
	}
	else
	{
		FormatEx(sQuery, sizeof(sQuery), "SELECT `id`, `expires`, `group` FROM `vip_users`;");
	}

	DebugMessage(sQuery)
	SQL_TQuery(g_hDatabase, SQL_Callback_RemoveExpiredPlayers, sQuery);
}

public SQL_Callback_RemoveExpiredPlayers(Handle:hOwner, Handle:hQuery, const String:sError[], any:iData)
{
	if (sError[0])
	{
		LogError("SQL_Callback_RemoveExpiredPlayers: %s", sError);
		return;
	}

	DebugMessage("SQL_Callback_RemoveExpiredPlayers: %i", SQL_GetRowCount(hQuery))
	if(SQL_GetRowCount(hQuery))
	{
		decl iExpires, iTime, iClientID;
		iTime = GetTime();
		while(SQL_FetchRow(hQuery))
		{
			iExpires = SQL_FetchInt(hQuery, 1);
			if(iExpires && iTime > iExpires)
			{
				if(g_CVAR_iDeleteExpired == 0 || iTime >= ((g_CVAR_iDeleteExpired*86400)+iExpires))
				{
					iClientID = SQL_FetchInt(hQuery, 0);
					DebugMessage("RemoveExpiredPlayers iClientID: %i", iClientID)
					
					DB_RemoveClientFromID(0, iClientID, false);
				}
			}
		}
	}
}