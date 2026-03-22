%%%-------------------------------------------------------------------
%%% @doc Stack Overflow search agent using the Stack Exchange API.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(stackoverflow_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(API_URL, "https://api.stackexchange.com/2.3/search/advanced").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"stackoverflow">>, <<"code">>,
                                      <<"qa">>, <<"programming">>, <<"debugging">>].

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(stackoverflow_filter, ?MODULE, #{
        capabilities => base_capabilities()
    }),
    {ok, self()}.

stop(_State) ->
    em_filter:stop_agent(stackoverflow_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

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
    Headers = [{"User-Agent",      "Emergence-StackOverflow-Filter/1.0"},
               {"Accept",          "application/json"},
               {"Accept-Encoding", "gzip"}],
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
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
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
            Score    = maps:get(<<"score">>,        Q, 0),
            Answers  = maps:get(<<"answer_count">>, Q, 0),
            Views    = maps:get(<<"view_count">>,   Q, 0),
            Answered = maps:get(<<"is_answered">>,  Q, false),
            Tags     = case maps:get(<<"tags">>, Q, []) of
                List when is_list(List) ->
                    iolist_to_binary([<<" [", Tag/binary, "]">> || Tag <- List]);
                _ -> <<>>
            end,
            Icon   = case Answered of true -> <<"✓">>; false -> <<"○">> end,
            Url    = iolist_to_binary(
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
