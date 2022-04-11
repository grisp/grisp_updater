-module(grisp_updater_progress).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").


%--- Types ---------------------------------------------------------------------

-type statistics() :: #{
    start_time := non_neg_integer(),
    blocks_total := non_neg_integer(),
    blocks_checked := non_neg_integer(),
    blocks_loading := non_neg_integer(),
    blocks_loaded := non_neg_integer(),
    blocks_retries := non_neg_integer(),
    blocks_written := non_neg_integer(),
    data_total := non_neg_integer(),
    data_checked := non_neg_integer(),
    data_loaded := non_neg_integer(),
    data_skipped := non_neg_integer(),
    data_written := non_neg_integer()
}.

-export_type([statistics/0]).


%--- Behaviour Definition ------------------------------------------------------

-callback progress_init(Opts :: map()) ->
    {ok, State :: term()} | {error, term()}.
-callback progress_update(State :: term(), Statistics :: statistics()) ->
    {ok, State :: term()}.
-callback progress_warning(State :: term(), Reason :: term(), Msg :: binary()) ->
    {ok, State :: term()}.
-callback progress_error(State :: term(), Statistics :: statistics(),
                         Reason :: term(), Msg :: binary()) ->
    ok.
-callback progress_done(State :: term(), Statistics :: statistics()) ->
    ok.


%--- Exports -------------------------------------------------------------------

-export([options/0]).
-export([wait/2]).

% Behaviour grisp_updater_progress callbacks
-export([progress_init/1]).
-export([progress_update/2]).
-export([progress_warning/3]).
-export([progress_error/3]).
-export([progress_done/2]).


%--- records -------------------------------------------------------------------

-record(state, {
        caller :: pid() | undefined,
        ref :: reference() | undefined,
        last_log :: undefined | integer()
}).


%--- API Functions -------------------------------------------------------------

options() ->
    #{caller => self(), ref => make_ref()}.

wait(Proc, #{ref := Ref}) ->
    MonRef = erlang:monitor(process, Proc),
    receive
        {'DOWN', MonRef, process, _, Reason} -> {error, Reason};
        {done, Ref} ->
            erlang:demonitor(MonRef, [flush]),
            ok;
        {error, Ref, Reason} ->
            erlang:demonitor(MonRef, [flush]),
            {error, Reason}
    end.


%--- Behavior grisp_updater_progress Callback ----------------------------------

progress_init(Opts) ->
    {ok, #state{
        caller = maps:get(caller, Opts, undefined),
        ref = maps:get(ref, Opts, undefined),
        last_log = erlang:system_time(millisecond)
    }}.

progress_update(#state{last_log = LastLog} = State, Stats) ->
    case (erlang:system_time(millisecond) - LastLog) > 1000 of
        false -> {ok, State};
        true ->
            ?LOG_INFO("Update progress: ~b%", [progress_percent(Stats)]),
            {ok, #state{last_log = erlang:system_time(millisecond)}}
    end.

progress_warning(State, Msg, Reason) ->
    ?LOG_WARNING("Update warning; ~s: ~p", [Msg, Reason]),
    {ok, State}.

progress_error(#state{caller = Caller, ref = Ref}, Stats, Reason) ->
    ?LOG_ERROR("Update failed after ~b% : ~p",
               [progress_percent(Stats), Reason]),
    Caller ! {error, Ref, Reason},
    ok.

progress_done(#state{caller = Caller, ref = Ref}, _Stats) ->
    ?LOG_INFO("Update done", []),
    Caller ! {done, Ref},
    ok.


%--- Internal Functions --------------------------------------------------------

progress_percent(Stats) ->
    #{data_total := Total, data_checked := Checked,
      data_skipped := Skipped, data_written := Written} = Stats,
    (Checked + Skipped + Written) * 100 div (Total * 2).
