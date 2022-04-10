-module(grisp_updater_tarball).

-behaviour(grisp_updater_source).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").


%--- Exports -------------------------------------------------------------------

% Behaviour grisp_updater_source callbacks
-export([source_init/1]).
-export([source_open/3]).
-export([source_stream/4]).
-export([source_cancel/2]).
-export([source_handle/2]).
-export([source_close/2]).
-export([source_terminate/2]).


%--- Records -------------------------------------------------------------------

-record(state, {
    files = #{} :: #{reference() => binary()}
}).


%--- Behaviour grisp_updater_source Callbacks ----------------------------------

source_init(_Opts) ->
    ?LOG_INFO("Initializing tarball update source", []),
    {ok, #state{}}.

source_open(#state{files = Files} = State, Url, _Opts) ->
    case filelib:is_regular(Url) of
        false ->
            {error, {tarball_not_found, Url}};
        true ->
            SessRef = make_ref(),
            {ok, SessRef, State#state{files = Files#{SessRef => Url}}}
    end.

source_stream(#state{files = Files} = State, SessRef, Path, _Opts) ->
    case maps:find(SessRef, Files) of
        error -> {error, unknown_session};
        {ok, Url} ->
            Filename = tarball_path(Path),
            case erl_tar:extract(Url, [memory, {files, [Filename]}]) of
                {ok,[{Filename, Data}]} -> {data, Data, State};
                {error, {_, enoent}} -> {error, {tarball_not_found, Url}};
                {error, _Reason} = Error -> Error
            end
    end.

source_cancel(State, _StreamRef) ->
    State.

source_handle(_State, _Msg) ->
    pass.

source_close(#state{files = Files} = State, SessRef) ->
    State#state{files = maps:remove(SessRef, Files)}.

source_terminate(_State, _Reason) ->
    ?LOG_INFO("Terminating tarball update source", []),
    ok.


%--- Internal Function ---------------------------------------------------------

tarball_path(Path) when is_list(Path) ->
    filename:join(".", Path);
tarball_path(Path) when is_binary(Path) ->
    filename:join(".", unicode:characters_to_list(Path)).
