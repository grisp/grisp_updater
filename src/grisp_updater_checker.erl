-module(grisp_updater_checker).

-behavior(gen_server).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").

-include("grisp_updater.hrl").


%--- Exports -------------------------------------------------------------------

% API
-export([start_link/1]).
-export([schedule_check/2]).
-export([cancel_check/1]).
-export([abort/0]).


% Callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).


%--- Records -------------------------------------------------------------------

-record(check, {
    block :: #block{},
    target :: #target{}
}).

-record(state, {
    pending = #{} :: #{non_neg_integer() => #check{}},
    schedule = queue:new() :: queue:queue()
}).


%--- Macros --------------------------------------------------------------------

-define(TIMEOUT, 10).


%--- API Functions -------------------------------------------------------------

start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

schedule_check(Block, Target) ->
    gen_server:cast(?MODULE, {schedule, Block, Target}).

cancel_check(BlockId) ->
    gen_server:call(?MODULE, {cancel, BlockId}).

abort() ->
    gen_server:call(?MODULE, abort).


%--- Callbacks -----------------------------------------------------------------

init(_Opts) ->
    ?LOG_INFO("Starting GRiSP block checker..."),
    {ok, #state{}}.

handle_call(abort, _From, State) ->
    {reply, ok, State#state{pending = #{}, schedule = queue:new()}};
handle_call({cancel, BlockId}, _From, #state{pending = Map} = State) ->
    State2 = State#state{pending = maps:remove(BlockId, Map)},
    {reply, ok, State2, timeout(State2)};
handle_call(Request, From, State) ->
    ?LOG_WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {reply, {error, unexpected_call}, State, timeout(State)}.

handle_cast({schedule, #block{id = Id} = Block, Target},
            #state{pending = M, schedule = Q} = State) ->
    Check = #check{block = Block, target = Target},
    case maps:find(Id, M) of
        {ok, _} ->
            grisp_updater_manager:checker_error(Id, already_scheduled),
            {noreply, State, timeout(State)};
        error ->
            M2 = M#{Id => Check},
            Q2 = queue:in(Id, Q),
            State2 = State#state{pending = M2, schedule = Q2},
            {noreply, State2, timeout(State2)}
    end;
handle_cast(Request, State) ->
    ?LOG_WARNING("Unexpected XXXX cast: ~p", [Request]),
    {noreply, State, timeout(State)}.

handle_info(timeout, #state{pending = M, schedule = Q} = State) ->
    FinalState = case queue:out(Q) of
        {empty, Q2} -> State#state{schedule = Q2};
        {{value, Id}, Q2} ->
            case maps:take(Id, M) of
                error -> State#state{schedule = Q2};
                {Check, M2} ->
                    State2 = State#state{pending = M2, schedule = Q2},
                    do_check(State2, Check)
            end
    end,
    {noreply, FinalState, timeout(FinalState)};
handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected message: ~p", [Info]),
    {noreply, State, timeout(State)}.


%--- Internal ------------------------------------------------------------------

timeout(#state{pending = M}) when map_size(M) > 0 -> ?TIMEOUT;
timeout(_State) -> infinity.

do_check(State, Check) ->
    #check{
        block = #block{
            id = Id,
            data_offset = DataOffset,
            data_size = DataSize,
            data_crc = ExpectedCrc
        },
        target = #target{device = Device, offset = DeviceOffset}
    } = Check,
    ?LOG_DEBUG("Checking block ~b [~b+~b=~b:~b] from ~s",
               [Id, DeviceOffset, DataOffset,
                DeviceOffset + DataOffset, DataSize, Device]),
    Offset = DeviceOffset + DataOffset,
    %TODO: Mabe do some device boundary checks ?
    case grisp_updater_storage:digest(crc32, Device, Offset, DataSize) of
        {error, eof} ->
            % Needed to check files that may be smaller than they updated version
            %TODO: Maybe only allow that for regular files, not for devices
            ?LOG_DEBUG("Block ~b check error: eof", [Id]),
            grisp_updater_manager:checker_done(Id, false),
            State;
        {error, Reason} ->
            ?LOG_DEBUG("Block ~b check error: ~w", [Id, Reason]),
            grisp_updater_manager:checker_error(Id, Reason),
            State;
        {ok, ExpectedCrc} ->
            ?LOG_DEBUG("Block ~b check passed (~b)", [Id, ExpectedCrc]),
            grisp_updater_manager:checker_done(Id, true),
            State;
        {ok, BlockCrc} ->
            ?LOG_DEBUG("Block ~b check failed, got ~b and expecting ~b",
                       [Id, BlockCrc, ExpectedCrc]),
            grisp_updater_manager:checker_done(Id, false),
            State
    end.
