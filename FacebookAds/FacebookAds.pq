﻿// This file contains your Data Connector logic
section FacebookAds;

client_id       = Json.Document ( Extension.Contents( "WebApp.json") ) [web][client_id];
client_secret   = Json.Document ( Extension.Contents( "WebApp.json") ) [web][client_secret];
token_uri       = Json.Document ( Extension.Contents( "WebApp.json") ) [web][token_uri];
authorize_uri   = Json.Document ( Extension.Contents( "WebApp.json") ) [web][authorize_uri];

redirectUrl = "https://preview.powerbi.com/views/oauthredirect.html";

baseUrl = "https://graph.facebook.com/v2.12/";
windowWidth = 1080;
windowHeight = 1024;

scope_prefix = "";
scopes = {
	"ads_read"
};

FacebookAds = [
    Authentication = [
        OAuth = [
            StartLogin = StartLogin,
            FinishLogin = FinishLogin
        ]
    ],
    Label =  Extension.LoadString ("DataSourceLabel")
];

// Data Source Kind description
StartLogin = (resourceUrl, state, display) =>
    let
        AuthorizeUrl = authorize_uri & "?" & Uri.BuildQueryString([
        client_id = client_id,
        redirect_uri = redirectUrl,
        state = state,
        scope = GetScopeString(scopes, scope_prefix),
        response_type = "code"
    ])
    in
        [
            LoginUri = AuthorizeUrl,
            CallbackUri = redirectUrl,
            WindowHeight = 720,
            WindowWidth = 1024,
            Context = null
        ];

FinishLogin = (context, callbackUri, state) =>
    let
        parts = Uri.Parts(callbackUri)[Query],
        result = if (Record.HasFields(parts, {"error", "error_description"})) then 
                    error Error.Record(parts[error], parts[error_description], parts)
                 else
                   TokenMethod("authorization_code", parts[code])
    in
        result;

Refresh = (resourceUrl, refresh_token) => TokenMethod("refresh_token", refresh_token);

TokenMethod = (grantType, code) =>
    let
        query = [
            grant_type = grantType,
            client_id = client_id,
            client_secret = client_secret,
            redirect_uri = redirectUrl
        ],

        // {CODE From Matt} added for Google API - field is "code" on initial auth, and "refresh_token" for refresh
        queryWithCode = if (grantType = "refresh_token") then [ refresh_token = code ] else [code = code],

        response = Web.Contents(token_uri, [
            Content = Text.ToBinary(Uri.BuildQueryString(query & queryWithCode)),
            Headers=[#"Content-type" = "application/x-www-form-urlencoded",#"Accept" = "application/json"], ManualStatusHandling = {400}]),
        body = Json.Document(response),
        result = if  (Record.HasFields(body, {"error", "error_description"})) then  
                    error Error.Record(body[error], body[error_description], body)
                 else
                    body
    in
        result;

// Data Source UI publishing description
FacebookAds.Publish = [
    Beta = false,
    Category = "Other",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://powerbi.microsoft.com/",
    SourceImage = FacebookAds.Icons,
    SourceTypeImage = FacebookAds.Icons
];

FacebookAds.Icons = [
    Icon16 = { Extension.Contents("FacebookAds16.png"), Extension.Contents("FacebookAds20.png"), Extension.Contents("FacebookAds24.png"), Extension.Contents("FacebookAds32.png") },
    Icon32 = { Extension.Contents("FacebookAds32.png"), Extension.Contents("FacebookAds40.png"), Extension.Contents("FacebookAds48.png"), Extension.Contents("FacebookAds64.png") }
];


// Navigation entry point
[DataSource.Kind="FacebookAds", Publish="FacebookAds.Publish"]
shared FacebookAds.Ads = (optional url as text, optional params as record) =>
    let
        key = Extension.CurrentCredential()[access_token],
        accountRequest = Web.Contents(baseUrl & "me/adaccounts?" & Uri.BuildQueryString([access_token=key,fields="id,name"])),
        adAccounts = Json.Document(accountRequest)[data],
        table = FacebookAds.AdAccountsToNavigationTable(adAccounts)
    in
        table;

shared FacebookAds.AdAccountsToNavigationTable = (adAccounts as list) =>
    let
        navHeader = {"Name","Key","Data","ItemKind", "ItemName", "IsLeaf"}, 
        navAdAccounts = List.Accumulate(adAccounts, {}, (state, current) => state & {{current[name], current[name], FacebookAds.GetInsights(current), "Table", "Table", false}} ),
        objects = #table(navHeader, navAdAccounts),
        table = Table.ToNavigationTable(objects, {"Key"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        table;

shared FacebookAds.GetInsights = (adAccount as record) =>
    let
        objects = #table(
            {"Name", "Key", "Data", "ItemKind", "ItemName", "IsLeaf"},{
            {"Facebook All Ad Insights", "Facebook All Ad Insights", FacebookAds.GetAllAds(adAccount), "Table", "Table", true},
            {"Facebook All Ad Insights Last 30 days", "Facebook All Ad Insights Last 30 days", FacebookAds.GetAllAds30Days(adAccount), "Table", "Table", true},
            {"Facebook All Ad Insights Last 90 days", "Facebook All Ad Insights Last 90 days", FacebookAds.GetAllAds90Days(adAccount), "Table", "Table", true},
            {"Facebook Active Ad Insights", "Facebook Active Ad Insights", FacebookAds.GetAllActiveAds(adAccount), "Table", "Table", true},
            {"Facebook Ad Actions", "Facebook Ad Actions", FacebookAds.GetAdActions(adAccount), "Table", "Table", true},
            {"Facebook Ad Action Values", "Facebook Ad Action Values", FacebookAds.GetAdActionValues(adAccount), "Table", "Table", true}
        }),
        NavTable = Table.ToNavigationTable(objects, {"Key"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        NavTable;

shared FacebookAds.GetAllAds = (adAccount as record) =>
    let
        access_token = Extension.CurrentCredential()[access_token],
//        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="lifetime", filtering="[{""field"":""spend"",""operator"":""GREATER_THAN"",""value"":""0""}]", limit="25"]),
        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="lifetime", limit="100"]),

        joined_response = List.Accumulate(
            {1}, 
            {},
            (state, adId) => List.Combine(
                { 
                  state, 
                  FacebookAds.GetData(seed, {})
                }
            )
        ),

        response = () =>
            let 
                response = Table.FromList(joined_response, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
                tableOfAdIds = Table.ExpandRecordColumn(response, "Column1", {"id"}, {"id"}),
                adIds = tableOfAdIds[id],

                list = List.Accumulate(
                    adIds, 
                    {},
                    (state, adId) => List.Combine(
                        { 
                          state, 
                          FacebookAds.GetData(baseUrl & adId & "/insights?" & Uri.BuildQueryString([access_token=access_token,fields="ad_id,campaign_id,adset_id,ad_name,account_id,adset_name,campaign_name,total_actions,reach,impressions,frequency,unique_clicks,spend,unique_inline_link_clicks,unique_social_clicks,cpc,cpm,call_to_action_clicks,clicks,account_currency,account_name,social_impressions,social_clicks,social_reach,social_spend,objective,inline_link_clicks,inline_post_engagement", level="ad", date_preset="lifetime", time_increment="1", limit="90"]), {})
                        }
                    )
                ),

                table = Table.FromList(list, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
                expanded = Table.ExpandRecordColumn(table, "Column1", {"date_start", "ad_id", "campaign_id", "adset_id", "ad_name", "account_id", "adset_name", "campaign_name", "total_actions", "reach", "impressions", "frequency", "unique_clicks", "spend", "unique_inline_link_clicks", "unique_social_clicks", "cpc", "cpm", "call_to_action_clicks", "clicks", "account_currency", "account_name", "social_impressions", "social_clicks", "social_reach", "social_spend", "objective", "inline_link_clicks", "inline_post_engagement"}, {"date", "Ad ID", "Campaign ID", "Adset ID", "Ad Name", "Account ID", "Adset Name", "Campaign Name", "Total Actions", "Reach", "Impressions", "Frequency", "Unique Clicks", "Spend", "Unique Inline Link Clicks", "Unique Social Clicks", "CPC", "CPM", "Call To Action Clicks", "Clicks", "Account Currency", "Account Name", "Social Impressions", "Social Clicks", "Social Reach", "Social Spend", "Objective", "Inline Link Clicks", "Inline Post Engagement"}),
                tableWithFBKey = Table.AddColumn(expanded, "facebook_ad_key", each [date] & "_" & [Account ID] & "_" & [Campaign ID] & "_" & [Adset ID] & "_" & [Ad ID]),
                tableTyped = Table.TransformColumnTypes(tableWithFBKey, {{"Ad ID", type text}, {"Campaign ID", type text}, {"Adset ID", type text}, {"Ad Name", type text}, {"Account ID", type text}, {"Adset Name", type text}, {"Campaign Name", type text}, {"Account Name", type text}, {"Objective", type text}, {"date", type date}, {"Total Actions", Int64.Type}, {"Reach", Int64.Type}, {"Impressions", Int64.Type}, {"Unique Inline Link Clicks", Int64.Type}, {"Unique Social Clicks", Int64.Type}, {"Call To Action Clicks", Int64.Type}, {"Clicks", Int64.Type}, {"Social Impressions", Int64.Type}, {"Social Clicks", Int64.Type}, {"Social Reach", Int64.Type}, {"Inline Link Clicks", Int64.Type}, {"Inline Post Engagement", Int64.Type}, {"Frequency", type number}, {"Spend", type number}, {"CPC", type number}, {"CPM", type number}, {"Social Spend", type number}}),
                tableOrderedColumns = Table.ReorderColumns(tableTyped, {"facebook_ad_key", "date", "Ad ID", "Campaign ID", "Adset ID", "Ad Name", "Account ID", "Adset Name", "Campaign Name", "Total Actions", "Reach", "Impressions", "Frequency", "Unique Clicks", "Spend", "Unique Inline Link Clicks", "Unique Social Clicks", "CPC", "CPM", "Call To Action Clicks", "Clicks", "Account Currency", "Account Name", "Social Impressions", "Social Clicks", "Social Reach", "Social Spend", "Objective", "Inline Link Clicks", "Inline Post Engagement"})
            in tableOrderedColumns,

        r = if List.Count(joined_response) > 0 then 
            response()
        else 
            null
    in
     r;

shared FacebookAds.GetAllAds30Days = (adAccount as record) =>
    let
        access_token = Extension.CurrentCredential()[access_token],
//        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="last_30d", filtering="[{""field"":""spend"",""operator"":""GREATER_THAN"",""value"":""0""}]", limit="25"]),
        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="last_30d", limit="100"]),

        joined_response = List.Accumulate(
            {1}, 
            {},
            (state, adId) => List.Combine(
                { 
                  state, 
                  FacebookAds.GetData(seed, {})
                }
            )
        ),

        response = () =>
            let 
                response = Table.FromList(joined_response, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
                tableOfAdIds = Table.ExpandRecordColumn(response, "Column1", {"id"}, {"id"}),
                adIds = tableOfAdIds[id],

                list = List.Accumulate(
                    adIds, 
                    {},
                    (state, adId) => List.Combine(
                        { 
                          state, 
                          FacebookAds.GetData(baseUrl & adId & "/insights?" & Uri.BuildQueryString([access_token=access_token,fields="ad_id,campaign_id,adset_id,ad_name,account_id,adset_name,campaign_name,total_actions,reach,impressions,frequency,unique_clicks,spend,unique_inline_link_clicks,unique_social_clicks,cpc,cpm,call_to_action_clicks,clicks,account_currency,account_name,social_impressions,social_clicks,social_reach,social_spend,objective,inline_link_clicks,inline_post_engagement", level="ad", date_preset="lifetime", time_increment="1", limit="90"]), {})
                        }
                    )
                ),

                table = Table.FromList(list, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
                expanded = Table.ExpandRecordColumn(table, "Column1", {"date_start", "ad_id", "campaign_id", "adset_id", "ad_name", "account_id", "adset_name", "campaign_name", "total_actions", "reach", "impressions", "frequency", "unique_clicks", "spend", "unique_inline_link_clicks", "unique_social_clicks", "cpc", "cpm", "call_to_action_clicks", "clicks", "account_currency", "account_name", "social_impressions", "social_clicks", "social_reach", "social_spend", "objective", "inline_link_clicks", "inline_post_engagement"}, {"date", "Ad ID", "Campaign ID", "Adset ID", "Ad Name", "Account ID", "Adset Name", "Campaign Name", "Total Actions", "Reach", "Impressions", "Frequency", "Unique Clicks", "Spend", "Unique Inline Link Clicks", "Unique Social Clicks", "CPC", "CPM", "Call To Action Clicks", "Clicks", "Account Currency", "Account Name", "Social Impressions", "Social Clicks", "Social Reach", "Social Spend", "Objective", "Inline Link Clicks", "Inline Post Engagement"}),
                tableWithFBKey = Table.AddColumn(expanded, "facebook_ad_key", each [date] & "_" & [Account ID] & "_" & [Campaign ID] & "_" & [Adset ID] & "_" & [Ad ID]),
                tableTyped = Table.TransformColumnTypes(tableWithFBKey, {{"Ad ID", type text}, {"Campaign ID", type text}, {"Adset ID", type text}, {"Ad Name", type text}, {"Account ID", type text}, {"Adset Name", type text}, {"Campaign Name", type text}, {"Account Name", type text}, {"Objective", type text}, {"date", type date}, {"Total Actions", Int64.Type}, {"Reach", Int64.Type}, {"Impressions", Int64.Type}, {"Unique Inline Link Clicks", Int64.Type}, {"Unique Social Clicks", Int64.Type}, {"Call To Action Clicks", Int64.Type}, {"Clicks", Int64.Type}, {"Social Impressions", Int64.Type}, {"Social Clicks", Int64.Type}, {"Social Reach", Int64.Type}, {"Inline Link Clicks", Int64.Type}, {"Inline Post Engagement", Int64.Type}, {"Frequency", type number}, {"Spend", type number}, {"CPC", type number}, {"CPM", type number}, {"Social Spend", type number}}),
                tableOrderedColumns = Table.ReorderColumns(tableTyped, {"facebook_ad_key", "date", "Ad ID", "Campaign ID", "Adset ID", "Ad Name", "Account ID", "Adset Name", "Campaign Name", "Total Actions", "Reach", "Impressions", "Frequency", "Unique Clicks", "Spend", "Unique Inline Link Clicks", "Unique Social Clicks", "CPC", "CPM", "Call To Action Clicks", "Clicks", "Account Currency", "Account Name", "Social Impressions", "Social Clicks", "Social Reach", "Social Spend", "Objective", "Inline Link Clicks", "Inline Post Engagement"})
            in tableOrderedColumns,

        r = if List.Count(joined_response) > 0 then 
            response()
        else 
            null
    in
     r;

shared FacebookAds.GetAllAds90Days = (adAccount as record) =>
    let
        access_token = Extension.CurrentCredential()[access_token],
//        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="last_90d", filtering="[{""field"":""spend"",""operator"":""GREATER_THAN"",""value"":""0""}]", limit="25"]),
        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="last_90d", limit="100"]),

        joined_response = List.Accumulate(
            {1}, 
            {},
            (state, adId) => List.Combine(
                { 
                  state, 
                  FacebookAds.GetData(seed, {})
                }
            )
        ),

        response = () =>
            let 
                response = Table.FromList(joined_response, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
                tableOfAdIds = Table.ExpandRecordColumn(response, "Column1", {"id"}, {"id"}),
                adIds = tableOfAdIds[id],

                list = List.Accumulate(
                    adIds, 
                    {},
                    (state, adId) => List.Combine(
                        { 
                          state, 
                          FacebookAds.GetData(baseUrl & adId & "/insights?" & Uri.BuildQueryString([access_token=access_token,fields="ad_id,campaign_id,adset_id,ad_name,account_id,adset_name,campaign_name,total_actions,reach,impressions,frequency,unique_clicks,spend,unique_inline_link_clicks,unique_social_clicks,cpc,cpm,call_to_action_clicks,clicks,account_currency,account_name,social_impressions,social_clicks,social_reach,social_spend,objective,inline_link_clicks,inline_post_engagement", level="ad", date_preset="lifetime", time_increment="1", limit="90"]), {})
                        }
                    )
                ),

                table = Table.FromList(list, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
                expanded = Table.ExpandRecordColumn(table, "Column1", {"date_start", "ad_id", "campaign_id", "adset_id", "ad_name", "account_id", "adset_name", "campaign_name", "total_actions", "reach", "impressions", "frequency", "unique_clicks", "spend", "unique_inline_link_clicks", "unique_social_clicks", "cpc", "cpm", "call_to_action_clicks", "clicks", "account_currency", "account_name", "social_impressions", "social_clicks", "social_reach", "social_spend", "objective", "inline_link_clicks", "inline_post_engagement"}, {"date", "Ad ID", "Campaign ID", "Adset ID", "Ad Name", "Account ID", "Adset Name", "Campaign Name", "Total Actions", "Reach", "Impressions", "Frequency", "Unique Clicks", "Spend", "Unique Inline Link Clicks", "Unique Social Clicks", "CPC", "CPM", "Call To Action Clicks", "Clicks", "Account Currency", "Account Name", "Social Impressions", "Social Clicks", "Social Reach", "Social Spend", "Objective", "Inline Link Clicks", "Inline Post Engagement"}),
                tableWithFBKey = Table.AddColumn(expanded, "facebook_ad_key", each [date] & "_" & [Account ID] & "_" & [Campaign ID] & "_" & [Adset ID] & "_" & [Ad ID]),
                tableTyped = Table.TransformColumnTypes(tableWithFBKey, {{"Ad ID", type text}, {"Campaign ID", type text}, {"Adset ID", type text}, {"Ad Name", type text}, {"Account ID", type text}, {"Adset Name", type text}, {"Campaign Name", type text}, {"Account Name", type text}, {"Objective", type text}, {"date", type date}, {"Total Actions", Int64.Type}, {"Reach", Int64.Type}, {"Impressions", Int64.Type}, {"Unique Inline Link Clicks", Int64.Type}, {"Unique Social Clicks", Int64.Type}, {"Call To Action Clicks", Int64.Type}, {"Clicks", Int64.Type}, {"Social Impressions", Int64.Type}, {"Social Clicks", Int64.Type}, {"Social Reach", Int64.Type}, {"Inline Link Clicks", Int64.Type}, {"Inline Post Engagement", Int64.Type}, {"Frequency", type number}, {"Spend", type number}, {"CPC", type number}, {"CPM", type number}, {"Social Spend", type number}}),
                tableOrderedColumns = Table.ReorderColumns(tableTyped, {"facebook_ad_key", "date", "Ad ID", "Campaign ID", "Adset ID", "Ad Name", "Account ID", "Adset Name", "Campaign Name", "Total Actions", "Reach", "Impressions", "Frequency", "Unique Clicks", "Spend", "Unique Inline Link Clicks", "Unique Social Clicks", "CPC", "CPM", "Call To Action Clicks", "Clicks", "Account Currency", "Account Name", "Social Impressions", "Social Clicks", "Social Reach", "Social Spend", "Objective", "Inline Link Clicks", "Inline Post Engagement"})
            in tableOrderedColumns,

        r = if List.Count(joined_response) > 0 then 
            response()
        else 
            null
    in
     r;

     
shared FacebookAds.GetAllActiveAds = (adAccount as record) =>
    let
        access_token = Extension.CurrentCredential()[access_token],
        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name,effective_status"]),

        joined_response = List.Generate(
            ()=> [result = null, query = seed], 
            each [query] <> null, 
            each [
                result = Json.Document(Web.Contents([query])), 
                query = try result[paging][next] otherwise null
            ], 
            each [result]
        ),

        response = Table.FromList(List.Skip(joined_response, 1), Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        expanded = Table.ExpandRecordColumn(response, "Column1", {"data"}, {"data"}),

        adIds = expanded[data]{0},
        adIdsActive = List.Select(adIds, each _[effective_status] = "ACTIVE"),

        getAdInsights = (ad as record) =>
        let 
            access_token = Extension.CurrentCredential()[access_token],
            insights = Web.Contents(baseUrl & ad[id] & "/insights?" & Uri.BuildQueryString([access_token=access_token,fields="ad_id,campaign_id,adset_id,ad_name,account_id,adset_name,campaign_name,total_actions,reach,impressions,frequency,unique_clicks,spend,unique_inline_link_clicks,unique_social_clicks,cpc,cpm,call_to_action_clicks,clicks,account_currency,account_name,social_impressions,social_clicks,social_reach,social_spend,objective,inline_link_clicks,inline_post_engagement", level="ad", date_preset="lifetime", time_increment="1"])),
            data = Json.Document(insights)[data],
            table = Table.FromRecords(data)
        in
            table,

        table = List.Accumulate(
            adIdsActive, 
            #table(null, {}),
            (state, current) => state & getAdInsights(current)
        ),

        tableNoBlanks = Table.SelectRows(table , each not List.IsEmpty(List.RemoveMatchingItems(Record.FieldValues(_), {"", null}))),
        tableTyped = Table.TransformColumnTypes(tableNoBlanks, {{"ad_id", type text}, {"campaign_id", type text}, {"adset_id", type text}, {"ad_name", type text}, {"account_id", type text}, {"adset_name", type text}, {"campaign_name", type text}, {"account_name", type text}, {"objective", type text}, {"date_start", type date}, {"date_stop", type date}, {"total_actions", Int64.Type}, {"reach", Int64.Type}, {"impressions", Int64.Type}, {"unique_inline_link_clicks", Int64.Type}, {"unique_social_clicks", Int64.Type}, {"call_to_action_clicks", Int64.Type}, {"clicks", Int64.Type}, {"social_impressions", Int64.Type}, {"social_clicks", Int64.Type}, {"social_reach", Int64.Type}, {"inline_link_clicks", Int64.Type}, {"inline_post_engagement", Int64.Type}, {"frequency", type number}, {"spend", type number}, {"cpc", type number}, {"cpm", type number}, {"social_spend", type number}}),
        tableWithDate = Table.RenameColumns(tableTyped, {{"date_start", "date"}}),
        tableWithNoEndDate = Table.RemoveColumns(tableWithDate, {"date_stop"}),
        tableWithDateFirst = Table.ReorderColumns(tableWithNoEndDate, {"date", "ad_id", "campaign_id", "adset_id", "ad_name", "account_id", "adset_name", "campaign_name", "total_actions", "reach", "impressions", "frequency", "unique_clicks", "spend", "unique_inline_link_clicks", "unique_social_clicks", "cpc", "cpm", "call_to_action_clicks", "clicks", "account_currency", "account_name", "social_impressions", "social_clicks", "social_reach", "social_spend", "objective", "inline_link_clicks", "inline_post_engagement"}),
        tableWithFriendlyNames = Table.RenameColumns(tableWithDateFirst,{{"adset_name", "Adset Name"}, {"account_id", "Account ID"}, {"ad_name", "Ad Name"}, {"adset_id", "Adset ID"}, {"campaign_id", "Campaign ID"}, {"ad_id", "Ad ID"}, {"campaign_name", "Campaign Name"}, {"total_actions", "Total Actions"}, {"reach", "Reach"}, {"impressions", "Impressions"}, {"frequency", "Frequency"}, {"unique_clicks", "Unique Clicks"}, {"spend", "Spend"}, {"unique_inline_link_clicks", "Unique Inline Link  Clicks"}, {"unique_social_clicks", "Unique Social Clicks"}, {"cpc", "CPC"}, {"cpm", "CPM"}, {"call_to_action_clicks", "Call To Action Clicks"}, {"clicks", "Clicks"}, {"account_currency", "Account Currency"}, {"account_name", "Account Name"}, {"social_impressions", "Social Impressions"}, {"social_clicks", "Social Clicks"}, {"social_reach", "Social Reach"}, {"social_spend", "Social Spend"}, {"objective", "Objective"}, {"inline_link_clicks", "Inline Link Clicks"}, {"inline_post_engagement", "Inline Post Engagement"}}),
        tableWithFBKey = Table.AddColumn(tableWithFriendlyNames, "facebook_ad_key", each Date.ToText([date]) & "_" & [Account ID] & "_" & [Campaign ID] & "_" & [Adset ID] & "_" & [Ad ID])
        
    in
        tableWithFBKey;


shared FacebookAds.GetAdActions = (adAccount as record) =>
    let
        access_token = Extension.CurrentCredential()[access_token],
//        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="lifetime", filtering="[{""field"":""spend"",""operator"":""GREATER_THAN"",""value"":""0""}]", limit="25"]),
        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="lifetime", limit="100"]),

        getAdIds = (query, result) =>
            let
                response = Json.Document(Web.Contents(query)),
                newResult = List.Combine({result, response[data]}),
                nextQuery = try response[paging][next] otherwise null
            in
                if nextQuery <> null then @getAdIds(nextQuery, newResult) else newResult,

        joined_response = List.Accumulate(
            {1}, 
            {},
            (state, adId) => List.Combine(
                { 
                  state, 
                  getAdIds(seed, {})
                }
            )
        ),

        response = Table.FromList(List.Skip(joined_response, 1), Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        tableOfAdIds = Table.ExpandRecordColumn(response, "Column1", {"id"}, {"id"}),
        adIds = tableOfAdIds[id],

        // List.Generator didn't work here - i spend to hours trying to decunstruct. Looked like a PQ/M error. Maybe I'll report it later
        // Shifting to simple recursive setup, and i learned about the @ operator for self referencing function
        getAdInsight = (query, result) =>
            let
                response = Json.Document(Web.Contents(query)),
                newResult = List.Combine({result, response[data]}),
                nextQuery = try response[paging][next] otherwise null
            in
                if nextQuery <> null then @getAdInsight(nextQuery, newResult) else newResult,

        list = List.Accumulate(
            adIds, 
            {},
            (state, adId) => List.Combine(
                { 
                  state, 
                  getAdInsight(baseUrl & adId & "/insights?" & Uri.BuildQueryString([access_token=access_token,fields="ad_id,campaign_id,adset_id,account_id,actions", level="ad", date_preset="lifetime", time_increment="1", limit="100"]), {})
                }
            )
        ),

        table = Table.FromList(list, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        expanded = Table.ExpandRecordColumn(table, "Column1", {"date_start", "ad_id", "campaign_id", "adset_id", "account_id", "actions"}, {"date", "Ad ID", "Campaign ID", "Adset ID", "Account ID", "Actions"}),
        tableWithFBKey = Table.AddColumn(expanded, "facebook_ad_key", each [date] & "_" & [Account ID] & "_" & [Campaign ID] & "_" & [Adset ID] & "_" & [Ad ID]),
        tableTyped = Table.TransformColumnTypes(tableWithFBKey, {{"Ad ID", type text}, {"Campaign ID", type text}, {"Adset ID", type text}, {"Account ID", type text}, {"date", type date}}),
        tableOrderedColumns = Table.ReorderColumns(tableTyped, {"facebook_ad_key", "date", "Ad ID", "Campaign ID", "Adset ID", "Account ID", "Actions"}),
        expandedActionsList = Table.ExpandListColumn(tableOrderedColumns, "Actions"),
        expandedActionsRecord = Table.ExpandRecordColumn(expandedActionsList, "Actions", {"action_type", "value"}, {"action_type", "value"}),
        expandedActionValuesTyped = Table.TransformColumnTypes(expandedActionsRecord,{{"value", type number}, {"action_type", type text}}),
        removedNulls = Table.SelectRows(expandedActionValuesTyped, each [action_type] <> null),
        tableWithAddedMetricsAsColumns = Table.Pivot(removedNulls, List.Distinct(removedNulls[action_type]), "action_type", "value", List.Sum)
    in
        tableWithAddedMetricsAsColumns;

shared FacebookAds.GetAdActionValues = (adAccount as record) =>
    let
        access_token = Extension.CurrentCredential()[access_token],
//        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="lifetime", filtering="[{""field"":""spend"",""operator"":""GREATER_THAN"",""value"":""0""}]", limit="25"]),
        seed = baseUrl & adAccount[id] & "/ads?" & Uri.BuildQueryString([access_token=access_token, fields="name", date_preset="lifetime", limit="100"]),

        getAdIds = (query, result) =>
            let
                response = Json.Document(Web.Contents(query)),
                newResult = List.Combine({result, response[data]}),
                nextQuery = try response[paging][next] otherwise null
            in
                if nextQuery <> null then @getAdIds(nextQuery, newResult) else newResult,

        joined_response = List.Accumulate(
            {1}, 
            {},
            (state, adId) => List.Combine(
                { 
                  state, 
                  getAdIds(seed, {})
                }
            )
        ),

        response = Table.FromList(List.Skip(joined_response, 1), Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        tableOfAdIds = Table.ExpandRecordColumn(response, "Column1", {"id"}, {"id"}),
        adIds = tableOfAdIds[id],

        // List.Generator didn't work here - i spend to hours trying to deconstruct. Looked like a PQ/M error. Maybe I'll report it later
        // Shifting to simple recursive setup, and i learned about the @ operator for self referencing function
        getAdInsight = (query, result) =>
            let
                response = Json.Document(Web.Contents(query)),
                newResult = List.Combine({result, response[data]}),
                nextQuery = try response[paging][next] otherwise null
            in
                if nextQuery <> null then @getAdInsight(nextQuery, newResult) else newResult,

        list = List.Accumulate(
            adIds, 
            {},
            (state, adId) => List.Combine(
                { 
                  state, 
                  getAdInsight(baseUrl & adId & "/insights?" & Uri.BuildQueryString([access_token=access_token,fields="ad_id,campaign_id,adset_id,account_id,action_values", level="ad", date_preset="lifetime", time_increment="1", limit="90"]), {})
                }
            )
        ),

        table = Table.FromList(list, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        expanded = Table.ExpandRecordColumn(table, "Column1", {"date_start", "ad_id", "campaign_id", "adset_id", "account_id", "action_values"}, {"date", "Ad ID", "Campaign ID", "Adset ID", "Account ID", "Action Values"}),
        tableWithFBKey = Table.AddColumn(expanded, "facebook_ad_key", each [date] & "_" & [Account ID] & "_" & [Campaign ID] & "_" & [Adset ID] & "_" & [Ad ID]),
        tableTyped = Table.TransformColumnTypes(tableWithFBKey, {{"Ad ID", type text}, {"Campaign ID", type text}, {"Adset ID", type text}, {"Account ID", type text}, {"date", type date}}),
        tableOrderedColumns = Table.ReorderColumns(tableTyped, {"facebook_ad_key", "date", "Ad ID", "Campaign ID", "Adset ID", "Account ID", "Action Values"}),
        expandedActionValuesList = Table.ExpandListColumn(tableOrderedColumns, "Action Values"),
        expandedActionValuesRecord = Table.ExpandRecordColumn(expandedActionValuesList, "Action Values", {"action_type", "value"}, {"action_type", "value"}),
        expandedActionValuesTyped = Table.TransformColumnTypes(expandedActionValuesRecord,{{"value", type number}, {"action_type", type text}}),
        removedNulls = Table.SelectRows(expandedActionValuesTyped, each [action_type] <> null),
        tableWithAddedMetricsAsColumns = Table.Pivot(removedNulls, List.Distinct(removedNulls[action_type]), "action_type", "value", List.Sum)
    in
        tableWithAddedMetricsAsColumns;

FacebookAds.GetData = (query, result) =>
    let
        response = Json.Document(Web.Contents(query)),
        newResult = List.Combine({result, response[data]}),
        nextQuery = try response[paging][next] otherwise null,
        testForError = try response
    in
        if testForError[HasError] then 
            {[]}
        else if nextQuery <> null then FacebookAds.GetData(nextQuery, newResult) else newResult;

////////////////////////////////////////////////////////////////////////////////////////////////////
////////////                                                                            ////////////
////////////The following functions are a set of helper functions provided by Microsoft ////////////
////////////                                                                           ////////////
///////////////////////////////////////////////////////////////////////////////////////////////////


//// Table Navigation function provided by Microsoft. 
//// Get the full example on how to create a Navigation Table from Microsoft here > https://github.com/Microsoft/DataConnectors/tree/master/samples/NavigationTable

Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta 
        [
            NavigationTable.NameColumn = nameColumn, 
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn, 
            Preview.DelayColumn = itemNameColumn, 
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;

//// Function to check if the text string exists or if it should grab the next string
//// Get the full example on why this function was created from Microsoft here > https://github.com/Microsoft/DataConnectors/blob/fe8cb91f694e476bd70c10b9295a815d7bfc42d7/samples/MyGraph/README.md

Value.IfNull = (a, b) => if a <> null then a else b;

//// Function to concatenate all the scopes and create a string for them
//// Get the full example on why this function was created from Microsoft here > https://github.com/Microsoft/DataConnectors/blob/fe8cb91f694e476bd70c10b9295a815d7bfc42d7/samples/MyGraph/README.md
GetScopeString = (scopes as list, optional scopePrefix as text) as text =>
    let
        prefix = Value.IfNull(scopePrefix, ""),
        addPrefix = List.Transform(scopes, each prefix & _),
        asText = Text.Combine(addPrefix, " ")
    in
        asText;

//// Helper function to create sample tables
SampleTable = ( OutputTable as table) as text =>

let
    TableToTransform = Table.FirstN(OutputTable,2),        
    Headers = Text.Combine(List.Transform(Table.ColumnNames(TableToTransform), each """"""&Text.From(_)&""""""), ","),
    Data = Text.Combine(List.Transform(List.Transform(Table.ToRows(TableToTransform), each Text.Combine(List.Transform(_, (_)=> """"""&Text.From(_)&""""""), ",")), each "{"&_&"}"), ","),
    TableFormat = "#table({"&Headers&"},{"&Data&"})"
in
    TableFormat;