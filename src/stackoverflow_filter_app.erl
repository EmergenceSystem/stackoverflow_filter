-module(stackoverflow_filter_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% Handler callbacks
-export([handle/1]).

-define(STACKEXCHANGE_API_URL, "https://api.stackexchange.com/2.3/search/advanced").

%% Application behavior
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(stackoverflow_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%% @doc Handle incoming requests from the filter server.
handle(Body) when is_binary(Body) ->
    handle(binary_to_list(Body));

handle(Body) when is_list(Body) ->
    EmbryoList = generate_embryo_list(list_to_binary(Body)),
    Response = #{embryo_list => EmbryoList},
    jsone:encode(Response);

handle(_) ->
    jsone:encode(#{error => <<"Invalid request body">>}).

generate_embryo_list(JsonBinary) ->
    case jsone:decode(JsonBinary, [{keys, atom}]) of
        Search when is_map(Search) ->
            Value = binary_to_list(maps:get(value, Search, <<"">>)),
            Timeout = list_to_integer(binary_to_list(maps:get(timeout, Search, <<"10">>))),

            %% Recherche sur Stack Overflow
            search_stackoverflow(Value, Timeout);
        {error, Reason} ->
            io:format("Error decoding JSON: ~p~n", [Reason]),
            []
    end.

search_stackoverflow(Query, TimeoutSecs) ->
    EncodedQuery = uri_string:quote(Query),
    
    %% API Stack Exchange avec paramètres optimisés
    Url = lists:concat([?STACKEXCHANGE_API_URL,
                        "?order=desc",
                        "&sort=relevance",
                        "&q=", EncodedQuery,
                        "&site=stackoverflow",
                        "&pagesize=30",
                        "&filter=withbody"]),
    
    %% Headers requis pour éviter le 403
    Headers = [
        {"User-Agent", "Emergence-StackOverflow-Filter/1.0"},
        {"Accept", "application/json"},
        {"Accept-Encoding", "gzip"}
    ],
    
    case httpc:request(get, {Url, Headers}, [{timeout, TimeoutSecs * 1000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            extract_items_from_response(Body);
        {ok, {{_, StatusCode, _}, _, Body}} ->
            io:format("Stack Exchange API returned status ~p: ~p~n", [StatusCode, Body]),
            [];
        {error, Reason} ->
            io:format("Error fetching Stack Overflow results: ~p~n", [Reason]),
            []
    end.

extract_items_from_response(JsonData) ->
    try
        %% L'API Stack Exchange retourne du JSON compressé par défaut
        Decompressed = try
            zlib:gunzip(JsonData)
        catch
            _:_ -> JsonData  % Si ce n'est pas compressé, utiliser tel quel
        end,
        
        ParsedJson = jsone:decode(Decompressed),
        case maps:get(<<"items">>, ParsedJson, undefined) of
            Items when is_list(Items) ->
                lists:filtermap(fun process_question/1, Items);
            _ ->
                []
        end
    catch
        error:Reason ->
            io:format("Failed to parse Stack Overflow response: ~p~n", [Reason]),
            []
    end.

process_question(Question) ->
    try
        QuestionId = maps:get(<<"question_id">>, Question, undefined),
        Title = maps:get(<<"title">>, Question, undefined),
        
        case {QuestionId, Title} of
            {QId, T} when is_integer(QId), is_binary(T) ->
                Score = maps:get(<<"score">>, Question, 0),
                AnswerCount = maps:get(<<"answer_count">>, Question, 0),
                ViewCount = maps:get(<<"view_count">>, Question, 0),
                IsAnswered = maps:get(<<"is_answered">>, Question, false),
                
                %% Obtenir les tags
                Tags = case maps:get(<<"tags">>, Question, []) of
                    TagList when is_list(TagList) ->
                        TagsBin = lists:map(fun(Tag) -> <<" [", Tag/binary, "]">> end, TagList),
                        iolist_to_binary(TagsBin);
                    _ ->
                        <<>>
                end,
                
                %% Icône selon statut
                StatusIcon = case IsAnswered of
                    true -> <<"✓">>;
                    false -> <<"○">>
                end,
                
                Url = iolist_to_binary(io_lib:format("https://stackoverflow.com/questions/~p", [QId])),
                
                %% Format: [✓/○] Title [score | answers | views]
                ResumeStr = io_lib:format("[~ts] ~ts [~p↑ | ~p answers | ~p views]~ts", 
                                         [binary_to_list(StatusIcon),
                                          binary_to_list(T), 
                                          Score, 
                                          AnswerCount, 
                                          ViewCount,
                                          binary_to_list(Tags)]),
                Resume = unicode:characters_to_binary(ResumeStr),
                
                {true, #{
                    properties => #{
                        <<"url">> => Url,
                        <<"resume">> => Resume,
                        <<"type">> => <<"stackoverflow_question">>
                    }
                }};
            _ ->
                false
        end
    catch
        _:_ -> false
    end.
