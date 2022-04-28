-module(grisp_updater_source).

-behavior(gen_server).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").


%--- Behaviour Definition ------------------------------------------------------

-callback source_init(Opts :: map()) ->
    {ok, State :: term()} | {error, term()}.
-callback source_open(State :: term(), Url :: binary(), Opts :: map()) ->
    {ok, SourceRef :: term(), State :: term()} | not_supported | {error, term()}.
-callback source_stream(State :: term(), SourceRef :: term(),
                        Path :: binary(), Opts :: map()) ->
    {stream, StreamRef :: term(), State :: term()}
  | {data, Data :: binary(), State :: term()}
  | {error, term()}.
-callback source_cancel(State :: term(), SourceRef :: term(), StreamRef :: term()) ->
    State :: term().
-callback source_handle(State :: term(), Msg :: term()) ->
    pass
  | {ok, State :: term}
  | {data, StreamRef :: term(), Data :: binary(), State :: term()}
  | {done, StreamRef :: term(), Data :: binary(), State :: term()}
  | {stream_error, [StreamRef :: term()], Reason :: term(), State :: term()}
  | {source_error, SourceRef :: term(), Reason :: term(), State :: term()}.
-callback source_close(State :: term(), SourceRef :: term()) ->
    State :: term().
-callback source_terminate(State :: term(), Reason :: term()) ->
    ok.

-optional_callbacks([source_handle/2]).



%--- Exports -------------------------------------------------------------------

% API
-export([start_link/1]).
-export([load/2]).
-export([stream/4]).
-export([cancel/1]).

% Callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).


%--- Records -------------------------------------------------------------------

-record(source, {
    source :: term(),
    backend :: term(),
    url :: binary(),
    refcount = 1 :: non_neg_integer(),
    tref :: undefined | reference()
}).

-record(load, {
    source :: term(),
    from :: term(),
    data :: iolist()
}).

-record(stream, {
    source :: reference(),
    mod :: module(),
    params :: term()
}).

-record(state, {
    backends :: undefined | #{term() => {module(), term()}},
    urls = #{} :: #{binary() => reference()},
    sources = #{} :: #{term() => #source{}},
    streams = #{} :: #{term() => #load{} | #stream{}}
}).


%--- Macros --------------------------------------------------------------------

-define(SOURCE_CLOSE_DELAY, 1000).


%--- API Functions -------------------------------------------------------------

start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

load(Url, Path) ->
    gen_server:call(?MODULE, {load, Url, Path}).

stream(Url, Path, SinkMod, SinkParams) ->
    gen_server:call(?MODULE, {stream, Url, Path, SinkMod, SinkParams}).

cancel(StreamRef) ->
    gen_server:call(?MODULE, {cancel, StreamRef}).


%--- Callbacks -----------------------------------------------------------------

init(#{backends := Backends})  ->
    ?LOG_INFO("Starting update source...", []),
    source_init(#state{}, Backends).

handle_call({load, Url, Path}, From, State) ->
    case start_loading(State, Url, Path, From) of
        {ok, State2} -> {noreply, State2};
        {error, Reason, State2} -> {reply, {error, Reason}, State2}
    end;
handle_call({stream, Url, Path, SinkMod, SinkParams}, _From, State) ->
    case start_streaming(State, Url, Path, SinkMod, SinkParams) of
        {ok, StreamRef, State2} -> {reply, {ok, StreamRef}, State2};
        {error, Reason, State2} -> {reply, {error, Reason}, State2}
    end;
handle_call({cancel, StreamRef}, _From, State) ->
    {reply, ok, cancel_stream(State, StreamRef)};
handle_call(Request, From, State) ->
    ?LOG_WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Request, State) ->
    ?LOG_WARNING("Unexpected cast: ~p", [Request]),
    {noreply, State}.

handle_info({delayed_close_source, SourceRef, MinRefCount}, State) ->
    {noreply, delayed_close_source(State, SourceRef, MinRefCount)};
handle_info(Info, State) ->
    case handle_message(State, Info) of
        {ok, State2} ->
            {noreply, State2};
        pass ->
            ?LOG_WARNING("Unexpected messagge: ~p", [Info]),
            {noreply, State}
    end.

terminate(Reason, #state{backends = Backends, sources = Sources,
                         streams = Streams} = State) ->
    lists:foreach(fun
        ({_, #load{from = From}}) ->
            gen_server:reply(From, {error, Reason});
        ({StreamRef, #stream{mod = SinkMod, params = SinkParams}}) ->
            SinkMod:sink_error(StreamRef, SinkParams, Reason)
    end, maps:to_list(Streams)),
    State2 = lists:foldl(
        fun(#source{source = SourceRef, backend = BackendRef}, S) ->
            source_close(S, BackendRef, SourceRef)
        end, State, maps:values(Sources)),
    lists:foreach(fun(BackendRef) ->
        source_terminate(State2, BackendRef, Reason)
    end, maps:keys(Backends)),
    ok.


%--- Internal ------------------------------------------------------------------

start_loading(State, Url, Path, From) ->
    case get_session(State, Url) of
        {error, Reason} ->
            {error, Reason, State};
        {ok, BackendRef, SourceRef, State2} ->
            case source_stream(State2, BackendRef, SourceRef, Path, #{}) of
                {error, Reason} ->
                    {error, Reason, decref_source(State2, SourceRef, 1)};
                {data, Data, State3} ->
                    gen_server:reply(From, {ok, Data}),
                    {ok, decref_source(State3, SourceRef, 1)};
                {stream, StreamRef, State3} ->
                    Load = #load{source = SourceRef, from = From, data = []},
                    {ok, add_stream(State3, SourceRef, StreamRef, Load)}
            end
    end.

start_streaming(State, Url, Path, SinkMod, SinkParams) ->
    case get_session(State, Url) of
        {error, Reason} ->
            {error, Reason, State};
        {ok, BackendRef, SourceRef, State2} ->
            case source_stream(State2, BackendRef, SourceRef, Path, #{}) of
                {error, Reason} ->
                    {error, Reason, decref_source(State2, SourceRef, 1)};
                {data, Data, State3} ->
                    TempStreamRef = make_ref(),
                    SinkMod:sink_done(TempStreamRef, SinkParams, Data),
                    {ok, TempStreamRef, State3};
                {stream, StreamRef, State3} ->
                    Stream = #stream{source = SourceRef, mod = SinkMod,
                                     params = SinkParams},
                    State4 = add_stream(State3, SourceRef, StreamRef, Stream),
                    {ok, StreamRef, State4}
            end
    end.

cancel_stream(#state{streams = StreamMap, sources = SourceMap} = State, StreamRef) ->
    case maps:find(StreamRef, StreamMap) of
        error -> State;
        {ok, #stream{source = SourceRef, mod = SinkMod, params = SinkParams}} ->
            #{SourceRef := #source{backend = BackendRef}} = SourceMap,
            SinkMod:sink_error(StreamRef, SinkParams, cancelled),
            del_stream(source_cancel(State, BackendRef, SourceRef, StreamRef), StreamRef)
    end.

handle_message(#state{streams = StreamMap} = State, Msg) ->
    case source_handle(State, Msg) of
        pass -> pass;
        {ok, _State2} = Result -> Result;
        {stream_error, StreamRefs, Reason, State2} ->
            State3 = lists:foldl(fun(StreamRef, S) ->
                notify_stream_error(S, StreamRef, Reason),
                del_stream(S, StreamRef)
            end, State2, StreamRefs),
            {ok, State3};
        {source_error, SourceRef, Reason, State2} ->
            notify_source_error(State2, SourceRef, Reason),
            {ok, del_source(State2, SourceRef)};
        {data, StreamRef, Data, State2} ->
            case maps:find(StreamRef, StreamMap) of
                error ->
                    ?LOG_WARNING("Source data for unknown stream ~w",
                                 [StreamRef]),
                    {ok, State2};
                {ok, #load{data = Buff} = Load} ->
                    Load2 = Load#load{data = [Data | Buff]},
                    {ok, State2#state{streams = StreamMap#{StreamRef => Load2}}};
                {ok, #stream{mod = SinkMod, params = SinkParams}} ->
                    case SinkMod:sink_data(StreamRef, SinkParams, Data) of
                        ok -> {ok, State2};
                        {abort, Reason} ->
                            ?LOG_DEBUG("Stream aborted by sink: ~p", [Reason]),
                            notify_stream_error(State, StreamRef, Reason),
                            {ok, del_stream(State2, StreamRef)}
                    end
            end;
        {done, StreamRef, Data, State2} ->
            case maps:find(StreamRef, StreamMap) of
                error ->
                    ?LOG_WARNING("Source final data for unknown stream ~w",
                                 [StreamRef]),
                    {ok, State2};
                {ok, #load{data = Buff, from = From}} ->
                    Result = iolist_to_binary(lists:reverse([Data | Buff])),
                    gen_server:reply(From, {ok, Result}),
                    {ok, del_stream(State2, StreamRef)};
                {ok, #stream{mod = SinkMod, params = SinkParams}} ->
                    SinkMod:sink_done(StreamRef, SinkParams, Data),
                    {ok, del_stream(State2, StreamRef)}
            end
    end.

notify_source_error(#state{sources = SourceMap, streams = StreamMap},
                     SourceRef, Reason) ->
    case maps:find(SourceRef, SourceMap) of
        error ->
            ?LOG_WARNING("Error for unknown source ~w: ~p",
                         [SourceRef, Reason]),
            ok;
        {ok, #source{}} ->
            lists:foreach(fun
                ({_, #load{source = S, from = From}}) when S =:= SourceRef ->
                    gen_server:reply(From, {error, Reason});
                ({StreamRef, #stream{source = S, mod = SinkMod, params = SinkParams}})
                  when S =:= SourceRef ->
                    SinkMod:sink_error(StreamRef, SinkParams, Reason)
            end, maps:to_list(StreamMap))
    end.

notify_stream_error(#state{streams = StreamMap}, StreamRef, Reason) ->
    case maps:find(StreamRef, StreamMap) of
        error ->
            ?LOG_WARNING("Error for unknown stream ~w: ~p",
                         [StreamRef, Reason]);
        {ok, #load{from = From}} ->
            gen_server:reply(From, {error, Reason});
        {ok, #stream{mod = SinkMod, params = SinkParams}} ->
            SinkMod:sink_error(StreamRef, SinkParams, Reason)
    end.

get_session(#state{urls = UrlMap, sources = SourceMap} = State, Url) ->
    case maps:find(Url, UrlMap) of
        {ok, SourceRef} ->
            #{SourceRef := #source{backend = BackendRef}} = SourceMap,
            {ok, BackendRef, SourceRef, State};
        error ->
            case source_open(State, Url, #{}) of
                {error, _Reason} = Error -> Error;
                {ok, BackendRef, SourceRef, State2} ->
                    Source = #source{
                        backend = BackendRef,
                        source = SourceRef,
                        url = Url,
                        refcount = 0
                    },
                    SourceMap2 = SourceMap#{SourceRef => Source},
                    UrlMap2 = UrlMap#{Url => SourceRef},
                    State3 = State2#state{urls = UrlMap2, sources = SourceMap2},
                    {ok, BackendRef, SourceRef, State3}
            end
    end.

del_source(#state{streams = StreamMap} = State, SourceRef) ->
    Refs = lists:foldl(fun
        ({X, #load{source = R}}, Acc) when R =:= SourceRef -> [X | Acc];
        ({X, #stream{source = R}}, Acc) when R =:= SourceRef -> [X | Acc]
    end, [], maps:to_list(StreamMap)),
    State2 = lists:foldl(fun(StreamRef, S) ->
        del_stream(S, StreamRef)
    end, State, Refs),
    % Ensure the session is closed even if something went wrong between
    % a session is opened and a stream is started
    force_close_source(State2, SourceRef).

% Remove a session if the refcount is smaller or equal to given count
decref_source(#state{sources = SourceMap} = State,
                   SourceRef, MinRefCount) ->
    case maps:find(SourceRef, SourceMap) of
        error -> State;
        {ok, #source{refcount = RefCount} = Source} ->
            Source2 = Source#source{refcount = RefCount - 1},
            Source3 = if
                MinRefCount =:= infinity ->
                    schedule_close_source(Source2, infinity);
                RefCount =< MinRefCount ->
                    schedule_close_source(Source2, MinRefCount - 1);
                true ->
                    Source2
            end,
            SourceMap2 = SourceMap#{SourceRef := Source3},
            State#state{sources = SourceMap2}
    end.

schedule_close_source(#source{tref = undefined, source = SourceRef} = Source,
                      MinRefCount) ->
    TRef = erlang:send_after(?SOURCE_CLOSE_DELAY, self(),
                             {delayed_close_source, SourceRef, MinRefCount}),
    Source#source{tref = TRef};
schedule_close_source(#source{tref = TRef} = Source, MinRefCount) ->
    erlang:cancel_timer(TRef),
    schedule_close_source(Source#source{tref = undefined}, MinRefCount).

delayed_close_source(#state{sources = SourceMap} = State,
                     SourceRef, MinRefCount) ->
    case maps:find(SourceRef, SourceMap) of
        error -> State;
        {ok, #source{refcount = RefCount} = Source}
          when MinRefCount =:= infinity; RefCount =< MinRefCount ->
            force_close_source(State, Source#source{tref = undefined});
        {ok, #source{} = Source} ->
            Source2 = Source#source{tref = undefined},
            SourceMap2 = SourceMap#{SourceRef := Source2},
            State#state{sources = SourceMap2}
    end.

force_close_source(#state{urls = UrlMap, sources = SourceMap} = State,
                   #source{source = SourceRef, backend = BackendRef,
                           url = Url, tref = TRef}) ->
    if TRef =/= undefined -> erlang:cancel_timer(TRef); true -> ok end,
    State2 = source_close(State, BackendRef, SourceRef),
    SourceMap2 = maps:remove(SourceRef, SourceMap),
    UrlMap2 = maps:remove(Url, UrlMap),
    State2#state{urls = UrlMap2, sources = SourceMap2};
force_close_source(#state{sources = SourceMap} = State,
                   SourceRef) ->
    case maps:find(SourceRef, SourceMap) of
        error -> State;
        {ok, Source} -> force_close_source(State, Source)
    end.

add_stream(#state{sources = SourceMap, streams = StreamMap} = State,
           SourceRef, StreamRef, StreamData) ->
    #source{refcount = RefCount} = Source = maps:get(SourceRef, SourceMap),
    error = maps:find(StreamRef, StreamMap),
    StreamMap2 = StreamMap#{StreamRef => StreamData},
    Source2 = Source#source{refcount = RefCount + 1},
    SourceMap2 = SourceMap#{SourceRef => Source2},
    State#state{sources = SourceMap2, streams = StreamMap2}.

del_stream(#state{streams = StreamMap} = State, StreamRef) ->
    case maps:take(StreamRef, StreamMap) of
        error -> State;
        {#load{source = R}, M} ->
            decref_source(State#state{streams = M}, R, 1);
        {#stream{source = R}, M} ->
            decref_source(State#state{streams = M}, R, 1)
    end.


%--- Source Handling Functions

source_init(#state{backends = undefined} = State, BackendSpecs) ->
    case source_init_loop(BackendSpecs, []) of
        {error, _Reason} = Error -> Error;
        {ok, Backends} ->
            {ok, State#state{backends = maps:from_list(Backends)}}
    end.

source_init_loop([], Backends) ->
    {ok, lists:reverse(Backends)};
source_init_loop([{Mod, Opts} | Rest], Backends)
  when is_atom(Mod), is_map(Opts) ->
    case Mod:source_init(Opts) of
        {ok, Sub} ->
            source_init_loop(Rest, [{make_ref(), {Mod, Sub}} | Backends]);
        {error, Reason} = Error ->
            lists:foreach(fun({_, {M, S}}) ->
                M:source_terminate(S, Reason)
            end, Backends),
            Error
    end;
source_init_loop([BackendSpec | _], Backends) ->
    Reason = {bad_backend, BackendSpec},
    lists:foreach(fun({_, {M, S}}) ->
        M:source_terminate(S, Reason)
    end, Backends),
    {error, Reason}.

source_open(#state{backends = Backends} = State, Url, Opts) ->
    case source_open_loop(maps:keys(Backends), Backends, Url, Opts) of
        not_supported -> {error, not_supported};
        {error, _Reason} = Error -> Error;
        {ok, BackendRef, SourceRef, Backends2} ->
            {ok, BackendRef, SourceRef, State#state{backends = Backends2}}
    end.

source_open_loop([], _Backends, _Url, _Opts) ->
    not_supported;
source_open_loop([Ref | Rest], Backends, Url, Opts) ->
    #{Ref := {Mod, Sub}} = Backends,
    case Mod:source_open(Sub, Url, Opts) of
        not_supported -> source_open_loop(Rest, Backends, Url, Opts);
        {error, _Reason} = Error -> Error;
        {ok, SourceRef, Sub2} ->
            {ok, Ref, SourceRef, Backends#{Ref := {Mod, Sub2}}}
    end.

source_stream(#state{backends = Backends} = State,
              BackendRef, SourceRef, Path, Opts) ->
    #{BackendRef := {Mod, Sub}} = Backends,
    case Mod:source_stream(Sub, SourceRef, Path, Opts) of
        {error, Reason} ->
            {error, Reason};
        {data, Data, Sub2} ->
            State2 = State#state{backends = Backends#{BackendRef := {Mod, Sub2}}},
            {data, Data, State2};
        {stream, StreamRef, Sub2} ->
            State2 = State#state{backends = Backends#{BackendRef := {Mod, Sub2}}},
            {stream, StreamRef, State2}
    end.

source_cancel(#state{backends = Backends} = State,
              BackendRef, SourceRef, StreamRef) ->
    #{BackendRef := {Mod, Sub}} = Backends,
    Sub2 = Mod:source_cancel(Sub, SourceRef, StreamRef),
    State#state{backends = Backends#{BackendRef := {Mod, Sub2}}}.

source_handle(#state{backends = Backends} = State, Msg) ->
    case source_handle_loop(maps:keys(Backends), Backends, Msg) of
        pass -> pass;
        {ok, Backends2} ->
            {ok, State#state{backends = Backends2}};
        {stream_error, StreamRefs, Reason, Backends2} ->
            {stream_error, StreamRefs, Reason, State#state{backends = Backends2}};
        {source_error, SourceRef, Reason, Backends2} ->
            {source_error, SourceRef, Reason, State#state{backends = Backends2}};
        {data, StreamRef, Data, Backends2} ->
            {data, StreamRef, Data, State#state{backends = Backends2}};
        {done, StreamRef, Data, Backends2} ->
            {done, StreamRef, Data, State#state{backends = Backends2}}
    end.

source_handle_loop([], _Backends, _Msg) ->
    pass;
source_handle_loop([Ref | Rest], Backends, Msg) ->
    #{Ref := {Mod, Sub}} = Backends,
    try Mod:source_handle(Sub, Msg) of
        pass ->
            source_handle_loop(Rest, Backends, Msg);
        {ok, Sub2} ->
            {ok, Backends#{Ref := {Mod, Sub2}}};
        {stream_error, StreamRefs, Reason, Sub2} ->
            {stream_error, StreamRefs, Reason, Backends#{Ref := {Mod, Sub2}}};
        {source_error, SourceRef, Reason, Sub2} ->
            {source_error, SourceRef, Reason, Backends#{Ref := {Mod, Sub2}}};
        {data, StreamRef, Data, Sub2} ->
            {data, StreamRef, Data, Backends#{Ref := {Mod, Sub2}}};
        {done, StreamRef, Data, Sub2} ->
            {done, StreamRef, Data, Backends#{Ref := {Mod, Sub2}}}
    catch
        error:undef ->
            source_handle_loop(Rest, Backends, Msg)
    end.

source_close(#state{backends = Backends} = State, BackendRef, SourceRef) ->
    #{BackendRef := {Mod, Sub}} = Backends,
    Sub2 = Mod:source_close(Sub, SourceRef),
    State#state{backends = Backends#{BackendRef := {Mod, Sub2}}}.

source_terminate(#state{backends = Backends}, BackendRef, Reason) ->
    #{BackendRef := {Mod, Sub}} = Backends,
    Mod:source_terminate(Sub, Reason).
