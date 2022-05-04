-module(grisp_updater_manager).

-behavior(gen_statem).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").

-include("grisp_updater.hrl").


%--- Exports -------------------------------------------------------------------

% API Functions
-export([start_link/1]).
-export([get_status/0]).
-export([update/2]).
-export([start_update/4]).
-export([cancel_update/0]).
-export([validate/0]).

% Internal callbacks
-export([checker_done/2]).
-export([checker_error/2]).
-export([loader_done/1]).
-export([loader_failed/2]).
-export([loader_error/2]).

% Behaviour gen_statm callbacks
-export([callback_mode/0]).
-export([init/1]).
-export([ready/3]).
-export([updating/3]).
-export([terminate/3]).


%--- Types -------------------------------------------------------------------

-type update_status() :: ready | updating.

-export_type([update_status/0]).


%--- Records -------------------------------------------------------------------

-record(pending, {
    status :: checking | loading,
    target :: #target{},
    block :: #block{},
    retry = 0 :: non_neg_integer()
}).

-record(update, {
    url :: binary(),
    progress :: undefined | {module(), term()},
    manifest :: undefined | term(),
    stats :: undefined | grisp_updater_progress:statistics(),
    system_id :: undefined | non_neg_integer(),
    system_target :: undefined | target(),
    objects :: undefined | [#object{}],
    pending :: undefined | #{integer() => #pending{}}
}).

-record(data, {
    system :: undefined | {Mod :: module(), Sub :: term()},
    update :: undefined | #update{}
}).


%--- API Functions -------------------------------------------------------------

start_link(Opts) ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, Opts, []).

get_status() ->
    gen_statem:call(?MODULE, get_status).

update(Url, Opts) ->
    ProgressOpts = grisp_updater_progress:options(),
    Msg = {start_update, Url, grisp_updater_progress, ProgressOpts, Opts},
    case gen_statem:call(?MODULE, Msg, infinity) of
        {error, _Reason} = Error -> Error;
        ok -> grisp_updater_progress:wait(?MODULE, ProgressOpts)
    end.

start_update(Url, Callbacks, Params, Opts) ->
    gen_statem:call(?MODULE, {start_update, Url, Callbacks, Params, Opts}).

cancel_update() ->
    gen_statem:call(?MODULE, cancel_update).

validate() ->
    gen_statem:call(?MODULE, validate).


%--- Internal Callback Functions -----------------------------------------------

checker_done(BlockId, Outcome) ->
    gen_statem:cast(?MODULE, {checker_done, BlockId, Outcome}).

checker_error(BlockId, Reason) ->
    gen_statem:cast(?MODULE, {checker_error, BlockId, Reason}).

loader_done(BlockId) ->
    gen_statem:cast(?MODULE, {loader_done, BlockId}).

loader_failed(BlockId, Reason) ->
    gen_statem:cast(?MODULE, {loader_failed, BlockId, Reason}).

loader_error(BlockId, Reason) ->
    gen_statem:cast(?MODULE, {loader_error, BlockId, Reason}).


%--- Behaviour gen_statem Callbacks --------------------------------------------

callback_mode() -> state_functions.

init(#{system := SysOpts}) ->
    ?LOG_INFO("Starting GRiSP update manager..."),
    case system_init(#data{}, SysOpts) of
        {error, _Reason} = Error -> Error;
        {ok, Data} -> {ok, ready, Data, []}
    end.

ready({call, From}, {start_update, Url, Callbacks, Params, Opts}, Data) ->
    case start_update(Data, Url, Callbacks, Params, Opts) of
        {done, Data2} ->
            {keep_state, Data2, [{reply, From, ok}]};
        {ok, Data2} ->
            {next_state, updating, Data2, [{next_event, internal, bootstrap},
                                           {reply, From, ok}]};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;
ready({call, From}, cancel_update, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_updating}}]};
ready({call, From}, validate, Data) ->
    case system_validate(Data) of
        {error, Reason} = Error ->
            ?LOG_ERROR("Error validating running system: ~p", [Reason]),
            {keep_state_and_data, [{reply, From, Error}]};
        {ok, Data2} ->
            ?LOG_INFO("Running system validated", []),
            {keep_state, Data2, [{reply, From, ok}]}
    end;
ready(EventType, Event, Data) ->
    handle_event(EventType, Event, ready, Data).

updating({call, From}, {start_update, _, _, _, _}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, already_updating}}]};
updating({call, From}, cancel_update, _Data) ->
    %TODO: Implemente cancelation
    {keep_state_and_data, [{reply, From, {error, not_implemented}}]};
updating({call, From}, validate, _Data) ->
    {keep_state_and_data, [{reply, From, {error, updating}}]};
updating(cast, {checker_done, BlockId, Outcome}, Data) ->
    case got_checker_done(Data, BlockId, Outcome) of
        {ok, Data2} -> {keep_state, Data2};
        {done, Data2} -> {next_state, ready, Data2}
    end;
updating(cast, {checker_error, BlockId, Reason}, Data) ->
    case got_checker_error(Data, BlockId, Reason) of
        {ok, Data2} -> {keep_state, Data2};
        {done, Data2} -> {next_state, ready, Data2}
    end;
updating(cast, {loader_done, BlockId}, Data) ->
    case got_loader_done(Data, BlockId) of
        {ok, Data2} -> {keep_state, Data2};
        {done, Data2} -> {next_state, ready, Data2};
        {error, _Reason} -> {next_state, ready, Data}
    end;
updating(cast, {loader_failed, BlockId, Reason}, Data) ->
    case got_loader_failed(Data, BlockId, Reason) of
        {ok, Data2} -> {keep_state, Data2}
    end;
updating(cast, {loader_error, BlockId, Reason}, Data) ->
    case got_loader_error(Data, BlockId, Reason) of
        {ok, Data2} -> {keep_state, Data2};
        {done, Data2} -> {next_state, ready, Data2}
    end;
updating(internal, bootstrap, Data) ->
    case bootstrap_object(Data) of
        {ok, Data2} -> {keep_state, Data2, []};
        {error, _Reason} -> {next_state, ready, Data}
    end;
updating(EventType, Event, Data) ->
    handle_event(EventType, Event, updating, Data).

terminate(Reason, _State, Data) ->
    system_terminate(Data, Reason),
    ok.


%--- Internal Functions --------------------------------------------------------

handle_event({call, From}, get_status, State, _Data) ->
    {keep_state_and_data, [{reply, From, State}]};
handle_event({call, From}, Msg, _State, _Data) ->
    ?LOG_WARNING("Unexpected call from ~p: ~p", [Msg]),
    {keep_state_and_data, [{reply, From, {error, unexpected_call}}]};
handle_event(cast, Msg, _State, _Data) ->
    ?LOG_WARNING("Unexpected cast: ~p", [Msg]),
    keep_state_and_data;
handle_event(info, Msg, _State, _Data) ->
    ?LOG_WARNING("Unexpected message: ~p", [Msg]),
    keep_state_and_data.

start_update(Data, Url, Mod, Params, Opts) ->
    case progress_init(#update{url = Url}, Mod, Params) of
        {error, _Reason} = Error -> Error;
        {ok, Up} ->
            Data2 = Data#data{update = Up},
            case grisp_updater_source:load(Url, <<"MANIFEST">>) of
                {error, _Reason} = Error -> Error;
                {ok, Bin} ->
                    case grisp_updater_manifest:parse(Bin, Opts) of
                        {error, _Reason} = Error -> Error;
                        {ok, #manifest{objects = []}} ->
                            update_done(Data2);
                        {ok, Manifest} ->
                            do_start_update(Data2, Manifest)
                    end
            end
    end.

do_start_update(#data{update = Up} = Data,
                #manifest{objects = Objs} = Manifest) ->
    check_structure(Data, Manifest),
    case select_update_target(Data, Manifest) of
        {error, _Reason} = Error -> Error;
        {ok, SysId, SysTarget} ->
            ?LOG_INFO("System selected for update: ~w", [SysId]),
            case system_prepare_update(Data, SysId) of
                {error, _Reason} = Error -> Error;
                {ok, Data2} ->
                    #manifest{block_count = BlockCount,
                              data_size = DataSize} = Manifest,
                    Data3 = Data2#data{
                        update = Up#update{
                            manifest = Manifest,
                            system_id = SysId,
                            system_target = SysTarget,
                            objects = Objs
                        }
                    },
                    {ok, stats_init(Data3, BlockCount, DataSize)}
            end
    end.

check_structure(_Data, _Manifest) ->
    %TODO: validate device partition table ?
    ok.

select_update_target(_Data, #manifest{structure = undefined}) ->
    {error, missing_structure};
select_update_target(Data, Manifest) ->
    case system_get_active(Data) of
        {removable, _} ->
            ?LOG_ERROR("Cannot update from a removable media", []),
            {error, current_system_removable};
        {_, false} ->
            ?LOG_ERROR("Cannot update from a system that is not validated", []),
            {error, current_system_not_validated};
        {CurrSysId, true} ->
            ?LOG_INFO("Current validate system: ~w", [CurrSysId]),
            get_next_system(Data, CurrSysId, Manifest)
    end.



get_next_system(Data, CurrSysId, Manifest) ->
    case system_get_updatable(Data) of
        undefined -> select_next_system(Data, CurrSysId, Manifest);
        {ok, Id, Target} -> {ok, Id, Target};
        {error, _Reason} = Error -> Error
    end.

%TODO: Factorize this code
select_next_system(Data, CurrSysId,
                      #manifest{structure = #mbr{} = Structure}) ->
    #mbr{sector_size = SecSize, partitions = Partitions} = Structure,
    case lists_keysplit(CurrSysId, #mbr_partition.id, Partitions) of
        not_found ->
            ?LOG_ERROR("Current system ~w not found in update package MBR structure",
                       [CurrSysId]),
            {error, current_system_partition_not_found};
        {H, T} ->
            case first_system_partition(T ++ H) of
                not_found ->
                    ?LOG_ERROR("No appropriate system partition found in update package MBR structure", []),
                    {error, update_system_partition_not_found};
                #mbr_partition{id = Id, start = Start, size = Size} ->
                    GlobalTarget = #target{offset = BaseOffset}
                        = system_get_global_target(Data),
                    %TODO: Add some boundary checks
                    Target = GlobalTarget#target{
                        offset = BaseOffset + Start * SecSize,
                        size = Size * SecSize
                    },
                    {ok, Id, Target}
            end
    end;
select_next_system(Data, CurrSysId,
                      #manifest{structure = #gpt{} = Structure}) ->
    #gpt{sector_size = SecSize, partitions = Partitions} = Structure,
    case lists_keysplit(CurrSysId, #gpt_partition.id, Partitions) of
        not_found ->
            ?LOG_ERROR("Current system ~w not found in update package GPT structure",
                       [CurrSysId]),
            {error, current_system_partition_not_found};
        {H, T} ->
            case first_system_partition(T ++ H) of
                not_found ->
                    ?LOG_ERROR("No appropriate system partition found in update package GPT structure", []),
                    {error, update_system_partition_not_found};
                #gpt_partition{id = Id, start = Start, size = Size} ->
                    GlobalTarget = #target{offset = BaseOffset}
                        = system_get_global_target(Data),
                    %TODO: Add some boundary checks
                    Target = GlobalTarget#target{
                        offset = BaseOffset + Start * SecSize,
                        size = Size * SecSize
                    },
                    {ok, Id, Target}
            end
    end.

first_system_partition([]) -> not_found;
first_system_partition([#mbr_partition{role = system, id = Id} = Part | _])
  when Id =/= undefined ->
    Part;
first_system_partition([#gpt_partition{role = system, id = Id} = Part | _])
  when Id =/= undefined ->
    Part;
first_system_partition([_ | Rest]) ->
    first_system_partition(Rest).

bootstrap_object(#data{update = #update{objects = [Obj | _],
                                        system_id = SysId,
                                        system_target = SysTarget,
                                        pending = undefined} = Up} = Data) ->
    ?LOG_INFO("Starting updating ~s", [object_name(Obj)]),
    #object{target = TargetSpec, blocks = Blocks} = Obj,
    case system_prepare_target(Data, SysId, SysTarget, TargetSpec) of
        {ok, ObjTarget} ->
            bootstrap_object(Data, Up, ObjTarget, Blocks);
        {error, Reason} = Error ->
            ?LOG_ERROR("Error while preparing target ~p for system ~b: ~p",
                       [TargetSpec, SysId, Reason]),
            Error
    end.


bootstrap_object(Data, Up, ObjTarget, Blocks) ->
    Pending = lists:foldl(fun(#block{id = Id} = B, Map) ->
        grisp_updater_checker:schedule_check(B, ObjTarget),
        Map#{Id => #pending{status = checking, block = B,
                            target = ObjTarget}}
    end, #{}, Blocks),
    Up2 = Up#update{pending = Pending},
    {ok, Data#data{update = Up2}}.

bootstrap_next_object(#data{update = #update{objects = [Obj],
                                             pending = Pending}} = Data)
  when map_size(Pending) =:= 0 ->
    ?LOG_INFO("Done updating ~s", [object_name(Obj)]),
    update_done(Data);
bootstrap_next_object(#data{update = #update{objects = [Last | Objs],
                                             pending = Pending} = Up} = Data)
  when map_size(Pending) =:= 0 ->
    ?LOG_INFO("Done updating ~s", [object_name(Last)]),
    Data2 = Data#data{update = Up#update{objects = Objs, pending = undefined}},
    bootstrap_object(Data2).

got_checker_done(#data{update = #update{pending = Map} = Up} = Data, BlockId, true) ->
    ?LOG_DEBUG("Block ~b already up to date", [BlockId]),
    case maps:take(BlockId, Map) of
        error ->
            ?LOG_WARNING("Received checker success outcome for unknown block ~w",
                         [BlockId]),
            {ok, Data};
        {#pending{status = checking, block = Block}, Map2} ->
            Data2 = Data#data{update = Up#update{pending = Map2}},
            Data3 = stats_block_checked(Data2, Block, false),
            case map_size(Map2) of
                0 -> bootstrap_next_object(Data3);
                _ -> {ok, Data3}
            end;
        {#pending{status = Status}, Map2} ->
            ?LOG_WARNING("Received checker success outcome for unexpected block ~w currently ~w",
                         [BlockId, Status]),
            Up2 = Up#update{pending = Map2},
            {ok, Data#data{update = Up2}}
    end;
got_checker_done(#data{update = Up} = Data, BlockId, false) ->
    ?LOG_DEBUG("Block ~b checked and need update", [BlockId]),
    #update{url = Url, pending = Map} = Up,
    case maps:find(BlockId, Map) of
        error ->
            ?LOG_WARNING("Received checker failed outcome for unknown block ~w",
                         [BlockId]),
            {ok, Data};
        {ok, #pending{status = checking} = Pending} ->
            #pending{target = Target, block = Block} = Pending,
            Pending2 = Pending#pending{status = loading},
            Map2 = Map#{BlockId := Pending2},
            grisp_updater_loader:schedule_load(Url, Block, Target),
            Data2 = Data#data{update = Up#update{pending = Map2}},
            {ok, stats_block_checked(Data2, Block, true)};
        {ok, #pending{status = Status}} ->
            ?LOG_WARNING("Received checker failed outcome for unexpected block ~w currently ~w",
                         [BlockId, Status]),
            {ok, Data}
    end.

got_checker_error(#data{update = #update{pending = Map}} = Data, BlockId, Reason) ->
    ?LOG_DEBUG("Block ~b check error: ~p", [BlockId, Reason]),
    case maps:find(BlockId, Map) of
        error ->
            ?LOG_WARNING("Received checker error for unknown block ~w",
                         [BlockId]),
            {ok, Data};
        {ok, #pending{status = checking, block = Block}} ->
            Data2 = stats_block_checked(Data, Block, false),
            update_failed(Data2, Reason);
        {ok, #pending{status = Status}} ->
            ?LOG_WARNING("Received checker error for unexpected block ~w currently ~w",
                         [BlockId, Status]),
            {ok, Data}
    end.

got_loader_done(#data{update = #update{pending = Map} = Up} = Data, BlockId) ->
    ?LOG_DEBUG("Block ~b loaded and written", [BlockId]),
    case maps:take(BlockId, Map) of
        error ->
            ?LOG_WARNING("Received loader outcome for unknown block ~w",
                         [BlockId]),
            {ok, Data};
        {#pending{status = loading, block = Block}, Map2} ->
            Data2 = Data#data{update = Up#update{pending = Map2}},
            Data3 = stats_block_loaded(Data2, Block),
            case map_size(Map2) of
                0 -> bootstrap_next_object(Data3);
                _ -> {ok, Data3}
            end;
        {#pending{status = Status}, Map2} ->
            ?LOG_WARNING("Received loader outcome for unexpected block ~w currently ~w",
                         [BlockId, Status]),
            Up2 = Up#update{pending = Map2},
            {ok, Data#data{update = Up2}}
    end.

got_loader_failed(#data{update = Up} = Data, BlockId, Reason) ->
    ?LOG_DEBUG("Block ~b loading failed: ~p", [BlockId, Reason]),
    #update{url = Url, pending = Map} = Up,
    case maps:find(BlockId, Map) of
        error ->
            ?LOG_WARNING("Received loader error for unknown block ~w",
                         [BlockId]),
            {ok, Data};
        {ok, #pending{status = loading, retry = Retry} = Pending} ->
            #pending{block = Block, target = Target} = Pending,
            Pending2 = Pending#pending{retry = Retry + 1},
            Map2 = Map#{BlockId := Pending2},
            Data2 = Data#data{update = Up#update{pending = Map2}},
            grisp_updater_loader:schedule_load(Url, Block, Target),
            {ok, stats_block_retried(Data2)};
        {ok, #pending{status = Status}} ->
            ?LOG_WARNING("Received loader error for unexpected block ~w currently ~w",
                         [BlockId, Status]),
            {ok, Data}
    end.

got_loader_error(#data{update = #update{pending = Map}} = Data, BlockId, Reason) ->
    ?LOG_DEBUG("Block ~b loading failed: ~p", [BlockId, Reason]),
    case maps:find(BlockId, Map) of
        error ->
            ?LOG_WARNING("Received loader error for unknown block ~w",
                         [BlockId]),
            {ok, Data};
        {ok, #pending{status = loading}} ->
            update_failed(Data, Reason);
        {ok, #pending{status = Status}} ->
            ?LOG_WARNING("Received loader error for unexpected block ~w currently ~w",
                         [BlockId, Status]),
            {ok, Data}
    end.

stats_init(#data{update = #update{} = Up} = Data, BlockCount, TotalSize) ->
    Stats = #{
        start_time => os:system_time(millisecond),
        blocks_total => BlockCount,
        blocks_checked => 0,
        blocks_loading => 0,
        blocks_loaded => 0,
        blocks_retries => 0,
        blocks_written => 0,
        data_total => TotalSize,
        data_checked => 0,
        data_loaded => 0,
        data_skipped => 0,
        data_written => 0
    },
    Data#data{update = Up#update{stats = Stats}}.

stats_block_checked(#data{update = #update{stats = Stats} = Up} = Data,
                    #block{data_size = Size}, Loading) ->
    #{blocks_checked := Bc, data_checked := Dc,
      blocks_loading := Bl, data_skipped := Ds} = Stats,
    Stats2 = Stats#{blocks_checked := Bc + 1, data_checked := Dc + Size},
    Stats3 = case Loading of
        true -> Stats2#{blocks_loading := Bl + 1};
        false -> Stats2#{data_skipped := Ds + Size}
    end,
    Up2 = Up#update{stats = Stats3},
    progress_update(Up2, Stats3),
    Data#data{update = Up2}.

stats_block_loaded(#data{update = #update{stats = Stats} = Up} = Data,
                   #block{data_size = DataSize, encoding = Encoding}) ->
    #{blocks_loaded := Bl, blocks_written := Bw,
      data_loaded := Dl, data_written := Dw} = Stats,
    LoadedSize = case Encoding of
        #gzip_encoding{block_size = BlockSize} -> BlockSize;
        #raw_encoding{} -> DataSize
    end,
    Stats2 = Stats#{
        blocks_loaded := Bl + 1,
        blocks_written := Bw + 1,
        data_loaded := Dl + LoadedSize,
        data_written := Dw + DataSize
    },
    Up2 = Up#update{stats = Stats2},
    progress_update(Up2, Stats2),
    Data#data{update = Up2}.

stats_block_retried(#data{update = #update{stats = Stats} = Up} = Data) ->
    #{blocks_retries := Br} = Stats,
    Stats2 = Stats#{blocks_retries := Br + 1},
    Up2 = Up#update{stats = Stats2},
    progress_update(Up2, Stats2),
    Data#data{update = Up2}.

update_done(#data{update = Up} = Data) ->
    #update{stats = Stats, system_id = SysId} = Up,
    grisp_updater_checker:abort(),
    grisp_updater_loader:abort(),
    ?LOG_INFO("Marking system ~w as updated", [SysId]),
    case system_set_updated(Data, SysId) of
        {ok, Data2}  ->
            progress_done(Up, Stats),
            {done, Data2#data{update = undefined}};
        {error, Reason} ->
            ?LOG_INFO("Failed to mark system ~w as updated: ~p",
                      [SysId, Reason]),
            update_failed(Data, Reason)
    end.

update_failed(#data{update = #update{stats = Stats} = Up} = Data, Reason) ->
    ?LOG_WARNING("Update failed: ~w", [Reason]),
    grisp_updater_checker:abort(),
    grisp_updater_loader:abort(),
    progress_error(Up, Stats, Reason),
    {done, Data#data{update = undefined}}.

object_name(#object{product = Name}) when Name =/= undefined -> Name;
object_name(#object{type = Name}) when Name =/= undefined -> Name.

lists_keysplit(K, N, L) ->
    lists_keysplit(K, N, L, []).

lists_keysplit(_K, _N, [], _Acc) ->
    not_found;
lists_keysplit(K, N, [T | R], Acc)
  when element(N, T) =:= K ->
    {lists:reverse(Acc), R};
lists_keysplit(K, N, [V | R], Acc) ->
    lists_keysplit(K, N, R, [V | Acc]).


%--- System Callbacks Handling

system_init(#data{system = undefined} = Data, {Mod, Params}) ->
    case Mod:system_init(Params) of
        {error, _Reason} = Error -> Error;
        {ok, Sub} -> {ok, Data#data{system = {Mod, Sub}}}
    end.

system_get_global_target(#data{system = {Mod, Sub}}) ->
    Mod:system_get_global_target(Sub).

system_get_active(#data{system = {Mod, Sub}}) ->
    Mod:system_get_active(Sub).

system_get_updatable(#data{system = {Mod, Sub}}) ->
    try Mod:system_get_updatable(Sub)
    catch error:undef -> undefined
    end.

system_prepare_update(#data{system = {Mod, Sub}} = Data, SysId) ->
    try Mod:system_prepare_update(Sub, SysId) of
        {error, _Reason} = Error -> Error;
        {ok, Sub2} -> {ok, Data#data{system = {Mod, Sub2}}}
    catch
        error:undef -> {ok, Data}
    end.

system_prepare_target(#data{system = {Mod, Sub}} = Data, SysId, SysTarget, Spec) ->
    try Mod:system_prepare_target(Sub, SysId, SysTarget, Spec)
    catch error:undef ->
        {ok, default_system_prepare_target(Data, SysId, SysTarget, Spec)}
    end.

default_system_prepare_target(_Data, _SysId, _SysTarget,
                              #file_target_spec{path = Path}) ->
    #target{device = Path, offset = 0, size = undefined};
default_system_prepare_target(_Data, _SysId, #target{offset = SysOffset} = SysTarget,
                              #raw_target_spec{context = system, offset = ObjOffset}) ->
    SysTarget#target{offset = SysOffset + ObjOffset};
default_system_prepare_target(#data{system = {Mod, Sub}}, _SysId, _SysTarget,
                              #raw_target_spec{context = global, offset = Offset}) ->
    GlobTarget = #target{offset = GlobOffset} = Mod:system_get_global(Sub),
    GlobTarget#target{offset = GlobOffset + Offset}.


system_set_updated(#data{system = {Mod, Sub}} = Data, SysId) ->
    case Mod:system_set_updated(Sub, SysId) of
        {error, _Reason} = Error -> Error;
        {ok, Sub2} -> {ok, Data#data{system = {Mod, Sub2}}}
    end.

system_validate(#data{system = {Mod, Sub}} = Data) ->
    case Mod:system_validate(Sub) of
        {error, _Reason} = Error -> Error;
        {ok, Sub2} -> {ok, Data#data{system = {Mod, Sub2}}}
    end.

system_terminate(#data{system = {Mod, Sub}}, Reason) ->
    Mod:system_terminate(Sub, Reason).


%--- Progress Callbacks Handling

progress_init(#update{progress = undefined} = Up, Mod, Opts) ->
    case Mod:progress_init(Opts) of
        {ok, Sub} -> {ok, Up#update{progress = {Mod, Sub}}};
        {error, _Reason} = Error -> Error
    end.

progress_update(#update{progress = {Mod, Params}}, Stats) ->
    Mod:progress_update(Params, Stats).

% progress_warning(#update{progress = {Mod, Params}}, Msg, Reason) ->
%     Mod:progress_warning(Params, Msg, Reason).

progress_error(#update{progress = {Mod, Params}}, Stats, Reason) ->
    Mod:progress_error(Params, Stats, Reason).

progress_done(#update{progress = {Mod, Params}}, Stats) ->
    Mod:progress_done(Params, Stats).
