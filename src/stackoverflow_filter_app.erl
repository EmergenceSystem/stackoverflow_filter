%%%-------------------------------------------------------------------
%%% @doc Stack Overflow search filter using the Stack Exchange API.
%%%
%%% Queries the Stack Exchange advanced search API and returns
%%% matching questions as embryo maps.
%%% @end
%%%-------------------------------------------------------------------
-module(stackoverflow_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1]).

-define(API_URL, "https://api.stackexchange.com/2.3/search/advanced").

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_filter(stackoverflow_filter, ?MODULE).

stop(_State) ->
    em_filter:stop_filter(stackoverflow_filter).

%%====================================================================
%% Filter handler — returns a list of embryo maps
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    Url = lists:concat([?API_URL,
                        "?order=desc&sort=relevance",
                        "&q=",       uri_string:quote(Value),
                        "&site=stackoverflow",
                        "&pagesize=30",
                        "&filter=withbody"]),
    Headers = [{"User-Agent",       "Emergence-StackOverflow-Filter/1.0"},
               {"Accept",           "application/json"},
               {"Accept-Encoding",  "gzip"}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, Timeout * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_response(Body);
        _ ->
            []
    end.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>,   Map, <<"">>)),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

%%--------------------------------------------------------------------
%% Response parsing — API returns gzip-compressed JSON
%%--------------------------------------------------------------------

parse_response(Body) ->
    Decompressed = try zlib:gunzip(Body) catch _:_ -> Body end,
    try json:decode(Decompressed) of
        #{<<"items">> := Items} when is_list(Items) ->
            lists:filtermap(fun process_question/1, Items);
        _ -> []
    catch
        _:_ -> []
    end.

process_question(Q) ->
    case {maps:get(<<"question_id">>, Q, undefined),
          maps:get(<<"title">>,       Q, undefined)} of
        {QId, T} when is_integer(QId), is_binary(T) ->
            Score     = maps:get(<<"score">>,        Q, 0),
            Answers   = maps:get(<<"answer_count">>, Q, 0),
            Views     = maps:get(<<"view_count">>,   Q, 0),
            Answered  = maps:get(<<"is_answered">>,  Q, false),
            Tags      = case maps:get(<<"tags">>, Q, []) of
                List when is_list(List) ->
                    iolist_to_binary([<<" [", Tag/binary, "]">> || Tag <- List]);
                _ -> <<>>
            end,
            Icon = case Answered of true -> <<"✓">>; false -> <<"○">> end,
            Url  = iolist_to_binary(
                io_lib:format("https://stackoverflow.com/questions/~p", [QId])),
            Resume = unicode:characters_to_binary(
                io_lib:format("[~ts] ~ts [~p↑ | ~p answers | ~p views]~ts",
                    [Icon, T, Score, Answers, Views, Tags])),
            {true, #{
                <<"properties">> => #{
                    <<"url">>    => Url,
                    <<"resume">> => Resume
                }
            }};
        _ -> false
    end.
