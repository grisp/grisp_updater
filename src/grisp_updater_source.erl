-module(grisp_updater_source).

-behavior(gen_server).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").


%--- Behaviour Definition ------------------------------------------------------

-callback source_init(Opts :: map()) ->
    {ok, State :: term()} | {error, term()}.
-callback source_open(State :: term(), Url :: binary(), Opts :: map()) ->
    {ok, SessRef :: reference(), State :: term()} | {error, term()}.
-callback source_stream(State :: term(), SessRef :: reference(),
                        Path :: binary(), Opts :: map()) ->
    {stream, StreamRef :: reference(), State :: term()}
  | {data, Data :: binary(), State :: term()}
  | {error, term()}.
-callback source_cancel(State :: term(), StreamRef :: reference()) ->
    State :: term().
-callback source_handle(State :: term(), Msg :: term()) ->
    pass
  | {ok, State :: term}
  | {data, StreamRef :: reference(), Data :: binary(), State :: term()}
  | {done, StreamRef :: reference(), Data :: binary(), State :: term()}
  | {stream_error, StreamRef :: reference(), Reason :: term()}
  | {session_error, SessRef :: reference(), Reason :: term()}.
-callback source_close(State :: term(), SessRef :: reference()) ->
    State :: term().
-callback source_terminate(State :: term(), Reason :: term()) ->
    ok.


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

-record(sess, {
    url :: binary(),
    refcount = 1 :: non_neg_integer()
}).

-record(load, {
    sess :: reference(),
    from :: term(),
    data :: iolist()
}).

-record(stream, {
    sess :: reference(),
    mod :: module(),
    params :: term()
}).

-record(state, {
    source :: {module(), term()},
    urls = #{} :: #{binary() => reference()},
    sessions = #{} :: #{reference() => #sess{}},
    streams = #{} :: #{reference() => #load{} | #stream{}}
}).


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

init(#{backend := Backend})  ->
    ?LOG_INFO("Starting update source...", []),
    source_init(#state{}, Backend).

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

handle_info(Info, State) ->
    case handle_message(State, Info) of
        {ok, State2} -> {noreply, State2};
        pass ->
            ?LOG_WARNING("Unexpected messagge: ~p", [Info]),
            {noreply, State}
    end.

terminate(Reason, #state{sessions = Sessions, streams = Streams} = State) ->
    lists:foreach(fun
        ({_, #load{from = From}}) ->
            gen_server:reply(From, {error, Reason});
        ({StreamRef, #stream{mod = SinkMod, params = SinkParams}}) ->
            SinkMod:sink_error(StreamRef, SinkParams, Reason)
    end, maps:to_list(Streams)),
    State2 = lists:foldl(fun(SessRef, S) ->
        source_close(S, SessRef)
    end, State, maps:keys(Sessions)),
    source_terminate(State2, Reason),
    ok.


%--- Internal ------------------------------------------------------------------

start_loading(State, Url, Path, From) ->
    case get_session(State, Url) of
        {error, Reason} ->
            {error, Reason, State};
        {ok, SessRef, State2} ->
            case source_stream(State2, SessRef, Path, #{}) of
                {error, Reason} ->
                    {error, Reason, del_session_if(State2, SessRef, 1)};
                {data, Data, State3} ->
                    gen_server:reply(From, {ok, Data}),
                    {ok, del_session_if(State3, SessRef, 1)};
                {stream, StreamRef, State3} ->
                    Load = #load{sess = SessRef, from = From, data = []},
                    {ok, add_stream(State3, SessRef, StreamRef, Load)}
            end
    end.

start_streaming(State, Url, Path, SinkMod, SinkParams) ->
    case get_session(State, Url) of
        {error, Reason} ->
            {error, Reason, State};
        {ok, SessRef, State2} ->
            case source_stream(State2, SessRef, Path, #{}) of
                {error, Reason} ->
                    {error, Reason, del_session_if(State2, SessRef, 1)};
                {data, Data, State3} ->
                    TempRef = make_ref(),
                    SinkMod:sink_done(TempRef, SinkParams, Data),
                    {ok, TempRef, State3};
                {stream, StreamRef, State3} ->
                    Stream = #stream{sess = SessRef, mod = SinkMod,
                                     params = SinkParams},
                    State2 = add_stream(State3, SessRef, StreamRef, Stream),
                    {ok, StreamRef, State2}
            end
    end.

cancel_stream(#state{streams = StreamMap} = State, StreamRef) ->
    case maps:find(StreamRef, StreamMap) of
        error -> State;
        {ok, #stream{mod = SinkMod, params = SinkParams}} ->
            SinkMod:sink_error(StreamRef, SinkParams, cancelled),
            del_stream(source_cancel(State, StreamRef), StreamRef)
    end.

handle_message(#state{streams = StreamMap} = State, Msg) ->
    case source_handle(State, Msg) of
        pass -> pass;
        {ok, _State2} = Result -> Result;
        {stream_error, StreamRef, Reason} ->
            notify_stream_error(State, StreamRef, Reason),
            {ok, del_stream(State, StreamRef)};
        {session_error, SessRef, Reason} ->
            notify_session_error(State, SessRef, Reason),
            {ok, del_session(State, SessRef)};
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

notify_session_error(#state{sessions = SessMap, streams = StreamMap},
                     SessRef, Reason) ->
    case maps:find(SessRef, SessMap) of
        error ->
            ?LOG_WARNING("Error for unknown session ~w: ~p",
                         [SessRef, Reason]),
            ok;
        {ok, #sess{}} ->
            lists:foreach(fun
                ({_, #load{sess = S, from = From}}) when S =:= SessRef ->
                    gen_server:reply(From, {error, Reason});
                ({StreamRef, #stream{sess = S, mod = SinkMod, params = SinkParams}})
                  when S =:= SessRef ->
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

get_session(#state{urls = UrlMap, sessions = SessMap} = State, Url) ->
    case maps:find(Url, UrlMap) of
        {ok, SessRef} ->
            {ok, SessRef, State};
        error ->
            case source_open(State, Url, #{}) of
                {error, _Reason} = Error -> Error;
                {ok, SessRef, State2} ->
                    Sess = #sess{url = Url, refcount = 0},
                    SessMap2 = SessMap#{SessRef => Sess},
                    UrlMap2 = UrlMap#{Url => SessRef},
                    State3 = State2#state{urls = UrlMap2, sessions = SessMap2},
                    {ok, SessRef, State3}
            end
    end.

del_session(#state{streams = StreamMap} = State, SessRef) ->
    Refs = lists:foldl(fun
        ({X, #load{sess = R}}, Acc) when R =:= SessRef -> [X | Acc];
        ({X, #stream{sess = R}}, Acc) when R =:= SessRef -> [X | Acc]
    end, [], maps:to_list(StreamMap)),
    State2 = lists:foldl(fun(StreamRef, S) ->
            del_stream(S, StreamRef)
        end, State, Refs),
    % Ensure the session is closed even if something went wrong between
    % a session is opened and a stream is started
    del_session_if(State2, SessRef, infinity).

% Remove a session if the refcount is smaller or equal to given count
del_session_if(#state{urls = UrlMap, sessions = SessMap} = State,
               SessRef, MinRefCount) ->
    case maps:find(SessRef, SessMap) of
        error -> State;
        {ok, #sess{url = Url, refcount = RefCount}}
          when MinRefCount =:= infinity; RefCount =< MinRefCount ->
            State2 = source_close(State, SessRef),
            SessMap2 = maps:remove(SessRef, SessMap),
            UrlMap2 = maps:remove(Url, UrlMap),
            State2#state{urls = UrlMap2, sessions = SessMap2}
    end.

add_stream(#state{sessions = SessMap, streams = StreamMap} = State,
           SessRef, StreamRef, StreamData) ->
    #sess{refcount = RefCount} = Sess = maps:get(SessRef, SessMap),
    error = maps:find(StreamRef, StreamMap),
    StreamMap2 = StreamMap#{StreamRef => StreamData},
    Sess2 = Sess#sess{refcount = RefCount + 1},
    SessMap2 = SessMap#{SessRef => Sess2},
    State#state{sessions = SessMap2, streams = StreamMap2}.

del_stream(#state{streams = StreamMap} = State, StreamRef) ->
    case maps:take(StreamRef, StreamMap) of
        error -> State;
        {#load{sess = R}, M} -> del_session_if(State#state{streams = M}, R, 1);
        {#stream{sess = R}, M} -> del_session_if(State#state{streams = M}, R, 1)
    end.


%--- Source Handling Functions

source_init(#state{source = undefined} = State, {Mod, Opts})
  when is_atom(Mod), is_map(Opts) ->
    case Mod:source_init(Opts) of
        {error, _Reason} = Error -> Error;
        {ok, Sub} -> {ok, State#state{source = {Mod, Sub}}}
    end;
source_init(#state{source = undefined}, _Any) ->
    {error, bad_backend}.

source_open(#state{source = {Mod, Sub}} = State, Url, Opts) ->
    case Mod:source_open(Sub, Url, Opts) of
        {error, _Reason} = Error -> Error;
        {ok, SessRef, Sub2} -> {ok, SessRef, State#state{source = {Mod, Sub2}}}
    end.

source_stream(#state{source = {Mod, Sub}} = State, SessRef, Path, Opts) ->
    case Mod:source_stream(Sub, SessRef, Path, Opts) of
        {error, Reason} ->
            {error, Reason};
        {data, Data, Sub2} ->
            {data, Data, State#state{source = {Mod, Sub2}}};
        {stream, StreamRef, Sub2} ->
            {stream, StreamRef, State#state{source = {Mod, Sub2}}}
    end.

source_cancel(#state{source = {Mod, Sub}} = State, StreamRef) ->
    State#state{source = {Mod, Mod:source_cancel(Sub, StreamRef)}}.

source_handle(#state{source = {Mod, Sub}} = State, Msg) ->
    case Mod:source_handle(Sub, Msg) of
        pass ->
            pass;
        {ok, Sub2} ->
            {ok, State#state{source = {Mod, Sub2}}};
        {stream_error, _StreamRef, _Reason} = Error ->
            Error;
        {session_error, _SessRef, _Reason} = Error ->
            Error;
        {data, StreamRef, Data, Sub2} ->
            {data, StreamRef, Data, State#state{source = {Mod, Sub2}}};
        {done, StreamRef, Data, Sub2} ->
            {done, StreamRef, Data, State#state{source = {Mod, Sub2}}}
    end.

source_close(#state{source = {Mod, Sub}} = State, SessRef) ->
    State#state{source = {Mod, Mod:source_close(Sub, SessRef)}}.

source_terminate(#state{source = {Mod, Sub}}, Reason) ->
    Mod:source_terminate(Sub, Reason).
