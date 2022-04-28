-module(grisp_updater_http).

-behaviour(grisp_updater_source).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").


%--- Types ---------------------------------------------------------------------

-type method() :: get | head | options | patch | post | put | delete.


%--- Behaviour Definition ------------------------------------------------------

-callback http_init(Options :: map()) ->
    {ok, State :: term()} | {error, REason :: term()}.

-callback http_connection_options(State :: term(), Url :: binary()) ->
    {ok, Host :: inet:hostname() | inet:ip_address(),
         Port :: inet:port_number(),
         Opts :: gun:opts(),
         State :: term()}
  | not_supported | {error, term()}.

-callback http_request_options(State :: term(), Method :: method(),
                               Url :: binary(), Path :: binary()) ->
    {ok, Path :: binary(), Headers :: [{binary(), binary()}], State :: term()}
  | {error, term()}.

-optional_callbacks([
    http_connection_options/2,
    http_request_options/4
]).


%--- Exports -------------------------------------------------------------------

% Utility functions
-export([join_http_path/2]).

% Behaviour grisp_updater_source callbacks
-export([source_init/1]).
-export([source_open/3]).
-export([source_stream/4]).
-export([source_cancel/3]).
-export([source_handle/2]).
-export([source_close/2]).
-export([source_terminate/2]).


%--- Records -------------------------------------------------------------------

-record(conn, {
    ref :: reference(),
    url :: binary(),
    pid :: pid() | undefined,
    mon :: reference() | undefined,
    proto :: atom() | undefined
}).

-record(state, {
    callbacks :: {module(), term()} | undefined,
    connections = #{} :: #{pid() => #conn{}}
}).


%--- Macros --------------------------------------------------------------------

-define(CONNECTION_TIMEOUT, 5000).


%--- Utility Functions ---------------------------------------------------------

join_http_path(Base, Path) ->
    FixedBase = case re:run(Base, "^\(.*[^/]\)/*$",
                            [{capture, all_but_first, binary}]) of
        nomatch -> <<"">>;
        {match, [TrimmedBase]} -> TrimmedBase
    end,
    FixedPath = case re:run(Path, "^\/*([^/].*\)$",
                            [{capture, all_but_first, binary}]) of
        nomatch -> <<"">>;
        {match, [TrimmedPath]} -> TrimmedPath
    end,
    <<FixedBase/binary, $/, FixedPath/binary>>.


%--- Behaviour grisp_updater_source Callbacks ----------------------------------

source_init(Opts) ->
    ?LOG_INFO("Initializing HTTP update source", []),
    case maps:find(backend, Opts) of
        error -> {ok, #state{}};
        {ok, BackendDef} -> http_init(#state{}, BackendDef)
    end.

source_open(State, Url, _Opts) ->
    case http_connection_options(State, Url) of
        not_supported -> not_supported;
        {error, _Reason} = Error -> Error;
        {ok, Host2, Port2, Opts, State2} ->
            Conn = #conn{ref = make_ref(), url = Url},
            gun_connect(State2, Host2, Port2, Opts, Conn)
    end.

gun_connect(#state{connections = ConnMap} = State, Host, Port, Opts,
            #conn{pid = undefined, ref = _Ref} = Conn) ->
    case gun:open(Host, Port, Opts) of
        {error, _Reason} = Error -> Error;
        {ok, ConnPid} ->
            MonRef = monitor(process, ConnPid),
            case gun:await_up(ConnPid, ?CONNECTION_TIMEOUT, MonRef) of
                {error, _Reason} = Error -> Error;
                {ok, Protocol} ->
                    Conn2 = Conn#conn{
                        pid = ConnPid,
                        mon = MonRef,
                        proto = Protocol
                    },
                    ConnMap2 = ConnMap#{ConnPid => Conn2},
                    {ok, ConnPid, State#state{connections = ConnMap2}}
            end
    end.

source_stream(#state{connections = ConnMap} = State, ConnPid, Path, _Opts) ->
    case maps:find(ConnPid, ConnMap) of
        error -> {error, unknown_source};
        {ok, #conn{url = Url}} ->
            case http_request_options(State, get, Url, Path) of
                {error, _Reason} = Error -> Error;
                {ok, ReqPath, Headers, State2} ->
                    StreamRef = gun:get(ConnPid, ReqPath, Headers, #{}),
                    {stream, StreamRef, State2}
            end
    end.

source_cancel(State, ConnPid, StreamRef) ->
    gun:cancel(ConnPid, StreamRef),
    State.

source_handle(#state{connections = ConnMap} = State,
              {gun_push, ConnPid, _OriginalStreamRef, _PushedStreamRef,
               _Method, _Host, _Path, _Headers}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} -> {ok, State}
    end;
source_handle(#state{connections = ConnMap} = State,
              {gun_response, ConnPid, StreamRef, fin, Status, _Headers})
  when Status >= 200, Status < 300 ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} -> {done, StreamRef, <<>>, State}
    end;
source_handle(#state{connections = ConnMap} = State,
              {gun_response, ConnPid, _StreamRef, nofin, Status, _Headers})
  when Status >= 200, Status < 300 ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} -> {ok, State}
    end;
source_handle(#state{connections = ConnMap} = State,
              {gun_response, ConnPid, StreamRef, fin, Status, _Headers}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} ->
            {stream_error, [StreamRef], {http_error, Status}, State}
    end;
source_handle(#state{connections = ConnMap} = State,
              {gun_response, ConnPid, StreamRef, nofin, Status, _Headers}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} ->
            gun:cancel(ConnPid, StreamRef),
            gun:flush(ConnPid, StreamRef),
            {stream_error, [StreamRef], {http_error, Status}, State}
    end;
source_handle(#state{connections = ConnMap} = State,
              {gun_trailers, ConnPid, _StreamRef, _Headers}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} ->
            {ok, State}
    end;
source_handle(#state{connections = ConnMap} = State,
              {gun_inform, ConnPid, _StreamRef, _Status, _Headers}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} ->
            {ok, State}
    end;

source_handle(#state{connections = ConnMap} = State,
              {gun_data, ConnPid, StreamRef, nofin, Data}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} ->
            {data, StreamRef, Data, State}
    end;
source_handle(#state{connections = ConnMap} = State,
              {gun_data, ConnPid, StreamRef, fin, Data}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} ->
            {done, StreamRef, Data, State}
    end;

source_handle(#state{connections = ConnMap} = State,
              {gun_error, ConnPid, StreamRef, Reason}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} ->
            {stream_error, [StreamRef], Reason, State}
    end;
source_handle(#state{connections = ConnMap} = State,
              {'DOWN', MonRef, process, ConnPid, Reason}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{mon = MonRef}} ->
            {source_error, ConnPid, Reason, State}
    end;
source_handle(#state{connections = ConnMap} = State,
              {gun_down, ConnPid, _Protocol, Reason,
               _KilledStreams, _UnprocessedStreams}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} ->
            State2 = close_connection(State, ConnPid),
            {source_error, ConnPid, Reason, State2}
    end;
source_handle(#state{connections = ConnMap} = State,
              {gun_up, ConnPid, _Protocol}) ->
    case maps:find(ConnPid, ConnMap) of
        error -> pass;
        {ok, #conn{}} ->
            {ok, State}
    end;
source_handle(_State, _Msg) ->
    pass.

source_close(State, ConnPid) ->
    close_connection(State, ConnPid).

source_terminate(#state{connections = ConnMap} = State, _Reason) ->
    ?LOG_INFO("Terminating HTTP update source", []),
    lists:foldl(fun(ConnPid, S) ->
        close_connection(S, ConnPid)
    end, State, maps:keys(ConnMap)),
    ok.


%--- Internal Function ---------------------------------------------------------

close_connection(#state{connections = ConnMap} = State, ConnPid) ->
    case maps:take(ConnPid, ConnMap) of
        error -> State;
        {#conn{mon = MonRef}, ConnMap2} ->
            erlang:demonitor(MonRef, [flush]),
            gun:close(ConnPid),
            gun:flush(ConnPid),
            State#state{connections = ConnMap2}
    end.


%--- Callback Handling Functions

http_init(#state{callbacks = undefined} = State, {Mod, Opts}) ->
    case Mod:http_init(Opts) of
        {ok, Sub} -> {ok, State#state{callbacks = {Mod, Sub}}};
        {error, _Reason} = Error -> Error
    end.

http_connection_options(#state{callbacks = undefined} = State, Url) ->
    http_connection_options_default(State, Url);
http_connection_options(#state{callbacks = {Mod, Sub}} = State, Url) ->
    try Mod:http_connection_options(Sub, Url) of
        {error, _Reason} = Error -> Error;
        {ok, Host2, Port2, Opts, Sub2} ->
            {ok, Host2, Port2, Opts, State#state{callbacks = {Mod, Sub2}}}
    catch
        error:undef ->
            http_connection_options_default(State, Url)
    end.

http_connection_options_default(State, Url) ->
    case uri_string:parse(Url) of
        #{scheme := <<"https">>, host := Host} = Parts ->
            Hostname = unicode:characters_to_list(Host),
            Port = maps:get(port, Parts, 443),
            {ok, Hostname, Port, #{transport => tls}, State};
        #{scheme := <<"http">>, host := Host} = Parts ->
            Hostname = unicode:characters_to_list(Host),
            Port = maps:get(port, Parts, 80),
            {ok, Hostname, Port, #{}, State};
        _ ->
            not_supported
    end.

http_request_options(#state{callbacks = undefined} = State,
                     Method, Url, Path) ->
    http_request_options_default(State, Method, Url, Path);
http_request_options(#state{callbacks = {Mod, Sub}} = State,
                     Method, Url, Path) ->
    try Mod:http_request_options(Sub, Method, Url, Path) of
        {error, _Reason} = Error -> Error;
        {ok, Path2, Headers, Sub2} ->
            {ok, Path2, Headers, State#state{callbacks = {Mod, Sub2}}}
    catch
        error:undef ->
            http_request_options_default(State, Method, Url, Path)
    end.

http_request_options_default(State, _Method, Url, Path) ->
    #{path := Base} = uri_string:parse(Url),
    {ok, join_http_path(Base, Path), [], State}.
